#!/usr/bin/env bash
# Installs ESP-IDF (v5.x) into ~/esp/esp-idf for building the ESP32
# firmware in esp32-firmware/. Safe to re-run.
set -euo pipefail

IDF_DIR="$HOME/esp/esp-idf"
IDF_BRANCH="release/v5.3"

mkdir -p "$HOME/esp"

if [ ! -d "$IDF_DIR" ]; then
    git clone -b "$IDF_BRANCH" --recursive https://github.com/espressif/esp-idf.git "$IDF_DIR"
else
    echo "ESP-IDF already present at $IDF_DIR, updating..."
    cd "$IDF_DIR"
    git pull
    git submodule update --init --recursive
fi

cd "$IDF_DIR"
./install.sh esp32s3

echo "Done. Source $IDF_DIR/export.sh before building, or use scripts/build-esp32.sh"
