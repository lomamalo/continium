#pragma once

#include <stdint.h>
#include "hal/adc_types.h"

/* ---------------- GPIO ----------------
 * The FireBeetle 2 ESP32-S3 (DFR0975) has a single onboard user LED on
 * GPIO21, silkscreen label D13 (also shared with the GDI backlight pin).
 * It is a plain (non-addressable) LED, driven via the LEDC PWM peripheral
 * so it can fade as well as blink. */
#define APP_LED_GPIO        21
#define APP_BUTTON_GPIO     0   /* BOOT button, active LOW, internal pull-up */

/* ---------------- Timings ---------------- */
#define APP_ALIVE_PERIOD_MS       1000
#define APP_BUTTON_DEBOUNCE_MS    50
#define APP_BUTTON_LONG_PRESS_MS  2000
#define APP_BLINK_PERIOD_MS       500
#define APP_IDENTIFY_BLINK_COUNT  5

/* LED status patterns (ledgame.c), period per full cycle:
 *   not paired -> fast blink, paired -> slower blink,
 *   battery low -> slow fade, charging -> faster fade,
 *   charging AND full -> solid on (see render_automatic). */
#define APP_LED_BLINK_NOT_PAIRED_MS  400
#define APP_LED_BLINK_PAIRED_MS      1200
#define APP_LED_FADE_LOW_MS          3000
#define APP_LED_FADE_CHARGING_MS     1200

/* ---------------- Battery / charge monitoring ----------------
 * The FireBeetle 2 ESP32-S3 has an onboard LiPo charge management chip,
 * but (on the stock board) its CHRG status is only wired to a charge LED,
 * not to a spare MCU GPIO. So charging is inferred from the battery
 * voltage trend read on the analog pin below (voltage rising steadily =
 * charging; falling = on battery; flat near the top = full/USB-powered).
 *
 * If your revision *does* expose the charger's CHRG pin (open-drain,
 * active LOW while charging) to a free GPIO, wire it up and set
 * APP_CHG_STATUS_GPIO to that pin for a precise reading instead of the
 * heuristic -- ledgame.c / battery.c prefer it automatically when >= 0.
 */
#define APP_BATTERY_ADC_CHANNEL   ADC_CHANNEL_0 /* GPIO1 on ESP32-S3, DFRobot VBAT divider */
#define APP_CHG_STATUS_GPIO       (-1)           /* set to a GPIO number if wired, else -1 */
#define APP_BATTERY_SAMPLE_MS     2000
#define APP_BATTERY_TREND_WINDOW  6              /* samples kept for trend detection */
#define APP_BATTERY_RISE_MV       15             /* min rise over the window to call it "charging" */
#define APP_BATTERY_FALL_MV       15             /* min fall over the window to call it "discharging" */
#define APP_BATTERY_LOW_MV        3450            /* below this: low-battery warning */
#define APP_BATTERY_FULL_MV       4150            /* at/above this: considered full */
/* DFRobot FireBeetle 2 ESP32-S3 battery divider is 1:2 (100k/100k), and the
 * ADC is read with attenuation ADC_ATTEN_DB_12; adjust the multiplier below
 * if your board's divider differs. */
#define APP_BATTERY_DIVIDER_RATIO 2.0f

/* ---------------- LED game (ambient animation) ---------------- */
#define APP_LED_GAME_TICK_MS      20   /* animation frame period, smooth breathing */
#define APP_LED_OVERRIDE_MS       4000 /* how long a manual `led <color>` command holds before the game resumes */

/* ---------------- Firmware ---------------- */
#define APP_FIRMWARE_VERSION "0.4.0"
#define APP_AUTHOR "Malo Lemoine"

/* ---------------- WiFi + battery-powered sync (box buffer) ----------------
 * The box runs on battery, connects to the home WiFi (credentials are
 * provisioned once from the phone app over BLE, stored in NVS), pulls the
 * continuity store from the daemon into SPIFFS as a buffer copy, reports
 * its status (POST /box/status) and goes back to deep sleep. */
#define APP_DAEMON_HOST          "192.168.1.180"
#define APP_DAEMON_HTTP_PORT     8081
#define APP_SYNC_PERIOD_MS       600000   /* 10 min between syncs */
#define APP_WIFI_CONNECT_TIMEOUT_MS 15000
#define APP_SYNC_HTTP_TIMEOUT_MS 10000
#define APP_BUFFER_FILE          "/spiffs/continuity.json"
#define APP_NVS_NS               "passerelle"
#define APP_NVS_KEY_WIFI_SSID    "wifi_ssid"
#define APP_NVS_KEY_WIFI_PASS    "wifi_pass"
#define APP_PROVISION_WINDOW_MS  300000   /* stay awake 5 min for BLE config */

/* ---------------- BLE ---------------- */
#define APP_BLE_DEVICE_NAME   "Passerelle-ESP32"
/* Custom 128-bit UUIDs (randomly generated for this project) */
#define APP_BLE_SERVICE_UUID  "6e400001-b5a3-f393-e0a9-e50e24dcca9e"
#define APP_BLE_TX_CHAR_UUID  "6e400003-b5a3-f393-e0a9-e50e24dcca9e"
#define APP_BLE_RX_CHAR_UUID  "6e400002-b5a3-f393-e0a9-e50e24dcca9e"

/* ---------------- States ---------------- */
typedef enum {
    STATE_INIT    = 0, /* LED yellow blinking   */
    STATE_READY   = 1, /* LED blue blinking     */
    STATE_PAIRING = 2, /* LED magenta blinking  */
    STATE_PAIRED  = 3, /* LED green solid       */
    STATE_ERROR   = 4, /* LED red blinking      */
} app_state_t;

/* Global mutable state, defined in main.c */
extern volatile app_state_t g_app_state;
