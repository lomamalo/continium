# Architecture détaillée du projet Passerelle

> Projet Continium — conçu et développé par **Malo Lemoine**.
> Dépôt : <https://github.com/lomamalo/continium>

## Vue d'ensemble

Passerelle est un système de continuité entre PC Linux et smartphone Android via un boîtier ESP32 FireBeetle 2 (ESP32-S3).

```
Smartphone (Android)          PC (Linux, Fedora 44)           ESP32-S3 (FireBeetle 2)
┌──────────────────┐         ┌──────────────────────┐        ┌──────────────────────┐
│  Flutter App     │         │  Rust Daemon         │        │  ESP-IDF Firmware    │
│  "continium"     │◄───WS──►│  passerelle-daemon   │◄──USB──►│  USB Serial/JTAG    │
│                  │         │                      │        │                      │
│  WebSocket       │  :8080  │  tokio-tungstenite   │ ttyACM0│  JSON lines output   │
│  client          │         │  serialport          │ 115200 │  NimBLE BLE          │
│                  │         │  JSON forwarding      │        │  LED WS2812 GPIO 48  │
└──────────────────┘         └──────────────────────┘        │  Button GPIO 0       │
                                                             └──────────────────────┘
```

### Flux de données

1. **ESP32 → Daemon** : L'ESP32 envoie des lignes JSON via USB Serial/JTAG (console output-only)
   - `{"type":"alive","state":1}` toutes les 1s
   - `{"type":"button","event":"short"}` sur appui bouton
   - `{"type":"boot","status":"ready","firmware":"0.1.0"}` au démarrage
2. **Daemon → App Android** : Le daemon relaye chaque ligne JSON à tous les clients WebSocket connectés
3. **App Android → Daemon** : L'app envoie des commandes textes via WebSocket
4. **Daemon → ESP32** : Le daemon écrit les commandes sur le port série
   - `ping`, `state`, `led red`, `identify`, `info`, `pair`, `reset`

---

## 1. ESP32 Firmware (`esp32-firmware/`)

### Matériel
- **Carte** : FireBeetle 2 ESP32-S3 (ESP32-S3 dual-core Xtensa LX7)
- **LED** : WS2812 RGB sur GPIO 48 (via `led_strip` RMT)
- **Bouton** : BOOT GPIO 0, actif LOW, pull-up interne
- **USB** : USB Serial/JTAG intégré ( `/dev/ttyACM0` )
- **BLE** : NimBLE (pas Bluedroid), rôle périphérique uniquement

### Configuration (`sdkconfig.defaults`)
- Console : USB Serial/JTAG (pas UART)
- BLE : NimBLE enable, max 1 connexion, périphérique uniquement
- Flash : DIO 80MHz, 4MB
- FreeRTOS : tick rate 100Hz
- Optimisation : taille ( -Os )
- Log : niveau INFO max

### Fichiers source (`main/`)

| Fichier | Rôle | Détails |
|---------|------|---------|
| `app_config.h` | Configuration centralisée | Pins GPIO, timings, états, UUID BLE |
| `main.c` | Point d'entrée, REPL, alive | `app_main()`, `alive_task()`, `handle_command()` |
| `led.c/h` | Driver WS2812 | `led_init()`, `led_set()`, `led_blink()`, `led_set_state()` |
| `ble.c/h` | BLE NimBLE | `ble_init()`, publicité, callbacks GAP |
| `button.c/h` | Bouton GPIO 0 | Détection appui court (<2s) / long (≥2s), debounce 50ms |
| `console.c/h` | Console USB | `console_printf()` pour sortie, `console_read_line()` stub (non utilisé) |

### Commandes supportées
```
ping       → "pong"
state      → {"type":"state","value":<state>}
led <coul> → {"type":"led","color":"<coul>"}
pair       → {"type":"pairing","status":"started"}
reset      → {"type":"reset","status":"ok"} (suivi de reboot)
identify   → {"type":"identify","status":"ok"} (LED clignote blanc 5x)
info       → {"type":"info","chip":"esp32s3","mac":"...","firmware":"0.1.0","state":<n>,"uptime_ms":<n>}
```

### États
```c
STATE_INIT    = 0  // LED jaune clignotant
STATE_READY   = 1  // LED bleu clignotant
STATE_PAIRING = 2  // LED magenta clignotant
STATE_PAIRED  = 3  // LED verte fixe
STATE_ERROR   = 4  // LED rouge clignotant
```

### Problèmes connus
- `console_read_line()` retourne toujours -1 (output-only)
- REPL non fonctionnel : `fgets`/`select` sur stdin via USB Serial/JTAG cause Interrupt Watchdog
- Les commandes écrites sur le port série arrivent bien sur l'ESP32 mais ne sont pas lues (pas de réception)

---

## 2. Daemon Rust (`linux-daemon/`)

### Dépendances (`Cargo.toml`)
```toml
tokio = { features = ["full"] }       # Runtime async
tokio-tungstenite = "0.24"            # WebSocket serveur
futures-util = "0.3"                  # Stream/Sink combinators
serialport = "4"                      # Communication série
clap = { features = ["derive"] }      # CLI arguments
anyhow = "1"                          # Gestion d'erreurs
```

### Architecture
```
main.rs
├── serial::run()     → thread bloquant pour lecture série
│   ├── spawn_blocking → BufReader::read_line() en boucle
│   └── async select  → écriture commandes sur port série
└── ws::run()          → serveur WebSocket async
    ├── listener.accept() → accepte connexions
    └── esp_rx.recv()    → broadcast aux clients
```

### `src/main.rs`
- Parse CLI : `--serial-port` (défaut `/dev/ttyACM0`), `--serial-baud` (défaut 115200), `--ws-port` (défaut 8080)
- Crée 2 channels : `esp_tx/rx` (JSON ESP32 → WS) et `cmd_tx/rx` (WS → ESP32)
- Lance `serial::run()` dans un `tokio::spawn`
- Lance `ws::run()` dans le main (blocking await)

### `src/serial.rs`
- Boucle infinie de reconnexion (toutes les 3 secondes)
- `connect()` :
  1. Ouvrir le port série (`serialport::new()` + `.timeout(200ms)`)
  2. Cloner le port pour le reader
  3. `spawn_blocking` : `BufReader::read_line()` en boucle, envoie chaque ligne sur `esp_tx`
  4. Boucle async : `cmd_rx.recv()` → écrit sur le port série
  5. Si le reader se termine ou erreur d'écriture → fermeture et reconnexion
- Utilise `AtomicBool` pour signaler au reader bloquant qu'il doit s'arrêter
- Timeout de 200ms sur le reader, avec vérification du flag `done` à chaque timeout

**Points faibles :**
- La boucle async checke `read_handle.is_finished()` avec un sleep de 100ms (polling)
- Pas de gestion du hot-plug (juste retry toutes les 3s)
- Buffer ligne limité (pas de limite explicite, dépend de `BufReader`)

### `src/ws.rs`
- `Clients` : `Arc<Mutex<Vec<UnboundedSender<String>>>>`
- Boucle principale avec `tokio::select!` :
  - `esp_rx.recv()` : message de l'ESP32 → broadcast à tous les clients (avec `retain` pour nettoyer les morts)
  - `listener.accept()` : nouvelle connexion → `handle_client()`
- `handle_client()` :
  1. `accept_async()` → upgrade WS
  2. Crée une `UnboundedChannel` pour ce client
  3. Ajoute le sender à la liste des clients
  4. `send_task` : lit la channel → envoie sur WS
  5. `recv_task` : lit le WS → envoie sur `cmd_tx` (vers ESP32)
  6. `tokio::select!` attend que l'un des deux se termine
  7. Nettoie le sender de la liste

**Points faibles :**
- Broadcast lock tous les clients à chaque message (peut bloquer)
- Pas de heartbeat/ping sur le WS
- Pas de limitation du nombre de clients
- Les messages binaires sont convertis en UTF-8 lossy

---

## 3. App Android (`android-app/`)

### Technologie
- **Framework** : Flutter 3.29.2 (Dart 3.7.2)
- **Cible** : Android (API 34+)
- **Dépendances** : `provider` (state management), `web_socket_channel` (WebSocket)
- **APK** : Debug 85MB (Release potentiel ~8-10MB)

### Structure
```
lib/
├── main.dart                       # Point d'entrée, theme ultra dark
├── services/
│   └── websocket_service.dart      # WebSocket client + state management
├── screens/
│   └── home_screen.dart            # Layout principal (sidebar + panneaux)
└── widgets/
    ├── sidebar.dart                # Navigation latérale (icônes)
    ├── status_panel.dart           # Infos device + connexion
    ├── commands_panel.dart         # Boutons de contrôle + LED
    └── event_log.dart              # Log d'événements chronologique
```

### Theme
```dart
// Ultra dark
scaffoldBackgroundColor: #0A0A0A
cardColor: #141414
dividerColor: #2A2A2A
primary/accent: #64FFDA (teal)
// Text
primary: #E0E0E0
secondary: #888888
// Status
green: #4CAF50
red: #FF5252
orange: #FFAB40
blue: #448AFF
```

### `websocket_service.dart`
- `ChangeNotifier` (Provider pattern)
- États : `disconnected`, `connecting`, `connected`
- Auto-reconnect toutes les 3s
- Buffer de 200 messages max
- `sendCommand(command, [arg])` → envoie `"<command> [arg]\n"` sur WS
- Méthodes : `connect(host, port)`, `send(msg)`, `sendCommand(cmd, [arg])`, `clearLog()`

### `home_screen.dart`
- Dialogue de connexion au démarrage (host + port)
- AppBar avec logo `continium.png` + indicateur connecté/déconnecté
- Sidebar gauche (3 items) + panneau principal

### `status_panel.dart`
- Extrait les infos du buffer de messages (dernier `info`, `alive`, `boot`)
- Affiche : Chip, MAC, Firmware, Uptime, State
- Status connexion daemon

### `commands_panel.dart`
- Grille de boutons : Ping, Info, Identify, Pair, Reset (rouge)
- Contrôle LED : cercles de couleur (red, green, blue, yellow, white, off)

### `event_log.dart`
- Liste chronologique inversée (plus récent en haut)
- Chaque événement a une icône + couleur selon le type
- Bouton "clear" pour vider le log

### `AndroidManifest.xml`
- Permission `INTERNET` ajoutée
- Label : "continium"

### Problèmes connus
- Dialogue de connexion avec IP par défaut `192.168.1.100` (propre au réseau de dev)
- Pas de persistance des messages (perdus au reconnect)
- Pas de détection automatique du daemon (mDNS/Bonjour)
- Connect state optimiste (indique "connected" avant la confirmation WS)

---

## 4. Protocole de communication

### ESP32 → Daemon (USB Serial, JSON lines)
```
{"type":"boot","status":"ready","firmware":"0.1.0"}
{"type":"alive","state":1}
{"type":"button","event":"short"}
{"type":"button","event":"long","action":"pairing"}
```

### Daemon → App Android (WebSocket, relay brut)
Le daemon relay chaque ligne JSON 1:1 sans parsing ni transformation.

### App Android → Daemon → ESP32 (texte brut)
```
ping
state
led red
info
identify
pair
reset
```

---

## 5. Scripts et outils

### `scripts/build-esp32.sh`
- Active ESP-IDF (`~/esp/esp-idf/export.sh`)
- `idf.py fullclean` + `idf.py build`
- Usage : `./scripts/build-esp32.sh`

### `scripts/install-esp-idf.sh`
- Non documenté (probablement `git clone` + `install.sh` de ESP-IDF)

### `docs/proto/esp32-uart-protocol.md`
- Documente le protocole série entre ESP32 et PC
- Commandes REPL + messages asynchrones

---

## 6. Déploiement

### Daemon Linux
```bash
# Build
cd linux-daemon && cargo build --release

# Run
./target/release/passerelle-daemon \
  --serial-port /dev/ttyACM0 \
  --serial-baud 115200 \
  --ws-port 8080
```

### App Android
```bash
# Debug APK
cd android-app && flutter build apk --debug
# → build/app/outputs/flutter-apk/app-debug.apk

# Release APK (nécessite key store)
flutter build apk --release
```

### ESP32 Firmware
```bash
cd esp32-firmware
. ~/esp/esp-idf/export.sh
idf.py build
idf.py -p /dev/ttyACM0 flash monitor
```

---

## 7. Problèmes connus et limitations

### ESP32 Firmware
1. **Pas de REPL entrant** : impossible de lire les commandes via USB Serial/JTAG (cause : `fgets`/`select` sur USB Serial/JTAG provoque Interrupt Watchdog). Solution temporaire : output-only.
2. **Pas de gestion d'erreur BLE** : pas de callback de service découvert, pas de gestion de connexion réelle.
3. **Buffer ligne** : pas de protection contre les lignes JSON >256 chars.
4. **Blink task** : `malloc` dans `led_blink()` peut échouer silencieusement.

### Daemon Rust
1. **Polling pour la fin du reader** : `read_handle.is_finished()` checké toutes les 100ms (pas idéal).
2. **Thread bloquant pour la lecture série** : pas de timeout de lecture infini si l'ESP32 crash (le timeout 200ms le gère partiellement).
3. **Pas de heartbeat** sur le WebSocket (les clients morts sont détectés via `retain` sur send).
4. **Pas de logging structuré** : tout est en `eprintln!`.
5. **Pas de gestion de signaux** : SIGINT/SIGTERM non gérés.
6. **Le broadcast lock** est tenu pendant l'envoi à tous les clients (potentiel contention).

### App Android
1. **Performances** : la liste d'événements peut ralentir avec 200 entrées.
2. **Pas de cache** : les messages sont perdus au reconnect.
3. **Dialogue de connexion** : IP en dur, pas de découverte réseau.
4. **State management** : Provider simple (pas Riverpod/BLoC).
5. **Pas de thème system** : toujours dark (pas de light theme).
6. **Pas d'internationalisation** : tout en anglais.
7. **APK debug** : 85MB (à réduire en release).
8. **Pas de notification** : pas de background service, pas de notification si déconnecté.
9. **Sécurité** : WebSocket en clair (ws://), pas de TLS.
10. **DPR** : pas de testing sur différentes densités d'écran.
