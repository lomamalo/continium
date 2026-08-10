#pragma once

#include <stdbool.h>

/* True when the board's native USB port is connected to a real host (the
 * PC's daemon): the USB Serial/JTAG peripheral receives SOF packets. A
 * power bank never counts as connected. Used to keep the box awake and
 * show a steady LED while plugged in. */
bool usb_host_connected(void);
