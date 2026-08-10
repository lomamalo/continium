#include <string.h>

#include "freertos/FreeRTOS.h"
#include "esp_log.h"
#include "esp_nimble_hci.h"
#include "nimble/nimble_port.h"
#include "nimble/nimble_port_freertos.h"
#include "host/ble_hs.h"
#include "host/util/util.h"
#include "services/gap/ble_svc_gap.h"
#include "services/gatt/ble_svc_gatt.h"

#include "app_config.h"
#include "ble.h"
#include "wifi.h"

static const char *TAG = "ble";
static uint8_t s_own_addr_type;
static volatile bool s_connected = false;

volatile bool ble_provisioned = false;
static volatile bool s_provision_event = false;

bool ble_take_provision_event(void)
{
    bool ev = s_provision_event;
    s_provision_event = false;
    return ev;
}

static int gap_event_cb(struct ble_gap_event *event, void *arg);
static int prov_write_cb(uint16_t conn_handle, uint16_t attr_handle,
                         struct ble_gatt_access_ctxt *ctxt, void *arg);
static int prov_read_cb(uint16_t conn_handle, uint16_t attr_handle,
                        struct ble_gatt_access_ctxt *ctxt, void *arg);

/* ---- GATT: provisioning service (Nordic-UART-style UUIDs) ----
 * RX (6e400002, write): receive "SSID\nPASSWORD", stored in NVS.
 * TX (6e400003, read+notify): status string ("ok"/"err:...").
 */
/* 6e400001-b5a3-f393-e0a9-e50e24dcca9e */
#define SVC_UUID_LE \
    0x9e, 0xca, 0xdc, 0x24, 0x0e, 0xe5, 0xa9, 0xe0, \
    0x93, 0xf3, 0xa3, 0xb5, 0x01, 0x00, 0x40, 0x6e
/* 6e400002-b5a3-f393-e0a9-e50e24dcca9e (RX, write) */
#define RX_UUID_LE \
    0x9e, 0xca, 0xdc, 0x24, 0x0e, 0xe5, 0xa9, 0xe0, \
    0x93, 0xf3, 0xa3, 0xb5, 0x02, 0x00, 0x40, 0x6e
/* 6e400003-b5a3-f393-e0a9-e50e24dcca9e (TX, notify) */
#define TX_UUID_LE \
    0x9e, 0xca, 0xdc, 0x24, 0x0e, 0xe5, 0xa9, 0xe0, \
    0x93, 0xf3, 0xa3, 0xb5, 0x03, 0x00, 0x40, 0x6e

static struct ble_gatt_svc_def gatt_svcs[] = {
    {
        .type = BLE_GATT_SVC_TYPE_PRIMARY,
        .uuid = BLE_UUID128_DECLARE(SVC_UUID_LE),
        .characteristics = (struct ble_gatt_chr_def[]){
            {
                .uuid = BLE_UUID128_DECLARE(RX_UUID_LE),
                .access_cb = prov_write_cb,
                .flags = BLE_GATT_CHR_F_WRITE | BLE_GATT_CHR_F_WRITE_NO_RSP,
            },
            {
                .uuid = BLE_UUID128_DECLARE(TX_UUID_LE),
                .access_cb = prov_read_cb,
                .flags = BLE_GATT_CHR_F_READ | BLE_GATT_CHR_F_NOTIFY,
            },
            {0},
        },
    },
    {0},
};

/* conn_handle/val_handle of the TX char, used to notify the phone app. */
static volatile uint16_t s_tx_conn = BLE_HS_CONN_HANDLE_NONE;
static uint16_t s_tx_val_handle = 0;

static void notify_status(const char *msg)
{
    /* The value handle is only assigned after the GATT registration; look
     * it up on demand instead of caching a possibly-stale value. */
    if (s_tx_val_handle == 0) {
        ble_gatts_find_chr(BLE_UUID128_DECLARE(SVC_UUID_LE),
                           BLE_UUID128_DECLARE(TX_UUID_LE),
                           NULL, &s_tx_val_handle);
    }
    if (s_tx_conn == BLE_HS_CONN_HANDLE_NONE || s_tx_val_handle == 0) {
        return;
    }
    struct os_mbuf *om = ble_hs_mbuf_from_flat(msg, (uint16_t)strlen(msg));
    if (om == NULL) {
        return;
    }
    ble_gatts_notify_custom(s_tx_conn, s_tx_val_handle, om);
}

/* Debug hook (console `bletx <msg>`): push a notification to the connected
 * central, used to validate the notify path without re-provisioning. */
void ble_test_notify(const char *msg)
{
    notify_status(msg);
}

/* ---- provisioning callbacks ---- */

static int prov_write_cb(uint16_t conn_handle, uint16_t attr_handle,
                         struct ble_gatt_access_ctxt *ctxt, void *arg)
{
    (void)attr_handle;
    (void)arg;
    if (ctxt->om == NULL) {
        return BLE_ATT_ERR_INVALID_ATTR_VALUE_LEN;
    }
    uint16_t len = OS_MBUF_PKTLEN(ctxt->om);
    if (len == 0 || len > 128) {
        return BLE_ATT_ERR_INVALID_ATTR_VALUE_LEN;
    }
    char data[129];
    os_mbuf_copydata(ctxt->om, 0, len, (uint8_t *)data);
    data[len] = 0;

    /* Format: "SSID\nPASSWORD" */
    char *nl = strchr(data, '\n');
    if (nl == NULL) {
        notify_status("err:format");
        return BLE_ATT_ERR_INVALID_ATTR_VALUE_LEN;
    }
    *nl = 0;
    char *ssid = data;
    char *pass = nl + 1;

    ESP_LOGI(TAG, "provisioning wifi ssid='%s' len=%d", ssid, (int)strlen(pass));
    if (wifi_save_credentials(ssid, pass)) {
        notify_status("ok");
        ble_provisioned = true;
        s_provision_event = true;
    } else {
        notify_status("err:save");
    }
    return 0;
}

static int prov_read_cb(uint16_t conn_handle, uint16_t attr_handle,
                        struct ble_gatt_access_ctxt *ctxt, void *arg)
{
    (void)attr_handle;
    (void)arg;
    const char *status = wifi_has_credentials() ? "provisioned" : "idle";
    int rc = os_mbuf_append(ctxt->om, status, (uint16_t)strlen(status));
    return rc == 0 ? 0 : BLE_ATT_ERR_INSUFFICIENT_RES;
}

static void advertise(void)
{
    struct ble_gap_adv_params adv_params;
    struct ble_hs_adv_fields fields;

    memset(&fields, 0, sizeof(fields));
    fields.flags = BLE_HS_ADV_F_DISC_GEN | BLE_HS_ADV_F_BREDR_UNSUP;
    fields.name = (uint8_t *)APP_BLE_DEVICE_NAME;
    fields.name_len = strlen(APP_BLE_DEVICE_NAME);
    fields.name_is_complete = 1;

    int rc = ble_gap_adv_set_fields(&fields);
    if (rc != 0) {
        ESP_LOGE(TAG, "adv_set_fields failed rc=%d", rc);
        return;
    }

    memset(&adv_params, 0, sizeof(adv_params));
    adv_params.conn_mode = BLE_GAP_CONN_MODE_UND;
    adv_params.disc_mode = BLE_GAP_DISC_MODE_GEN;

    rc = ble_gap_adv_start(s_own_addr_type, NULL, BLE_HS_FOREVER,
                           &adv_params, gap_event_cb, NULL);
    if (rc != 0) {
        ESP_LOGE(TAG, "adv_start failed rc=%d", rc);
    }
}

static int gap_event_cb(struct ble_gap_event *event, void *arg)
{
    (void)arg;
    switch (event->type) {
        case BLE_GAP_EVENT_CONNECT:
            if (event->connect.status == 0) {
                s_connected = true;
                /* Remember the connection so notify_status() can reach the
                 * central (this was missing: notifications never went out). */
                s_tx_conn = event->connect.conn_handle;
                ESP_LOGI(TAG, "connection established (conn=%u)", s_tx_conn);
            } else {
                advertise();
            }
            break;
        case BLE_GAP_EVENT_DISCONNECT:
            s_connected = false;
            s_tx_conn = BLE_HS_CONN_HANDLE_NONE;
            s_tx_val_handle = 0;
            advertise();
            break;
        case BLE_GAP_EVENT_ADV_COMPLETE:
            advertise();
            break;
        case BLE_GAP_EVENT_SUBSCRIBE:
            if (event->subscribe.attr_handle == s_tx_val_handle) {
                ESP_LOGI(TAG, "TX char subscribed by central");
            }
            break;
        default:
            break;
    }
    return 0;
}

static void on_sync(void)
{
    int rc = ble_hs_id_infer_auto(0, &s_own_addr_type);
    if (rc != 0) {
        ESP_LOGE(TAG, "ble_hs_id_infer_auto failed rc=%d", rc);
        return;
    }
    /* The TX char's value handle is assigned after registration; look it up
     * so SUBSCRIBE events can be matched. */
    ble_gatts_find_chr(BLE_UUID128_DECLARE(SVC_UUID_LE),
                       BLE_UUID128_DECLARE(TX_UUID_LE),
                       NULL, &s_tx_val_handle);
    advertise();
}

static void on_reset(int reason)
{
    ESP_LOGW(TAG, "nimble host reset, reason=%d", reason);
}

static void host_task(void *param)
{
    (void)param;
    nimble_port_run();
    nimble_port_freertos_deinit();
}

void ble_init(void)
{
    esp_err_t ret = nimble_port_init();
    if (ret != ESP_OK) {
        ESP_LOGE(TAG, "nimble_port_init failed: %d", ret);
        return;
    }

    ble_hs_cfg.reset_cb = on_reset;
    ble_hs_cfg.sync_cb = on_sync;

    ble_svc_gap_init();
    ble_svc_gatt_init();

    ret = ble_gatts_count_cfg(gatt_svcs);
    if (ret != 0) {
        ESP_LOGE(TAG, "ble_gatts_count_cfg failed: %d", ret);
    }
    ret = ble_gatts_add_svcs(gatt_svcs);
    if (ret != 0) {
        ESP_LOGE(TAG, "ble_gatts_add_svcs failed: %d", ret);
    }

    ble_svc_gap_device_name_set(APP_BLE_DEVICE_NAME);
    ble_provisioned = wifi_has_credentials();

    nimble_port_freertos_init(host_task);
    ESP_LOGI(TAG, "ble init done, advertising as '%s' (provisioned=%d)",
             APP_BLE_DEVICE_NAME, (int)ble_provisioned);
}

bool ble_is_connected(void)
{
    return s_connected;
}
