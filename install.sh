#!/usr/bin/env bash
# Passerelle — installateur tout-en-un.
#
#   ./install.sh [--gui] [--no-gui] [--uninstall]
#
# Installe :
#   1. le daemon (service systemd utilisateur, démarre au boot, redémarre seul)
#   2. les scripts (envoi du fichier actif, ...) dans ~/.local/bin
#   3. l'app Linux (Continium) avec icone + autostart (optionnel)
#   4. des raccourcis expliqués a la fin
#
# Aucun acces root requis.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="$HOME/.local/bin"
APP_DIR="$HOME/.local/share/continium"
SERVICE_DIR="$HOME/.config/systemd/user"
INSTALL_GUI=1

for arg in "$@"; do
  case "$arg" in
    --gui) INSTALL_GUI=1 ;;
    --no-gui) INSTALL_GUI=0 ;;
    --uninstall) UNINSTALL=1 ;;
  esac
done

echo "==> Passerelle : installation pour $USER"

mkdir -p "$BIN_DIR" "$APP_DIR" "$SERVICE_DIR"

# ---------------------------------------------------------------- daemon
DAEMON_SRC="$ROOT/linux-daemon/target/release/passerelle-daemon"
if [ ! -f "$DAEMON_SRC" ]; then
  echo "ERREUR : binaire du daemon absent. Compile d'abord :"
  echo "  cd $ROOT/linux-daemon && cargo build --release"
  exit 1
fi

echo "==> [1/4] Daemon -> $BIN_DIR/passerelle-daemon"
cp -f "$DAEMON_SRC" "$BIN_DIR/passerelle-daemon"

UNIT="$SERVICE_DIR/passerelle-daemon.service"
echo "==> [2/4] Service systemd utilisateur : $UNIT"
cat > "$UNIT" <<EOF
[Unit]
Description=Passerelle daemon (ESP32 <-> apps)
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=$BIN_DIR/passerelle-daemon --serial-port /dev/ttyACM0 --serial-baud 115200 --ws-port 8080 --http-port 8081
Restart=always
RestartSec=3
StandardOutput=append:$HOME/.local/state/passerelle-daemon.log
StandardError=append:$HOME/.local/state/passerelle-daemon.log

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

# --------------------------------------------------------------- scripts
echo "==> [3/4] Scripts -> $BIN_DIR"
for s in "$ROOT"/scripts/*.py; do
  [ -e "$s" ] || continue
  name="$(basename "$s" .py)"
  cp -f "$s" "$BIN_DIR/$name"
  chmod +x "$BIN_DIR/$name"
  echo "    $name"
done

# --------------------------------------------------------------- app linux
if [ "$INSTALL_GUI" = "1" ]; then
  echo "==> [4/4] App Linux (Continium)"
  BUNDLE="$ROOT/android-app/build/linux/x64/debug/bundle"
  if [ ! -d "$BUNDLE" ]; then
    echo "    (bundle absent, compilation ignoree)"
  else
    rm -rf "$APP_DIR"
    cp -r "$BUNDLE" "$APP_DIR"
    ln -sf "$APP_DIR/continium" "$BIN_DIR/continium"

    DESKTOP_DIR="$HOME/.local/share/applications"
    mkdir -p "$DESKTOP_DIR"
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

    AUTOSTART="$HOME/.config/autostart"
    mkdir -p "$AUTOSTART"
    cp -f "$DESKTOP_DIR/continium.desktop" "$AUTOSTART/continium.desktop"
    echo "    installee + demarrage automatique a l'ouverture de session"
  fi
else
  echo "==> [4/4] App Linux ignoree (--no-gui)"
fi

echo
echo "Termine ! Ce qui tourne maintenant :"
echo "  - daemon en service (demarre au boot, se relance tout seul)"
echo "  - scripts dans ~/.local/bin (passerelle-gui, send_active_file, ...)"
echo "  - app Continium : icone dans le menu, demarrage auto a la session"
echo
echo "Pour gerer le daemon :"
echo "  systemctl --user status passerelle-daemon"
echo "  systemctl --user stop passerelle-daemon"
echo "Log : ~/.local/state/passerelle-daemon.log"
