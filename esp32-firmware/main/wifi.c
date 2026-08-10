#include <string.h>
#include <stdio.h>

#include "freertos/FreeRTOS.h"
#include "freertos/event_groups.h"
#include "esp_log.h"
#include "esp_wifi.h"
#include "esp_event.h"
#include "esp_netif.h"
#include "nvs_flash.h"
#include "nvs.h"
#include "esp_system.h"

#include "app_config.h"
#include "wifi.h"

static const char *TAG = "wifi";

static char s_ssid[64] = {0};
static char s_pass[64] = {0};
static bool s_creds_loaded = false;

static EventGroupHandle_t s_events;
#define WIFI_CONNECTED_BIT BIT0
#define WIFI_FAILED_BIT    BIT1

bool wifi_has_credentials(void)
{
    if (!s_creds_loaded) {
        nvs_handle_t h;
        size_t len;
        if (nvs_open(APP_NVS_NS, NVS_READONLY, &h) == ESP_OK) {
            s_ssid[0] = 0;
            s_pass[0] = 0;
            if (nvs_get_str(h, APP_NVS_KEY_WIFI_SSID, s_ssid, &(size_t){sizeof(s_ssid) - 1}) == ESP_OK) {
                len = sizeof(s_pass) - 1;
                nvs_get_str(h, APP_NVS_KEY_WIFI_PASS, s_pass, &len);
            }
            nvs_close(h);
        }
        s_creds_loaded = true;
    }
    return s_ssid[0] != 0;
}

const char *wifi_ssid(void)
{
    wifi_has_credentials();
    return s_ssid;
}

bool wifi_save_credentials(const char *ssid, const char *pass)
{
    if (ssid == NULL || ssid[0] == 0 || pass == NULL || pass[0] == 0) {
        return false;
    }
    nvs_handle_t h;
    if (nvs_open(APP_NVS_NS, NVS_READWRITE, &h) != ESP_OK) {
        return false;
    }
    bool ok = nvs_set_str(h, APP_NVS_KEY_WIFI_SSID, ssid) == ESP_OK
              && nvs_set_str(h, APP_NVS_KEY_WIFI_PASS, pass) == ESP_OK
              && nvs_commit(h) == ESP_OK;
    nvs_close(h);
    if (ok) {
        s_creds_loaded = true;
        strncpy(s_ssid, ssid, sizeof(s_ssid) - 1);
        strncpy(s_pass, pass, sizeof(s_pass) - 1);
        ESP_LOGI(TAG, "credentials saved (ssid='%s')", ssid);
    } else {
        ESP_LOGE(TAG, "failed to save credentials");
    }
    return ok;
}

static void wifi_event_handler(void *arg, esp_event_base_t base, int32_t id, void *data)
{
    (void)arg;
    (void)base;
    if (id == WIFI_EVENT_STA_START) {
        esp_wifi_connect();
    } else if (id == WIFI_EVENT_STA_DISCONNECTED) {
        ESP_LOGW(TAG, "wifi disconnected, retrying...");
        xEventGroupClearBits(s_events, WIFI_CONNECTED_BIT);
        esp_wifi_connect();
    }
}

static void ip_event_handler(void *arg, esp_event_base_t base, int32_t id, void *data)
{
    (void)arg;
    (void)base;
    if (id == IP_EVENT_STA_GOT_IP) {
        ip_event_got_ip_t *e = data;
        ESP_LOGI(TAG, "got IP " IPSTR, IP2STR(&e->ip_info.ip));
        xEventGroupSetBits(s_events, WIFI_CONNECTED_BIT);
    }
}

bool wifi_connect_blocking(uint32_t timeout_ms)
{
    if (!wifi_has_credentials()) {
        return false;
    }
    if (s_events == NULL) {
        s_events = xEventGroupCreate();
    }
    xEventGroupClearBits(s_events, WIFI_CONNECTED_BIT | WIFI_FAILED_BIT);

    esp_netif_init();
    esp_event_loop_create_default();

    wifi_init_config_t cfg = WIFI_INIT_CONFIG_DEFAULT();
    ESP_ERROR_CHECK(esp_wifi_init(&cfg));
    esp_event_handler_instance_t h1, h2;
    ESP_ERROR_CHECK(esp_event_handler_instance_register(WIFI_EVENT, ESP_EVENT_ANY_ID,
                                                        &wifi_event_handler, NULL, &h1));
    ESP_ERROR_CHECK(esp_event_handler_instance_register(IP_EVENT, IP_EVENT_STA_GOT_IP,
                                                        &ip_event_handler, NULL, &h2));

    wifi_config_t wcfg = {0};
    strncpy((char *)wcfg.sta.ssid, s_ssid, sizeof(wcfg.sta.ssid) - 1);
    strncpy((char *)wcfg.sta.password, s_pass, sizeof(wcfg.sta.password) - 1);
    wcfg.sta.threshold.authmode = WIFI_AUTH_WPA2_PSK;

    ESP_ERROR_CHECK(esp_wifi_set_mode(WIFI_MODE_STA));
    ESP_ERROR_CHECK(esp_wifi_set_config(WIFI_IF_STA, &wcfg));
    ESP_ERROR_CHECK(esp_wifi_start());

    ESP_LOGI(TAG, "connecting to '%s'...", s_ssid);
    EventBits_t bits = xEventGroupWaitBits(s_events, WIFI_CONNECTED_BIT | WIFI_FAILED_BIT,
                                           pdFALSE, pdFALSE, pdMS_TO_TICKS(timeout_ms));
    bool ok = (bits & WIFI_CONNECTED_BIT) != 0;
    if (!ok) {
        ESP_LOGW(TAG, "wifi connect timeout (%lu ms)", (unsigned long)timeout_ms);
    }
    return ok;
}

void wifi_stop(void)
{
    esp_wifi_stop();
    esp_wifi_deinit();
}
