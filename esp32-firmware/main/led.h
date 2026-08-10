#pragma once

#include <stdbool.h>
#include <stdint.h>
#include "app_config.h"

typedef struct {
    uint8_t r, g, b;
} led_color_t;

void led_init(void);

/* Set a solid color immediately (cancels any running blink task). */
void led_set(led_color_t color);

/* Start blinking between `color` and off at `period_ms`. Runs in its own
 * FreeRTOS task; call led_set() or led_blink() again to change/cancel it. */
void led_blink(led_color_t color, uint32_t period_ms);

/* Blink `color` `count` times then return to solid off. Blocking-free:
 * spawns a one-shot task. */
void led_blink_times(led_color_t color, uint32_t period_ms, int count);

/* Convenience: reflect an app_state_t onto the LED per the color scheme
 * documented in ARCHITECTURE.md. */
void led_set_state(app_state_t state);

/* Named colors used by the `led <color>` command. Returns false if `name`
 * is not recognized. */
bool led_color_from_name(const char *name, led_color_t *out);
