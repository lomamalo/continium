#include "button.h"
#include "app_config.h"
#include "driver/gpio.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "esp_timer.h"

static button_event_cb_t s_cb = NULL;

static void button_task(void *arg)
{
    (void)arg;
    bool was_pressed = false;
    int64_t press_start_us = 0;

    while (1) {
        bool level_low = (gpio_get_level(APP_BUTTON_GPIO) == 0); /* active LOW */

        if (level_low && !was_pressed) {
            /* Possible press start: debounce */
            vTaskDelay(pdMS_TO_TICKS(APP_BUTTON_DEBOUNCE_MS));
            if (gpio_get_level(APP_BUTTON_GPIO) == 0) {
                was_pressed = true;
                press_start_us = esp_timer_get_time();
            }
        } else if (!level_low && was_pressed) {
            /* Possible release: debounce */
            vTaskDelay(pdMS_TO_TICKS(APP_BUTTON_DEBOUNCE_MS));
            if (gpio_get_level(APP_BUTTON_GPIO) != 0) {
                was_pressed = false;
                int64_t held_ms = (esp_timer_get_time() - press_start_us) / 1000;
                if (s_cb != NULL) {
                    s_cb(held_ms >= APP_BUTTON_LONG_PRESS_MS
                             ? BUTTON_EVENT_LONG
                             : BUTTON_EVENT_SHORT);
                }
            }
        }

        vTaskDelay(pdMS_TO_TICKS(10));
    }
}

void button_init(button_event_cb_t cb)
{
    s_cb = cb;

    gpio_config_t io_conf = {
        .pin_bit_mask = 1ULL << APP_BUTTON_GPIO,
        .mode = GPIO_MODE_INPUT,
        .pull_up_en = GPIO_PULLUP_ENABLE,
        .pull_down_en = GPIO_PULLDOWN_DISABLE,
        .intr_type = GPIO_INTR_DISABLE,
    };
    gpio_config(&io_conf);

    xTaskCreate(button_task, "button_task", 2048, NULL, 4, NULL);
}
