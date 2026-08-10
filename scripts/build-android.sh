#!/usr/bin/env bash
# Compile l'APK Android de l'app "continium".
# Usage: ./scripts/build-android.sh [debug|release]
set -euo pipefail

MODE="${1:-debug}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$SCRIPT_DIR/../android-app"

if ! command -v flutter >/dev/null 2>&1; then
    echo "[erreur] 'flutter' est introuvable dans le PATH." >&2
    echo "Installe le SDK Flutter puis reessaie : https://docs.flutter.dev/get-started/install/linux" >&2
    exit 1
fi

case "$MODE" in
    debug|release) ;;
    *)
        echo "[erreur] mode inconnu: $MODE (utilise 'debug' ou 'release')" >&2
        exit 1
        ;;
esac

cd "$APP_DIR"
echo "==> flutter pub get"
flutter pub get

echo "==> flutter build apk --$MODE"
flutter build apk --"$MODE"

OUT_DIR="$APP_DIR/build/app/outputs/flutter-apk"
echo ""
echo "APK genere dans: $OUT_DIR"
ls -la "$OUT_DIR"/*.apk 2>/dev/null || true
