#pragma once

#include <stdint.h>
#include "led.h"

/*
 * "Jeu de LED" -- continuous ambient animation task reflecting the board's
 * real, live status: BLE pairing (ble_is_connected()) and battery state
 * (battery_is_charging()/battery_is_full()/battery_is_low()), on top of the
 * boot/error states from app_config.h.
 *
 * The FireBeetle 2 ESP32-S3 LED (onboard, GPIO21/D13) is single-color, so
 * patterns are brightness envelopes only. Automatic patterns, most urgent
 * wins (no command running):
 *   - INIT (boot) / ERROR              -> fast blink
 *   - charging AND full                -> solid ON
 *   - charging                         -> fast fade
 *   - battery low                      -> slow fade
 *   - paired (BLE connected)           -> slow blink
 *   - not paired                       -> fast blink
 *
 * Manual overrides (the `led <color>` and `identify` commands, plus the
 * temporary `pair` window) take priority for a bounded time, then the
 * automatic game resumes on its own -- no command is needed to "undo" it.
 */

void ledgame_init(void);

/* Solid color override for APP_LED_OVERRIDE_MS, then resumes automatic play. */
void ledgame_override_solid(led_color_t color);

/* Blink override for `count` blinks at `period_ms`, then resumes automatic play. */
void ledgame_override_blink_times(led_color_t color, uint32_t period_ms, int count);

/* Magenta "pairing" window of `duration_ms`, then resumes automatic play
 * (which will already reflect the real BLE state by the time it ends). */
void ledgame_enter_pairing(uint32_t duration_ms);
