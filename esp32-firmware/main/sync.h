#pragma once

#include <stdbool.h>
#include <stdint.h>

/* Initializes SPIFFS (the box buffer). Safe to call before any sync. */
bool sync_init(void);

/* Runs one full sync cycle:
 *   - GET  /continuity from the daemon, saved to SPIFFS (buffer copy)
 *   - POST /box/status (battery, stored count, last sync)
 * Returns true if both steps succeeded (daemon reachable).
 * Requires WiFi to be connected already. */
bool sync_run_cycle(void);

/* Number of items currently buffered in SPIFFS (cheap heuristic: counts
 * "category" keys in the buffered JSON). */
uint32_t sync_buffered_count(void);
