#!/usr/bin/env bash
# Continium — installateur PC tout-en-un, compatible toutes distros Linux.
#
#   curl -fsSL https://raw.githubusercontent.com/lomamalo/continium/main/docs/install-pc.sh | bash
#   curl -fsSL .../install-pc.sh | bash -s - -ip        # afficher l'URL de l'app
#
# Installe :
#   1. le daemon Rust en service systemd utilisateur (presse-papier partage,
#      serveur web de l'app, liaison boitier ESP32) — demarre au boot, se
#      relance seul
#   2. un raccourci sur le Bureau vers l'app (s'ouvre dans le navigateur)
#   3. l'extension Firefox (installee manuellement en un clic ensuite)
#
# L'app Linux tourne dans le navigateur : aucune dependance, aucune
# compilation, aucune version de distro requise.
#
# Aucun acces root requis.

set -euo pipefail

BASE="https://github.com/lomamalo/continium/releases/latest/download"
RAW="https://raw.githubusercontent.com/lomamalo/continium/main/docs"
BIN_DIR="$HOME/.local/bin"
APP_DIR="$HOME/.local/share/continium"
SERVICE_DIR="$HOME/.config/systemd/user"
EXT_DIR="$HOME/.local/share/passerelle-extension"
LOG_FILE="$HOME/.local/state/passerelle-daemon.log"
URL_LOCAL="http://127.0.0.1:8081"

PRINT_URL=0
for arg in "$@"; do
  [ "$arg" = "-ip" ] && PRINT_URL=1
done

local_ip() {
  ip route get 1 2>/dev/null | sed -n 's/.*src \([0-9.]*\).*/\1/p' \
    || hostname -I 2>/dev/null | awk '{print $1}'
}

app_url() {
  local ip
  ip="$(local_ip)"
  echo "  Sur ce PC      : $URL_LOCAL"
  [ -n "$ip" ] && echo "  Sur le reseau  : http://$ip:8081"
}

if [ "$PRINT_URL" = "1" ]; then
  echo "==> Continium — URL de l'app Linux (navigateur) :"
  app_url
  exit 0
fi

echo "==> Continium : installation pour $USER"
mkdir -p "$BIN_DIR" "$APP_DIR" "$SERVICE_DIR" "$EXT_DIR"

# ---------------------------------------------------------------- 1. daemon
echo "==> [1/2] Daemon Rust (service systemd) -> $BIN_DIR/passerelle-daemon"
curl -fsSL "$BASE/passerelle-daemon" -o "$BIN_DIR/passerelle-daemon"
chmod +x "$BIN_DIR/passerelle-daemon"

UNIT="$SERVICE_DIR/passerelle-daemon.service"
cat > "$UNIT" <<EOF
[Unit]
Description=Continium — passerelle (presse-papier, web, boitier ESP32)
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=$BIN_DIR/passerelle-daemon --serial-port /dev/ttyACM0 --serial-baud 115200 --ws-port 8080 --http-port 8081
Restart=always
RestartSec=3
StandardOutput=append:$LOG_FILE
StandardError=append:$LOG_FILE

[Install]
WantedBy=default.target
EOF

# Arrete un daemon lance a la main pour liberer les ports (si present).
for pid in $(pgrep -f "^$BIN_DIR/passerelle-daemon" || true); do
  echo "    (arret du daemon manuel PID $pid)"
  kill "$pid" 2>/dev/null || true
done
sleep 1

systemctl --user daemon-reload
systemctl --user enable --now passerelle-daemon.service
loginctl enable-linger "$USER" 2>/dev/null || true
systemctl --user is-active passerelle-daemon.service

# -------------------------------------------------- 2. raccourci bureau
echo "==> [2/2] Raccourci vers l'app sur le Bureau"
curl -fsSL "$RAW/assets/continium.png" -o "$APP_DIR/continium.png"
DESKTOP_DIR="$(xdg-user-dir DESKTOP 2>/dev/null || echo "$HOME/Desktop")"
mkdir -p "$DESKTOP_DIR"
cat > "$DESKTOP_DIR/continium.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Continium
Comment=Continium — presse-papier partage et passerelle
Exec=xdg-open $URL_LOCAL
Icon=$APP_DIR/continium.png
Terminal=false
Categories=Network;
EOF
chmod +x "$DESKTOP_DIR/continium.desktop"
echo "    $DESKTOP_DIR/continium.desktop"

# -------------------------------------------------------- 3. extension
echo "==> Extension Firefox -> $EXT_DIR/passerelle.xpi"
if curl -fsSL "$BASE/passerelle.xpi" -o "$EXT_DIR/passerelle.xpi" 2>/dev/null; then
  echo "    a installer en un clic : about:addons -> engrenage -> Installer depuis un fichier"
else
  echo "    (non disponible, on continue)"
fi

echo
echo "Termine ! L'app Continium s'ouvre dans le navigateur :"
app_url
echo
echo "Gerer le daemon (tout tourne via systemd) :"
echo "  systemctl --user status passerelle-daemon"
echo "  systemctl --user restart passerelle-daemon"
echo "  systemctl --user stop passerelle-daemon"
echo "  journalctl --user -u passerelle-daemon -f"
echo "Rappel de l'URL : curl -fsSL $RAW/install-pc.sh | bash -s - -ip"
