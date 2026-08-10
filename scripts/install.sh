#!/usr/bin/env bash
#
# Passerelle -- installateur Linux
#
#   curl -fsSL <url-de-ton-hebergement>/install.sh | bash
#   ou, depuis le projet deja extrait :
#   ./scripts/install.sh
#
# Installe et configure :
#   - les dependances systeme (build tools, libudev, python3-tk)
#   - Rust (si absent ou trop ancien) via rustup
#   - le daemon passerelle-daemon (compile + installe dans ~/.local/bin)
#   - le panneau de controle graphique (raccourci dans le menu applications)
#   - un service utilisateur systemd optionnel (demarrage automatique)
#
# La toolchain ESP-IDF (firmware) et le SDK Flutter (APK Android) sont de
# gros installateurs externes avec leurs propres licences/mecanismes de
# mise a jour : ce script ne les installe PAS silencieusement en arriere
# plan, mais propose de lancer scripts/install-esp-idf.sh, et affiche la
# marche a suivre pour Flutter. Voir COMMANDES.md pour le detail complet.
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
PASSERELLE_REPO_URL="${PASSERELLE_REPO_URL:-}"
INSTALL_DIR="${PASSERELLE_DIR:-$HOME/.local/share/passerelle}"
BIN_DIR="$HOME/.local/bin"
DESKTOP_DIR="$HOME/.local/share/applications"
ICON_DIR="$HOME/.local/share/icons/hicolor/256x256/apps"
MIN_RUST_MAJOR=1
MIN_RUST_MINOR=80

# ---------------------------------------------------------------------------
# Presentation
# ---------------------------------------------------------------------------
c_reset=$'\033[0m'; c_accent=$'\033[1;36m'; c_warn=$'\033[1;33m'; c_err=$'\033[1;31m'; c_ok=$'\033[1;32m'
log()  { printf '%s[passerelle]%s %s\n' "$c_accent" "$c_reset" "$1"; }
ok()   { printf '%s[passerelle]%s %s\n' "$c_ok" "$c_reset" "$1"; }
warn() { printf '%s[passerelle]%s %s\n' "$c_warn" "$c_reset" "$1" >&2; }
err()  { printf '%s[passerelle]%s %s\n' "$c_err" "$c_reset" "$1" >&2; }

banner() {
cat <<'EOF'

  ____                           _ _
 |  _ \ __ _ ___ ___  ___ _ __ __| | | ___
 | |_) / _` / __/ __|/ _ \ '__/ _` | |/ _ \
 |  __/ (_| \__ \__ \  __/ | | (_| | |  __/
 |_|   \__,_|___/___/\___|_|  \__,_|_|\___|

 Continuite PC <-> telephone via ESP32
EOF
}

# ---------------------------------------------------------------------------
# 0. Verifications de base
# ---------------------------------------------------------------------------
require_linux() {
    if [[ "$(uname -s)" != "Linux" ]]; then
        err "Ce script installe Passerelle sur Linux uniquement."
        exit 1
    fi
}

detect_pkg_manager() {
    if command -v apt-get >/dev/null 2>&1; then
        echo "apt"
    elif command -v dnf >/dev/null 2>&1; then
        echo "dnf"
    elif command -v pacman >/dev/null 2>&1; then
        echo "pacman"
    else
        echo "unknown"
    fi
}

# ---------------------------------------------------------------------------
# 1. Localisation / recuperation du projet
# ---------------------------------------------------------------------------
locate_or_fetch_project() {
    # Cas 1 : le script est execute depuis l'interieur du projet
    # (./scripts/install.sh) -> on utilise ce checkout directement.
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || true)"
    if [[ -n "$script_dir" && -f "$script_dir/../ARCHITECTURE.md" ]]; then
        PROJECT_ROOT="$(cd "$script_dir/.." && pwd)"
        log "Projet detecte localement dans: $PROJECT_ROOT"
        return
    fi

    # Cas 2 : lance via `curl | bash` (pas de checkout local) -> on clone
    # le depot. PASSERELLE_REPO_URL doit etre defini (le script ne connait
    # pas d'URL par defaut -- heberge ce projet ou tu veux, par exemple ton
    # propre serveur git ou GitHub, puis exporte la variable) :
    #
    #   PASSERELLE_REPO_URL=https://mon-serveur/passerelle.git \
    #     curl -fsSL https://mon-serveur/install.sh | bash
    #
    if [[ -z "$PASSERELLE_REPO_URL" ]]; then
        err "Lance sans checkout local et sans PASSERELLE_REPO_URL defini."
        err "Soit tu executes ce script depuis le projet extrait (./scripts/install.sh),"
        err "soit tu exportes PASSERELLE_REPO_URL=<url git> avant de le curler."
        exit 1
    fi

    log "Recuperation du projet depuis $PASSERELLE_REPO_URL ..."
    mkdir -p "$(dirname "$INSTALL_DIR")"
    if [[ -d "$INSTALL_DIR/.git" ]]; then
        git -C "$INSTALL_DIR" pull --ff-only
    else
        git clone --depth 1 "$PASSERELLE_REPO_URL" "$INSTALL_DIR"
    fi
    PROJECT_ROOT="$INSTALL_DIR"
}

# ---------------------------------------------------------------------------
# 2. Dependances systeme
# ---------------------------------------------------------------------------
install_system_deps() {
    local pm="$1"
    log "Installation des dependances systeme ($pm)..."
    case "$pm" in
        apt)
            sudo apt-get update -y
            sudo apt-get install -y \
                curl git build-essential pkg-config libudev-dev \
                python3 python3-tk
            ;;
        dnf)
            sudo dnf install -y \
                curl git gcc gcc-c++ make pkgconf-pkg-config systemd-devel \
                python3 python3-tkinter
            ;;
        pacman)
            sudo pacman -Sy --noconfirm \
                curl git base-devel systemd-libs pkgconf python tk
            ;;
        *)
            warn "Gestionnaire de paquets non reconnu : installe manuellement curl, git,"
            warn "un compilateur C, pkg-config, les headers libudev, et python3-tk."
            ;;
    esac
}

# ---------------------------------------------------------------------------
# 3. Rust
# ---------------------------------------------------------------------------
rust_version_ok() {
    command -v cargo >/dev/null 2>&1 || return 1
    local ver major minor
    ver="$(cargo --version | awk '{print $2}')"
    major="${ver%%.*}"
    minor="${ver#*.}"; minor="${minor%%.*}"
    [[ "$major" -gt "$MIN_RUST_MAJOR" ]] && return 0
    [[ "$major" -eq "$MIN_RUST_MAJOR" && "$minor" -ge "$MIN_RUST_MINOR" ]] && return 0
    return 1
}

install_rust() {
    if rust_version_ok; then
        ok "Rust $(cargo --version) deja present et suffisamment recent."
        return
    fi
    log "Installation de Rust via rustup (necessite rustc/cargo >= ${MIN_RUST_MAJOR}.${MIN_RUST_MINOR})..."
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain stable
    # shellcheck disable=SC1090
    source "$HOME/.cargo/env"
    ok "Rust installe : $(cargo --version)"
}

# ---------------------------------------------------------------------------
# 4. Daemon
# ---------------------------------------------------------------------------
build_and_install_daemon() {
    log "Compilation du daemon (cargo build --release)..."
    (cd "$PROJECT_ROOT/linux-daemon" && cargo build --release)

    mkdir -p "$BIN_DIR"
    install -m 755 "$PROJECT_ROOT/linux-daemon/target/release/passerelle-daemon" "$BIN_DIR/passerelle-daemon"
    ok "Daemon installe : $BIN_DIR/passerelle-daemon"

    case ":$PATH:" in
        *":$BIN_DIR:"*) ;;
        *) warn "$BIN_DIR n'est pas dans ton PATH. Ajoute a ~/.bashrc (ou ~/.zshrc) :"
           warn "  export PATH=\"\$HOME/.local/bin:\$PATH\"" ;;
    esac
}

install_systemd_service() {
    local unit_dir="$HOME/.config/systemd/user"
    mkdir -p "$unit_dir"
    cat > "$unit_dir/passerelle-daemon.service" <<EOF
[Unit]
Description=Passerelle daemon (pont serie ESP32 <-> WebSocket)
After=default.target

[Service]
ExecStart=$BIN_DIR/passerelle-daemon --serial-port /dev/ttyACM0 --serial-baud 115200 --ws-port 8080
Restart=on-failure
RestartSec=3

[Install]
WantedBy=default.target
EOF
    systemctl --user daemon-reload || true
    ok "Service systemd --user installe : passerelle-daemon.service"
    log "  Activer au demarrage : systemctl --user enable --now passerelle-daemon"
    log "  Voir les logs        : journalctl --user -u passerelle-daemon -f"
    log "  (adapte le port serie dans $unit_dir/passerelle-daemon.service si besoin)"
}

# ---------------------------------------------------------------------------
# 5. Panneau de controle graphique
# ---------------------------------------------------------------------------
install_gui_launcher() {
    log "Installation du panneau de controle graphique..."
    mkdir -p "$DESKTOP_DIR" "$ICON_DIR"

    if [[ -f "$PROJECT_ROOT/android-app/assets/continium.png" ]]; then
        install -m 644 "$PROJECT_ROOT/android-app/assets/continium.png" \
            "$ICON_DIR/passerelle.png"
    fi

    mkdir -p "$BIN_DIR"
    cat > "$BIN_DIR/passerelle-gui" <<EOF
#!/usr/bin/env bash
exec python3 "$PROJECT_ROOT/linux-gui/passerelle_gui.py" "\$@"
EOF
    chmod +x "$BIN_DIR/passerelle-gui"

    cat > "$DESKTOP_DIR/passerelle-gui.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Passerelle
Comment=Continuite PC <-> telephone via ESP32
Exec=$BIN_DIR/passerelle-gui
Icon=passerelle
Terminal=false
Categories=Utility;Development;
EOF

    update-desktop-database "$DESKTOP_DIR" 2>/dev/null || true
    ok "Raccourci ajoute au menu applications : Passerelle"
    log "  Lancer en ligne de commande : passerelle-gui"
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
main() {
    banner
    require_linux

    local pm
    pm="$(detect_pkg_manager)"
    log "Distribution detectee : gestionnaire de paquets '$pm'"

    locate_or_fetch_project
    install_system_deps "$pm"
    install_rust
    build_and_install_daemon
    install_gui_launcher

    if [[ -d /run/systemd/system ]] && command -v systemctl >/dev/null 2>&1; then
        install_systemd_service
    else
        warn "systemd non detecte : lance le daemon manuellement (passerelle-daemon) ou via l'interface graphique."
    fi

    echo ""
    ok "Installation terminee."
    echo ""
    log "Prochaines etapes possibles (voir COMMANDES.md pour le detail) :"
    log "  - Lancer le panneau de controle : passerelle-gui"
    log "  - Flasher le firmware ESP32     : ./scripts/install-esp-idf.sh puis ./scripts/build-esp32.sh"
    log "  - Compiler l'app Android        : ./scripts/build-android.sh release"
}

main "$@"
