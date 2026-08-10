#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "freertos/FreeRTOS.h"
#include "esp_log.h"
#include "esp_spiffs.h"
#include "esp_http_client.h"
#include "esp_timer.h"

#include "app_config.h"
#include "sync.h"
#include "battery.h"

static const char *TAG = "sync";

static bool s_spiffs_ready = false;

bool sync_init(void)
{
    esp_vfs_spiffs_conf_t conf = {
        .base_path = "/spiffs",
        .partition_label = NULL, /* first SPIFFS partition found */
        .max_files = 4,
        .format_if_mount_failed = true,
    };
    esp_err_t ret = esp_vfs_spiffs_register(&conf);
    if (ret != ESP_OK) {
        ESP_LOGE(TAG, "spiffs register failed: %d", ret);
        return false;
    }
    s_spiffs_ready = true;
    ESP_LOGI(TAG, "spiffs mounted, %d items buffered", (int)sync_buffered_count());
    return true;
}

uint32_t sync_buffered_count(void)
{
    FILE *f = fopen(APP_BUFFER_FILE, "r");
    if (f == NULL) {
        return 0;
    }
    uint32_t count = 0;
    char buf[512];
    size_t n;
    while ((n = fread(buf, 1, sizeof(buf), f)) > 0) {
        for (size_t i = 0; i < n; i++) {
            if (memcmp(&buf[i], "\"category\"", 10) == 0) {
                count++;
            }
        }
    }
    fclose(f);
    return count;
}

/* Collects the GET response body into a growing buffer. */
typedef struct {
    char *data;
    size_t len;
    size_t cap;
} http_body_t;

static esp_err_t on_data(esp_http_client_event_t *evt)
{
    http_body_t *b = evt->user_data;
    if (evt->event_id == HTTP_EVENT_ON_DATA) {
        size_t need = b->len + evt->data_len + 1;
        if (need > b->cap) {
            size_t new_cap = b->cap ? b->cap * 2 : 4096;
            while (new_cap < need) {
                new_cap *= 2;
            }
            char *nd = realloc(b->data, new_cap);
            if (nd == NULL) {
                return ESP_FAIL;
            }
            b->data = nd;
            b->cap = new_cap;
        }
        memcpy(b->data + b->len, evt->data, evt->data_len);
        b->len += evt->data_len;
        b->data[b->len] = 0;
    }
    return ESP_OK;
}

static bool http_get_continuity(char **out, size_t *out_len)
{
    char url[128];
    snprintf(url, sizeof(url), "http://%s:%d/continuity",
             APP_DAEMON_HOST, APP_DAEMON_HTTP_PORT);

    http_body_t body = {0};
    esp_http_client_config_t cfg = {
        .url = url,
        .event_handler = on_data,
        .user_data = &body,
        .timeout_ms = APP_SYNC_HTTP_TIMEOUT_MS,
        .buffer_size = 2048,
    };
    esp_http_client_handle_t client = esp_http_client_init(&cfg);
    if (client == NULL) {
        return false;
    }
    esp_err_t err = esp_http_client_perform(client);
    esp_http_client_cleanup(client);

    if (err != ESP_OK || body.len == 0) {
        ESP_LOGW(TAG, "GET /continuity failed: %s", esp_err_to_name(err));
        free(body.data);
        return false;
    }
    *out = body.data;
    *out_len = body.len;
    ESP_LOGI(TAG, "GET /continuity: %d bytes", (int)body.len);
    return true;
}

static bool http_post_box_status(uint32_t stored, int64_t last_sync_ms)
{
    char url[128];
    snprintf(url, sizeof(url), "http://%s:%d/box/status",
             APP_DAEMON_HOST, APP_DAEMON_HTTP_PORT);

    char body[192];
    snprintf(body, sizeof(body),
             "{\"battery_mv\":%lu,\"stored\":%lu,\"last_sync_ms\":%lld,\"firmware\":\"%s\"}",
             (unsigned long)battery_read_mv(), (unsigned long)stored,
             (long long)last_sync_ms, APP_FIRMWARE_VERSION);

    esp_http_client_config_t cfg = {
        .url = url,
        .method = HTTP_METHOD_POST,
        .timeout_ms = APP_SYNC_HTTP_TIMEOUT_MS,
    };
    esp_http_client_handle_t client = esp_http_client_init(&cfg);
    if (client == NULL) {
        return false;
    }
    esp_http_client_set_header(client, "Content-Type", "application/json");
    esp_http_client_set_post_field(client, body, strlen(body));
    esp_err_t err = esp_http_client_perform(client);
    esp_http_client_cleanup(client);

    if (err != ESP_OK) {
        ESP_LOGW(TAG, "POST /box/status failed: %s", esp_err_to_name(err));
        return false;
    }
    ESP_LOGI(TAG, "POST /box/status: %s", body);
    return true;
}

bool sync_run_cycle(void)
{
    char *json = NULL;
    size_t json_len = 0;
    bool ok = http_get_continuity(&json, &json_len);
    if (ok) {
        FILE *f = fopen(APP_BUFFER_FILE, "w");
        if (f != NULL) {
            fwrite(json, 1, json_len, f);
            fclose(f);
        }
    }
    int64_t now_ms = esp_timer_get_time() / 1000;
    bool reported = http_post_box_status(sync_buffered_count(), now_ms);
    free(json);
    return ok && reported;
}
