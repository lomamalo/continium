#include "battery.h"
#include "app_config.h"

#include <string.h>
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "esp_adc/adc_oneshot.h"
#include "esp_adc/adc_cali.h"
#include "esp_adc/adc_cali_scheme.h"
#include "driver/gpio.h"
#include "esp_log.h"

static const char *TAG = "battery";

static adc_oneshot_unit_handle_t s_adc_handle;
static adc_cali_handle_t s_cali_handle;
static bool s_cali_ok = false;

static volatile uint32_t s_last_mv = 0;
static volatile bool s_charging = false;

static uint32_t s_history[APP_BATTERY_TREND_WINDOW];
static int s_history_count = 0;
static int s_history_pos = 0;

static bool cali_init(void)
{
    adc_cali_curve_fitting_config_t cali_config = {
        .unit_id = ADC_UNIT_1,
        .chan = APP_BATTERY_ADC_CHANNEL,
        .atten = ADC_ATTEN_DB_12,
        .bitwidth = ADC_BITWIDTH_DEFAULT,
    };
    return adc_cali_create_scheme_curve_fitting(&cali_config, &s_cali_handle) == ESP_OK;
}

static uint32_t sample_raw_mv(void)
{
    int raw = 0;
    if (adc_oneshot_read(s_adc_handle, APP_BATTERY_ADC_CHANNEL, &raw) != ESP_OK) {
        return s_last_mv; /* keep last known value on transient read errors */
    }

    int mv = raw;
    if (s_cali_ok) {
        adc_cali_raw_to_voltage(s_cali_handle, raw, &mv);
    }

    return (uint32_t)((float)mv * APP_BATTERY_DIVIDER_RATIO);
}

static void push_history(uint32_t mv)
{
    s_history[s_history_pos] = mv;
    s_history_pos = (s_history_pos + 1) % APP_BATTERY_TREND_WINDOW;
    if (s_history_count < APP_BATTERY_TREND_WINDOW) {
        s_history_count++;
    }
}

static void update_trend(void)
{
    if (APP_CHG_STATUS_GPIO >= 0) {
        /* Precise hardware signal available: active LOW while charging. */
        s_charging = (gpio_get_level(APP_CHG_STATUS_GPIO) == 0);
        return;
    }

    if (s_history_count < APP_BATTERY_TREND_WINDOW) {
        return; /* not enough samples yet to judge a trend */
    }

    /* Oldest sample is the one right after the current write position. */
    uint32_t oldest = s_history[s_history_pos];
    uint32_t newest = s_history[(s_history_pos + APP_BATTERY_TREND_WINDOW - 1) % APP_BATTERY_TREND_WINDOW];

    if (newest >= oldest && (newest - oldest) >= APP_BATTERY_RISE_MV) {
        s_charging = true;
    } else if (oldest > newest && (oldest - newest) >= APP_BATTERY_FALL_MV) {
        s_charging = false;
    }
    /* else: keep previous verdict, voltage is roughly flat (e.g. full and
     * still on the charger, or idle on battery) */
}

static void battery_task(void *arg)
{
    (void)arg;
    while (1) {
        uint32_t mv = sample_raw_mv();
        s_last_mv = mv;
        push_history(mv);
        update_trend();
        vTaskDelay(pdMS_TO_TICKS(APP_BATTERY_SAMPLE_MS));
    }
}

void battery_init(void)
{
    adc_oneshot_unit_init_cfg_t init_config = {
        .unit_id = ADC_UNIT_1,
    };
    if (adc_oneshot_new_unit(&init_config, &s_adc_handle) != ESP_OK) {
        ESP_LOGE(TAG, "adc_oneshot_new_unit failed");
        return;
    }

    adc_oneshot_chan_cfg_t chan_config = {
        .atten = ADC_ATTEN_DB_12,
        .bitwidth = ADC_BITWIDTH_DEFAULT,
    };
    adc_oneshot_config_channel(s_adc_handle, APP_BATTERY_ADC_CHANNEL, &chan_config);

    s_cali_ok = cali_init();
    if (!s_cali_ok) {
        ESP_LOGW(TAG, "ADC calibration unavailable, using raw counts as mV approximation");
    }

    if (APP_CHG_STATUS_GPIO >= 0) {
        gpio_config_t io_conf = {
            .pin_bit_mask = 1ULL << APP_CHG_STATUS_GPIO,
            .mode = GPIO_MODE_INPUT,
            .pull_up_en = GPIO_PULLUP_ENABLE,
        };
        gpio_config(&io_conf);
    }

    memset(s_history, 0, sizeof(s_history));

    xTaskCreate(battery_task, "battery_task", 3072, NULL, 2, NULL);
    ESP_LOGI(TAG, "battery monitor init done (channel=%d, chg_gpio=%d)",
             APP_BATTERY_ADC_CHANNEL, APP_CHG_STATUS_GPIO);
}

uint32_t battery_read_mv(void)
{
    return s_last_mv;
}

bool battery_is_charging(void)
{
    return s_charging;
}

bool battery_is_full(void)
{
    return s_last_mv >= APP_BATTERY_FULL_MV;
}

bool battery_is_low(void)
{
    return (!s_charging) && s_last_mv > 0 && s_last_mv < APP_BATTERY_LOW_MV;
}
