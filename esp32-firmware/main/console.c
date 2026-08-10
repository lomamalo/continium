#include "console.h"
#include <stdio.h>
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "driver/usb_serial_jtag.h"
#include "esp_vfs_usb_serial_jtag.h"
#include "esp_log.h"
#define CONSOLE_RX_POLL_MS 10

void console_init(void)
{
    /* Install the USB Serial/JTAG driver explicitly: the IDF console REPL
     * would do it via esp_console_new_repl_usb_serial_jtag(), but we never
     * create a REPL, so without this call usb_serial_jtag_read_bytes()
     * dereferences a NULL driver context and panics. */
    usb_serial_jtag_driver_config_t cfg = USB_SERIAL_JTAG_DRIVER_CONFIG_DEFAULT();
    esp_err_t err = usb_serial_jtag_driver_install(&cfg);
    if (err != ESP_OK && err != ESP_ERR_INVALID_STATE) {
        ESP_LOGE("console", "usb_serial_jtag_driver_install: %s", esp_err_to_name(err));
    }
    esp_vfs_dev_usb_serial_jtag_register();
    esp_vfs_dev_usb_serial_jtag_set_rx_line_endings(ESP_LINE_ENDINGS_LF);
    esp_vfs_dev_usb_serial_jtag_set_tx_line_endings(ESP_LINE_ENDINGS_LF);

    setvbuf(stdout, NULL, _IOLBF, 256);
}

void console_printf(const char *fmt, ...)
{
    va_list args;
    va_start(args, fmt);
    vprintf(fmt, args);
    va_end(args);
    printf("\n");
    fflush(stdout);
}

int console_read_line(char *buf, int buf_len)
{
    int pos = 0;
    uint8_t ch;

    for (;;) {
        if (usb_serial_jtag_read_bytes(&ch, 1, 0) == 1) {
            if (ch == '\n' || ch == '\r') {
                if (pos > 0) {
                    buf[pos] = '\0';
                    return pos;
                }
                continue; /* skip empty lines */
            }
            if (pos < buf_len - 1) {
                buf[pos++] = (char)ch;
            }
        } else {
            vTaskDelay(pdMS_TO_TICKS(CONSOLE_RX_POLL_MS));
        }
    }
}
