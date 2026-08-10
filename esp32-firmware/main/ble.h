#pragma once

#include <stdbool.h>

/* True if WiFi credentials were provisioned (saved in NVS). Set by the
 * BLE provisioning write callback when new credentials arrive. */
extern volatile bool ble_provisioned;

/* Returns true if a successful provisioning write happened since the last
 * call, and clears the event. The main flow uses this to retry the WiFi
 * connection immediately with the freshly provisioned credentials. */
bool ble_take_provision_event(void);

/* Initializes NimBLE host+controller and starts advertising as a peripheral
 * with the provisioning service (RX: wifi credentials, TX: status notify).
 * Only one concurrent connection is supported. */
void ble_init(void);

/* True while a central (e.g. the phone app) is connected. */
bool ble_is_connected(void);

/* Debug hook (console `bletx <msg>`): push a notification to the connected
 * central, used to validate the notify path without re-provisioning. */
void ble_test_notify(const char *msg);
