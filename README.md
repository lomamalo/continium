# Passerelle

**La continuité entre ton PC Linux et ton téléphone, portée par un boîtier
ESP32 que tu contrôles de bout en bout.** Firmware, daemon, application
mobile et panneau de contrôle Linux -- un seul projet, zéro dépendance
cloud, auto-hébergé.

Page de présentation : [`marketing/index.html`](marketing/index.html)
(ouvre-la simplement dans un navigateur). Check-list complète de toutes
les commandes : [`COMMANDES.md`](COMMANDES.md).

Voir [ARCHITECTURE.md](ARCHITECTURE.md) pour le détail complet de
l'architecture, du protocole, et des limitations connues.

```
Smartphone (Android) <--WS--> PC (Linux, daemon Rust) <--USB--> ESP32-S3 (firmware ESP-IDF)
```

## Structure du dépôt

```
passerelle/
├── esp32-firmware/     # Firmware ESP-IDF (C) : USB Serial/JTAG, BLE NimBLE, LED WS2812, batterie
│   └── components/led_strip/   # Composant led_strip vendorise (build 100% hors-ligne)
├── linux-daemon/        # Daemon Rust : pont serie <-> WebSocket
├── android-app/         # App Flutter "continium"
├── linux-gui/            # Panneau de controle graphique Linux (Tkinter)
├── scripts/              # install.sh, build-esp32.sh, build-android.sh, install-esp-idf.sh
├── marketing/            # Page de presentation (marketing/index.html)
├── docs/proto/            # Documentation du protocole serie
├── COMMANDES.md           # Toutes les commandes, dans l'ordre
└── ARCHITECTURE.md        # Document d'architecture detaille (source de verite)
```

## Démarrage rapide

Installation automatisee du daemon + panneau de controle graphique :

```bash
./scripts/install.sh
passerelle-gui
```

Voir [COMMANDES.md](COMMANDES.md) pour le detail complet (firmware ESP32,
APK Android, service systemd, etc.) -- ou continue ci-dessous pour les
etapes manuelles.

### 1. Firmware ESP32
```bash
./scripts/install-esp-idf.sh   # une seule fois
./scripts/build-esp32.sh
cd esp32-firmware && idf.py -p /dev/ttyACM0 flash monitor
```

### 2. Daemon Rust
```bash
# Dependances systeme (Debian/Ubuntu/Raspberry Pi OS)
sudo apt install libudev-dev pkg-config

cd linux-daemon
cargo build --release
./target/release/passerelle-daemon --serial-port /dev/ttyACM0 --serial-baud 115200 --ws-port 8080
```
> **Verifie par compilation reelle** (debug + release, zero warning) avec
> rustc/cargo 1.91. Necessite rustc/cargo >= 1.80 (voir `rust-version`
> dans Cargo.toml) : le rustc 1.75 par defaut d'Ubuntu 24.04 echoue car
> une dependance transitive (`unescaper`, via `tungstenite`) requiert
> `edition2024`. `libudev-dev` est requis par la crate `serialport` pour
> l'enumeration des ports.

### 3. App Android
```bash
cd android-app
flutter pub get
flutter build apk --debug
# APK: build/app/outputs/flutter-apk/app-debug.apk
```
Au premier lancement, l'app demande l'IP et le port du daemon (par défaut
`192.168.1.100:8080`, à adapter à votre réseau).

### 4. Panneau de contrôle graphique (Linux)
```bash
sudo apt install python3-tk    # ou: sudo dnf install python3-tkinter
python3 linux-gui/passerelle_gui.py
```
Regroupe les etapes 1 a 3 dans une interface (demarrage du daemon, build +
flash du firmware, build de l'APK, journal en direct). Voir
[COMMANDES.md](COMMANDES.md).

## Limitations connues

Voir la section "Problèmes connus et limitations" dans ARCHITECTURE.md — en
particulier, la réception de commandes côté ESP32 (REPL entrant) n'est pas
fonctionnelle : le firmware ne fait actuellement qu'émettre des messages
(mode output-only), à cause d'un Interrupt Watchdog déclenché par la
lecture du stdin USB Serial/JTAG.

## Intégration bout en bout

Le firmware, le daemon et l'app sont câblés ensemble par une seule source
de vérité : la télémétrie JSON de l'ESP32 (`ble_connected`, `charging`,
`battery_mv`, voir `docs/proto/esp32-uart-protocol.md`), relayée telle
quelle par le daemon jusqu'à l'app.

- **Jeu de LED embarqué** (`esp32-firmware/main/ledgame.c`) : anime la LED
  WS2812 en continu selon l'état réel BLE + batterie (bleu = en recherche,
  vert "battement de coeur" = connecté, ambre/cyan respirant = en charge,
  rouge = batterie faible), sans intervention du PC/de l'app.
- **App Android** (`android-app/lib/widgets/continuity_card.dart`) : la
  carte de continuité rejoue exactement la même logique côté écran (glyphe
  du logo animé), à partir de la même télémétrie reçue en direct sur le
  WebSocket — donc toujours cohérente avec ce que montre la LED physique.
- **Connexion WebSocket réelle** : `WebSocketService.connect()` attend la
  confirmation du handshake (`channel.ready`) avant d'annoncer "connecté"
  (plus d'état optimiste), et se reconnecte automatiquement toutes les 3s.
