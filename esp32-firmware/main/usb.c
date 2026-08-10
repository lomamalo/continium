#include "usb.h"

#include "driver/usb_serial_jtag.h"

bool usb_host_connected(void)
{
    return usb_serial_jtag_is_connected();
}
