#!/usr/bin/env bash
# Continium — installateur PC tout-en-un.
#
#   curl -fsSL https://raw.githubusercontent.com/lomaloma/continium/main/continium-site/install-pc.sh | bash
#
# Installe :
#   1. le daemon Rust en service systemd utilisateur (démarre au boot, se relance seul)
#   2. l'extension Firefox (installée manuellement en un clic ensuite)
#   3. un raccourci Continium dans le menu + démarrage automatique de session
#   4. l'app Linux (AppImage) si elle est présente dans la release
#
# Aucun accès root requis.

set -euo pipefail

BASE="https://github.com/lomaloma/continium/releases/latest/download"
BIN_DIR="$HOME/.local/bin"
APP_DIR="$HOME/.local/share/continium"
SERVICE_DIR="$HOME/.config/systemd/user"
EXT_DIR="$HOME/.local/share/passerelle-extension"
LOG_FILE="$HOME/.local/state/passerelle-daemon.log"

echo "==> Continium : installation pour $USER"
mkdir -p "$BIN_DIR" "$APP_DIR" "$SERVICE_DIR" "$EXT_DIR"

# ---------------------------------------------------------------- 1. daemon
echo "==> [1/4] Daemon Rust -> $BIN_DIR/passerelle-daemon"
curl -fsSL "$BASE/passerelle-daemon" -o "$BIN_DIR/passerelle-daemon"
chmod +x "$BIN_DIR/passerelle-daemon"

UNIT="$SERVICE_DIR/passerelle-daemon.service"
cat > "$UNIT" <<EOF
[Unit]
Description=Passerelle daemon (ESP32 <-> apps)
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

for pid in $(pgrep -f "^$BIN_DIR/passerelle-daemon" || true); do
  echo "    (arret du daemon manuel PID $pid)"
  kill "$pid" 2>/dev/null || true
done
sleep 1

systemctl --user daemon-reload
systemctl --user enable --now passerelle-daemon.service
loginctl enable-linger "$USER" 2>/dev/null || true
systemctl --user is-active passerelle-daemon.service

# ----------------------------------------------------------- 2. app linux
echo "==> [2/4] App Linux (AppImage)"
if curl -fsSL "$BASE/continium.AppImage" -o "$APP_DIR/continium.AppImage" 2>/dev/null; then
  chmod +x "$APP_DIR/continium.AppImage"
  ln -sf "$APP_DIR/continium.AppImage" "$BIN_DIR/continium"
  echo "    installee : ~/.local/bin/continium"
else
  echo "    (aucune AppImage dans la release, on continue sans)"
fi

# --------------------------------------------------------- 3. extension
echo "==> [3/4] Extension Firefox -> $EXT_DIR/passerelle.xpi"
curl -fsSL "$BASE/passerelle.xpi" -o "$EXT_DIR/passerelle.xpi"
echo "    a installer en un clic : about:addons -> engrenage -> Installer depuis un fichier"

# --------------------------------------------------------- 4. menu + autostart
echo "==> [4/4] Entree de menu + demarrage automatique"
DESKTOP_DIR="$HOME/.local/share/applications"
mkdir -p "$DESKTOP_DIR" "$HOME/.config/autostart"
cat > "$DESKTOP_DIR/continium.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Continium
Comment=Passerelle — continuer ses activites sur son telephone
Exec=$BIN_DIR/continium
Icon=applications-internet
Terminal=false
Categories=Network;
EOF
cp -f "$DESKTOP_DIR/continium.desktop" "$HOME/.config/autostart/continium.desktop"

echo
echo "Termine ! Ce qui tourne maintenant :"
echo "  - daemon en service (demarre au boot, se relance tout seul)"
echo "  - extension Firefox a installer en 1 clic (voir au-dessus)"
echo "  - app Continium : icone dans le menu, demarrage auto a la session"
echo
echo "Gerer le daemon :"
echo "  systemctl --user status passerelle-daemon"
echo "  systemctl --user stop passerelle-daemon"
echo "Log : $LOG_FILE"
