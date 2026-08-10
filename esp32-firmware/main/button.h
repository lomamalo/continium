#pragma once

typedef enum {
    BUTTON_EVENT_SHORT,
    BUTTON_EVENT_LONG,
} button_event_t;

typedef void (*button_event_cb_t)(button_event_t event);

/* Initializes GPIO0 with internal pull-up and starts a polling task that
 * debounces the button and distinguishes short (<2s) vs long (>=2s) presses. */
void button_init(button_event_cb_t cb);
