#pragma once

#include <stdarg.h>

/* Initialize the USB Serial/JTAG console for output. */
void console_init(void);

/* printf-style helper that writes a line (with trailing \n) to the console. */
void console_printf(const char *fmt, ...);

/*
 * NOTE: reading from the USB Serial/JTAG console via fgets()/select() causes
 * an Interrupt Watchdog reset on this target/IDF combo. This function is a
 * stub kept for API symmetry; it always returns -1 and must NOT be relied on.
 * See "Known issues" in ARCHITECTURE.md.
 */
int console_read_line(char *buf, int buf_len);
