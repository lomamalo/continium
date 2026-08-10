#pragma once

#include <stdbool.h>
#include <stdint.h>

/* Initializes the battery ADC (and the CHG status GPIO if configured) and
 * starts a background task that samples the battery voltage every
 * APP_BATTERY_SAMPLE_MS and derives a charging/discharging trend. */
void battery_init(void);

/* Latest battery voltage in millivolts (already scaled by the divider
 * ratio). Returns 0 before the first sample is taken. */
uint32_t battery_read_mv(void);

/* True if the board appears to be charging right now. If APP_CHG_STATUS_GPIO
 * is configured (>= 0), this reflects that pin directly; otherwise it is
 * derived from the voltage trend (see battery.c). */
bool battery_is_charging(void);

/* True if battery_read_mv() is at/above APP_BATTERY_FULL_MV. */
bool battery_is_full(void);

/* True if battery_read_mv() is below APP_BATTERY_LOW_MV (and not currently
 * charging). */
bool battery_is_low(void);
