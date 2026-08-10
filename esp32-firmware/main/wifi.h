#pragma once

#include <stdbool.h>
#include <stdint.h>

/* Loads the provisioned WiFi credentials from NVS. Returns true if both
 * SSID and password are present. */
bool wifi_has_credentials(void);

/* Returns the stored SSID (static buffer, "" if none). */
const char *wifi_ssid(void);

/* Saves the WiFi credentials to NVS (provisioned over BLE from the phone
 * app). Returns true on success. */
bool wifi_save_credentials(const char *ssid, const char *pass);

/* Connects to the stored WiFi network. Blocks until connected or the
 * timeout expires. Returns true if connected (IP obtained). */
bool wifi_connect_blocking(uint32_t timeout_ms);

/* Disconnects and stops the WiFi driver (before deep sleep). */
void wifi_stop(void);
