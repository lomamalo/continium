#!/usr/bin/env bash
# Build the ESP32 firmware from scratch.
# Usage: ./scripts/build-esp32.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIRMWARE_DIR="$SCRIPT_DIR/../esp32-firmware"

# shellcheck disable=SC1091
source "$HOME/esp/esp-idf/export.sh"

cd "$FIRMWARE_DIR"
idf.py fullclean
idf.py build

echo "Build done. Flash with:"
echo "  idf.py -p /dev/ttyACM0 flash monitor"
