idf_component_register(
    SRCS "main.c" "led.c" "ledgame.c" "battery.c" "ble.c" "button.c" "console.c"
          "wifi.c" "sync.c" "usb.c"
    INCLUDE_DIRS "."
    REQUIRES driver vfs led_strip bt esp_timer nvs_flash esp_hw_support esp_adc
             esp_wifi esp_event esp_netif esp_http_client spiffs
)
