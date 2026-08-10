#include "led.h"
#include <string.h>
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "driver/ledc.h"
#include "esp_log.h"

static const char *TAG = "led";

/* The FireBeetle 2 ESP32-S3 onboard LED is a plain single-color LED on
 * GPIO21 (silk D13): no RMT/WS2812, just LEDC PWM so it can fade. */
#define LEDC_SPEED_MODE   LEDC_LOW_SPEED_MODE
#define LEDC_TIMER_NUM    LEDC_TIMER_0
#define LEDC_CHANNEL_NUM  LEDC_CHANNEL_0
#define LEDC_DUTY_RES     LEDC_TIMER_8_BIT
#define LEDC_FREQ_HZ      5000

static TaskHandle_t s_blink_task = NULL;
static SemaphoreHandle_t s_led_mutex = NULL;
static volatile bool s_blink_stop_requested = false;

typedef struct {
    uint32_t duty;
    uint32_t period_ms;
    int count; /* -1 = forever */
} blink_args_t;

/* Writes to the LEDC channel are cheap and atomic, but the blink task and
 * the game task can both be writing, so keep them serialized (same
 * discipline as the old RMT path). */
static void apply_duty(uint32_t duty)
{
    xSemaphoreTake(s_led_mutex, portMAX_DELAY);
    ledc_set_duty(LEDC_SPEED_MODE, LEDC_CHANNEL_NUM, duty);
    ledc_update_duty(LEDC_SPEED_MODE, LEDC_CHANNEL_NUM);
    xSemaphoreGive(s_led_mutex);
}

/* Single-color LED: brightness = max RGB channel (grayscale {v,0,0} from
 * the game keeps the fade level; any named color lights at full duty). */
static uint32_t color_to_duty(led_color_t c)
{
    uint32_t m = c.r;
    if (c.g > m) m = c.g;
    if (c.b > m) m = c.b;
    return m;
}

static void blink_task(void *arg)
{
    blink_args_t args = *(blink_args_t *)arg;
    vPortFree(arg);

    bool on = false;
    int iterations = args.count > 0 ? args.count * 2 : -1;

    while (iterations != 0) {
        if (s_blink_stop_requested) {
            break;
        }
        on = !on;
        apply_duty(on ? args.duty : 0);
        if (s_blink_stop_requested) {
            break;
        }
        vTaskDelay(pdMS_TO_TICKS(args.period_ms / 2 == 0 ? args.period_ms : args.period_ms / 2));
        if (iterations > 0) {
            iterations--;
        }
    }

    if (args.count > 0 && !s_blink_stop_requested) {
        apply_duty(0);
    }

    s_blink_task = NULL;
    s_blink_stop_requested = false;
    vTaskDelete(NULL);
}

/* Cooperative stop: set the flag and let blink_task finish its current
 * apply_duty() before it deletes itself. */
static void stop_blink(void)
{
    if (s_blink_task != NULL) {
        s_blink_stop_requested = true;
        for (int i = 0; i < 100 && s_blink_task != NULL; i++) {
            vTaskDelay(pdMS_TO_TICKS(10));
        }
        if (s_blink_task != NULL) {
            TaskHandle_t h = s_blink_task;
            s_blink_task = NULL;
            s_blink_stop_requested = false;
            vTaskDelete(h);
        }
    }
}

void led_init(void)
{
    s_led_mutex = xSemaphoreCreateMutex();

    ledc_timer_config_t timer_conf = {
        .speed_mode = LEDC_SPEED_MODE,
        .timer_num = LEDC_TIMER_NUM,
        .duty_resolution = LEDC_DUTY_RES,
        .freq_hz = LEDC_FREQ_HZ,
        .clk_cfg = LEDC_AUTO_CLK,
    };
    ESP_ERROR_CHECK(ledc_timer_config(&timer_conf));

    ledc_channel_config_t channel_conf = {
        .gpio_num = APP_LED_GPIO,
        .speed_mode = LEDC_SPEED_MODE,
        .channel = LEDC_CHANNEL_NUM,
        .intr_type = LEDC_INTR_DISABLE,
        .timer_sel = LEDC_TIMER_NUM,
        .duty = 0,
        .hpoint = 0,
    };
    ESP_ERROR_CHECK(ledc_channel_config(&channel_conf));

    ESP_LOGI(TAG, "led init done (gpio=%d, ledc)", APP_LED_GPIO);
}

void led_set(led_color_t color)
{
    stop_blink();
    apply_duty(color_to_duty(color));
}

void led_blink(led_color_t color, uint32_t period_ms)
{
    stop_blink();
    blink_args_t *args = pvPortMalloc(sizeof(blink_args_t));
    if (args == NULL) {
        ESP_LOGE(TAG, "led_blink: malloc failed");
        return;
    }
    *args = (blink_args_t){ .duty = color_to_duty(color), .period_ms = period_ms, .count = -1 };
    xTaskCreate(blink_task, "led_blink", 2048, args, 3, &s_blink_task);
}

void led_blink_times(led_color_t color, uint32_t period_ms, int count)
{
    stop_blink();
    blink_args_t *args = pvPortMalloc(sizeof(blink_args_t));
    if (args == NULL) {
        ESP_LOGE(TAG, "led_blink_times: malloc failed");
        return;
    }
    *args = (blink_args_t){ .duty = color_to_duty(color), .period_ms = period_ms, .count = count };
    xTaskCreate(blink_task, "led_blink_n", 2048, args, 3, &s_blink_task);
}

void led_set_state(app_state_t state)
{
    switch (state) {
        case STATE_INIT:
            led_blink((led_color_t){255, 255, 255}, APP_BLINK_PERIOD_MS);
            break;
        case STATE_READY:
            led_blink((led_color_t){255, 255, 255}, APP_BLINK_PERIOD_MS);
            break;
        case STATE_PAIRING:
            led_blink((led_color_t){255, 255, 255}, APP_BLINK_PERIOD_MS);
            break;
        case STATE_PAIRED:
            led_set((led_color_t){255, 255, 255});
            break;
        case STATE_ERROR:
            led_blink((led_color_t){255, 255, 255}, APP_BLINK_PERIOD_MS);
            break;
        default:
            break;
    }
}

bool led_color_from_name(const char *name, led_color_t *out)
{
    if (strcmp(name, "red") == 0)    { *out = (led_color_t){255, 0, 0}; return true; }
    if (strcmp(name, "green") == 0)  { *out = (led_color_t){0, 255, 0}; return true; }
    if (strcmp(name, "blue") == 0)   { *out = (led_color_t){0, 0, 255}; return true; }
    if (strcmp(name, "yellow") == 0) { *out = (led_color_t){255, 255, 0}; return true; }
    if (strcmp(name, "white") == 0)  { *out = (led_color_t){255, 255, 255}; return true; }
    if (strcmp(name, "off") == 0)    { *out = (led_color_t){0, 0, 0}; return true; }
    return false;
}
