#include "ledgame.h"
#include "app_config.h"
#include "led.h"
#include "ble.h"
#include "battery.h"
#include "usb.h"

#include <math.h>
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "esp_timer.h"

/* The FireBeetle 2 ESP32-S3 onboard LED is a single-color LED on GPIO21
 * (silk D13): only its brightness can be controlled, so every pattern is
 * expressed as a grayscale brightness envelope 0..255 (led.c maps a
 * grayscale color straight to the LEDC duty).
 *
 * Exact requested patterns, most urgent wins:
 *   - charging (USB-powered)     -> solid ON: "the box is connected"
 *   - battery low                -> slow fade
 *   - paired (BLE connected)     -> slow blink
 *   - not paired                 -> fast blink
 *   - boot / error               -> fast blink (transient, on top)
 *
 * Manual overrides (the `led <color>` and `identify` commands, plus the
 * temporary `pair` window) take priority for a bounded time, then the
 * automatic game resumes on its own -- no command is needed to "undo" it.
 */

static volatile bool s_override_active = false;
static volatile int64_t s_override_until_us = 0;

static uint8_t grayscale(float v)
{
    if (v < 0.0f) v = 0.0f;
    if (v > 1.0f) v = 1.0f;
    return (uint8_t)(255.0f * v);
}

/* Smooth 0..1..0 fade envelope, period_ms per full cycle. */
static float fade_envelope(int64_t now_us, uint32_t period_ms)
{
    float phase = fmodf((float)(now_us / 1000), (float)period_ms) / (float)period_ms;
    return 0.5f - 0.5f * cosf(2.0f * (float)M_PI * phase);
}

/* Square blink envelope: full brightness for half the period, off for the
 * other half. */
static float blink_envelope(int64_t now_us, uint32_t period_ms)
{
    return (fmodf((float)(now_us / 1000), (float)period_ms) < period_ms / 2) ? 1.0f : 0.0f;
}

static void render_automatic(int64_t now_us)
{
    if (g_app_state == STATE_INIT || g_app_state == STATE_ERROR) {
        led_set((led_color_t){ grayscale(blink_envelope(now_us, APP_LED_BLINK_NOT_PAIRED_MS)), 0, 0 });
        return;
    }

    bool charging = battery_is_charging() || usb_host_connected();
    bool low = battery_is_low();

    float level;
    if (charging) {
        level = 1.0f; /* solid on: USB-powered (charging/full), no blink */
    } else if (low) {
        level = fade_envelope(now_us, APP_LED_FADE_LOW_MS); /* slow fade */
    } else if (ble_is_connected()) {
        level = blink_envelope(now_us, APP_LED_BLINK_PAIRED_MS); /* slow blink */
    } else {
        level = blink_envelope(now_us, APP_LED_BLINK_NOT_PAIRED_MS); /* fast blink */
    }

    led_set((led_color_t){ grayscale(level), 0, 0 });
}

static void game_task(void *arg)
{
    (void)arg;
    while (1) {
        int64_t now = esp_timer_get_time();

        if (s_override_active) {
            if (now >= s_override_until_us) {
                s_override_active = false;
            }
            /* while override is active, the command that triggered it
             * (led_set / led_blink / led_blink_times) already owns the LED;
             * we just wait without touching it. */
        } else {
            render_automatic(now);
        }

        vTaskDelay(pdMS_TO_TICKS(APP_LED_GAME_TICK_MS));
    }
}

void ledgame_init(void)
{
    xTaskCreate(game_task, "led_game", 3072, NULL, 3, NULL);
}

void ledgame_override_solid(led_color_t color)
{
    led_set(color);
    s_override_until_us = esp_timer_get_time() + (int64_t)APP_LED_OVERRIDE_MS * 1000;
    s_override_active = true;
}

void ledgame_override_blink_times(led_color_t color, uint32_t period_ms, int count)
{
    led_blink_times(color, period_ms, count);
    int64_t duration_us = (int64_t)period_ms * count + 300000; /* small buffer */
    s_override_until_us = esp_timer_get_time() + duration_us;
    s_override_active = true;
}

void ledgame_enter_pairing(uint32_t duration_ms)
{
    led_blink((led_color_t){255, 255, 255}, APP_BLINK_PERIOD_MS);
    s_override_until_us = esp_timer_get_time() + (int64_t)duration_ms * 1000;
    s_override_active = true;
}
