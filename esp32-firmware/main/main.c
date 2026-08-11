// Continium — firmware du boitier passerelle (ESP32-S3).
// Conçu et développé par Malo Lemoine — github.com/lomamalo/continium
#include <stdio.h>
#include <string.h>
#include <inttypes.h>
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "esp_system.h"
#include "esp_mac.h"
#include "esp_timer.h"
#include "esp_log.h"
#include "esp_sleep.h"
#include "nvs_flash.h"

#include "app_config.h"
#include "console.h"
#include "led.h"
#include "ledgame.h"
#include "battery.h"
#include "button.h"
#include "ble.h"
#include "wifi.h"
#include "sync.h"
#include "usb.h"

static const char *TAG = "main";

volatile app_state_t g_app_state = STATE_INIT;

/* Set by a short button press while awake: the main flow opens a
 * provisioning window (see provision_window()). */
volatile bool g_provision_window_requested = false;

static void set_state(app_state_t state)
{
    g_app_state = state;
}

/* ---- JSON emitters (hand-rolled, no fixed-size messages need a lib) ---- */

static void emit_boot(void)
{
    console_printf("{\"type\":\"boot\",\"status\":\"ready\",\"firmware\":\"%s\"}",
                   APP_FIRMWARE_VERSION);
}

static void emit_alive(void)
{
    console_printf(
        "{\"type\":\"alive\",\"state\":%d,\"ble_connected\":%s,"
        "\"charging\":%s,\"battery_mv\":%" PRIu32 "}",
        (int)g_app_state,
        ble_is_connected() ? "true" : "false",
        battery_is_charging() ? "true" : "false",
        battery_read_mv());
}

static void emit_button(const char *event, const char *action)
{
    if (action != NULL) {
        console_printf("{\"type\":\"button\",\"event\":\"%s\",\"action\":\"%s\"}",
                       event, action);
    } else {
        console_printf("{\"type\":\"button\",\"event\":\"%s\"}", event);
    }
}

static void emit_state(void)
{
    console_printf("{\"type\":\"state\",\"value\":%d}", (int)g_app_state);
}

static void emit_led(const char *color)
{
    console_printf("{\"type\":\"led\",\"color\":\"%s\"}", color);
}

static void emit_pairing_started(void)
{
    console_printf("{\"type\":\"pairing\",\"status\":\"started\"}");
}

static void emit_reset_ok(void)
{
    console_printf("{\"type\":\"reset\",\"status\":\"ok\"}");
}

static void emit_identify_ok(void)
{
    console_printf("{\"type\":\"identify\",\"status\":\"ok\"}");
}

static void emit_info(void)
{
    uint8_t mac[6];
    esp_read_mac(mac, ESP_MAC_WIFI_STA);
    int64_t uptime_ms = esp_timer_get_time() / 1000;
    console_printf(
        "{\"type\":\"info\",\"chip\":\"esp32s3\","
        "\"mac\":\"%02x:%02x:%02x:%02x:%02x:%02x\","
        "\"firmware\":\"%s\",\"state\":%d,\"uptime_ms\":%" PRId64 ","
        "\"ble_connected\":%s,\"charging\":%s,\"battery_mv\":%" PRIu32 "}",
        mac[0], mac[1], mac[2], mac[3], mac[4], mac[5],
        APP_FIRMWARE_VERSION, (int)g_app_state, uptime_ms,
        ble_is_connected() ? "true" : "false",
        battery_is_charging() ? "true" : "false",
        battery_read_mv());
}

/* ---- Command handling (see docs/proto/esp32-uart-protocol.md) ---- */
static void handle_command(const char *line)
{
    char cmd[32] = {0};
    char arg[32] = {0};
    sscanf(line, "%31s %31s", cmd, arg);

    if (strcmp(cmd, "ping") == 0) {
        console_printf("pong");
    } else if (strcmp(cmd, "state") == 0) {
        emit_state();
    } else if (strcmp(cmd, "led") == 0) {
        led_color_t color;
        if (led_color_from_name(arg, &color)) {
            ledgame_override_solid(color);
            emit_led(arg);
        } else {
            console_printf("{\"type\":\"error\",\"message\":\"unknown color\"}");
        }
    } else if (strcmp(cmd, "pair") == 0) {
        set_state(STATE_PAIRING);
        ledgame_enter_pairing(5000);
        emit_pairing_started();
    } else if (strcmp(cmd, "reset") == 0) {
        emit_reset_ok();
        vTaskDelay(pdMS_TO_TICKS(200));
        esp_restart();
    } else if (strcmp(cmd, "identify") == 0) {
        ledgame_override_blink_times((led_color_t){255, 255, 255}, 200, APP_IDENTIFY_BLINK_COUNT);
        emit_identify_ok();
    } else if (strcmp(cmd, "info") == 0) {
        emit_info();
    } else if (strcmp(cmd, "sync") == 0) {
        console_printf("{\"type\":\"sync\",\"status\":\"starting\"}");
        if (wifi_connect_blocking(APP_WIFI_CONNECT_TIMEOUT_MS)) {
            bool ok = sync_run_cycle();
            wifi_stop();
            console_printf("{\"type\":\"sync\",\"status\":\"%s\",\"stored\":%u}",
                           ok ? "ok" : "failed", (unsigned)sync_buffered_count());
        } else {
            console_printf("{\"type\":\"sync\",\"status\":\"no-wifi\"}");
        }
    } else if (strcmp(cmd, "sleep") == 0) {
        esp_sleep_enable_timer_wakeup((uint64_t)APP_SYNC_PERIOD_MS * 1000);
        esp_sleep_enable_ext1_wakeup((uint64_t)1 << APP_BUTTON_GPIO, ESP_EXT1_WAKEUP_ANY_LOW);
        esp_deep_sleep_start();
    } else if (strcmp(cmd, "bletx") == 0) {
        ble_test_notify(arg);
        console_printf("{\"type\":\"bletx\",\"status\":\"sent\"}");
    } else {
        console_printf("{\"type\":\"error\",\"message\":\"unknown command\"}");
    }
}

static void on_button_event(button_event_t event)
{
    if (event == BUTTON_EVENT_SHORT) {
        emit_button("short", "provision");
        g_provision_window_requested = true;
    } else {
        emit_button("long", "pairing");
        set_state(STATE_PAIRING);
        ledgame_enter_pairing(5000);
    }
}

/* Keeps g_app_state in sync with the real BLE link once boot is done.
 * PAIRING is left untouched: it is now a long-lived mode (provisioning
 * window / waiting for credentials), not a transient state. */
static void alive_task(void *arg)
{
    (void)arg;
    while (1) {
        if (g_app_state == STATE_READY || g_app_state == STATE_PAIRED) {
            g_app_state = ble_is_connected() ? STATE_PAIRED : STATE_READY;
        }
        emit_alive();
        vTaskDelay(pdMS_TO_TICKS(APP_ALIVE_PERIOD_MS));
    }
}

static void console_input_task(void *arg)
{
    (void)arg;
    char line[256];
    while (1) {
        if (console_read_line(line, sizeof(line)) > 0) {
            handle_command(line);
        }
    }
}

/* Stays awake for `duration_ms` with BLE advertising (the phone app can
 * provision/re-provision the WiFi during this window). Returns as soon as
 * the window expires, or earlier if the client leaves with new credentials
 * already stored. Returns true if a new provision happened. */
static bool wait_provisioning(uint32_t duration_ms)
{
    set_state(STATE_PAIRING);
    ledgame_enter_pairing(duration_ms);
    int64_t end = esp_timer_get_time() + (int64_t)duration_ms * 1000;
    bool changed = false;
    while (esp_timer_get_time() < end) {
        vTaskDelay(pdMS_TO_TICKS(200));
        if (g_provision_window_requested) {
            g_provision_window_requested = false;
            ledgame_enter_pairing(duration_ms); /* renew the animation */
        }
        if (ble_take_provision_event()) {
            changed = true;
        }
        if (changed && !ble_is_connected()) {
            break; /* new credentials stored, client gone: retry WiFi now */
        }
    }
    g_provision_window_requested = false;
    return changed;
}

static void enter_deep_sleep(void)
{
    wifi_stop();
    esp_sleep_enable_timer_wakeup((uint64_t)APP_SYNC_PERIOD_MS * 1000);
    esp_sleep_enable_ext1_wakeup((uint64_t)1 << APP_BUTTON_GPIO, ESP_EXT1_WAKEUP_ANY_LOW);
    ESP_LOGI(TAG, "deep sleep %u s (wake: timer or button GPIO%d)",
             APP_SYNC_PERIOD_MS / 1000, APP_BUTTON_GPIO);
    vTaskDelay(pdMS_TO_TICKS(50));
    esp_deep_sleep_start();
}

/* One battery-friendly cycle: wifi -> sync -> report. Does NOT sleep: the
 * caller decides (deep sleep, or provisioning window while a phone is
 * connected over BLE). */
static void sync_cycle(void)
{
    set_state(STATE_READY);
    if (wifi_connect_blocking(APP_WIFI_CONNECT_TIMEOUT_MS)) {
        ledgame_override_blink_times((led_color_t){0, 255, 128}, 150, 2);
        bool ok = sync_run_cycle();
        ledgame_override_blink_times(
            ok ? (led_color_t){0, 255, 0} : (led_color_t){255, 0, 0}, 300, ok ? 3 : 2);
    } else {
        ledgame_override_blink_times((led_color_t){255, 0, 0}, 300, 2);
    }
    wifi_stop();
}

void app_main(void)
{
    ESP_ERROR_CHECK(nvs_flash_init());
    console_init();
    ESP_LOGI(TAG, "Passerelle firmware %s starting", APP_FIRMWARE_VERSION);

    set_state(STATE_INIT);
    led_init();
    ledgame_init();
    battery_init();
    button_init(on_button_event);
    ble_init();
    sync_init();

    emit_boot();

    esp_sleep_wakeup_cause_t cause = esp_sleep_get_wakeup_cause();
    bool woke_by_button = (cause == ESP_SLEEP_WAKEUP_EXT1);
    if (woke_by_button) {
        ESP_LOGI(TAG, "woke by button: opening provisioning window");
    }

    xTaskCreate(alive_task, "alive_task", 3072, NULL, 2, NULL);
    xTaskCreate(console_input_task, "console_in", 3072, NULL, 2, NULL);

    if (!wifi_has_credentials()) {
        /* No WiFi credentials yet: stay awake advertising, wait for the
         * phone app to provision them over BLE. A short button press renews
         * the pairing animation. */
        ESP_LOGI(TAG, "no wifi credentials: waiting for BLE provisioning");
        while (1) {
            bool provisioned = wait_provisioning(APP_PROVISION_WINDOW_MS * 12);
            if (provisioned) {
                break;
            }
        }
        ESP_LOGI(TAG, "provisioned: '%s'", wifi_ssid());
    }

    /* With credentials: sync, then either sleep (no BLE client) or stay
     * awake for provisioning. A new provision triggers an immediate retry
     * of the WiFi/sync cycle instead of waiting for the next timer. */
    if (woke_by_button) {
        /* User pressed the button to reconfigure: skip the sync attempt,
         * open the provisioning window first. */
        if (wait_provisioning(APP_PROVISION_WINDOW_MS)) {
            sync_cycle();
        } else {
            enter_deep_sleep();
        }
    }

    while (1) {
        sync_cycle();
        if (ble_is_connected()) {
            ESP_LOGI(TAG, "BLE client connected: provision window open");
            if (wait_provisioning(APP_PROVISION_WINDOW_MS)) {
                continue; /* new credentials: retry the sync right away */
            }
        }
        if (battery_is_charging() || usb_host_connected()) {
            /* USB-powered or USB-connected: stay awake instead of deep
             * sleeping, so the daemon keeps its serial link, the app shows
             * live telemetry and the LED stays solid (see ledgame.c). The
             * sync still happens every APP_SYNC_PERIOD_MS thanks to the
             * loop. */
            ESP_LOGI(TAG, "USB power detected: staying awake");
            vTaskDelay(pdMS_TO_TICKS(APP_SYNC_PERIOD_MS));
            continue;
        }
        enter_deep_sleep();
    }
}
