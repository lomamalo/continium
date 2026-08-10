# Commandes -- de zero a un systeme Passerelle complet

Check-list de toutes les commandes a taper, dans l'ordre, pour installer et
faire fonctionner l'ensemble du projet sur un PC Linux (teste sur base
Debian/Ubuntu/Raspberry Pi OS et Fedora). Pour l'installation automatisee
du daemon + de l'interface graphique, va directement a l'**etape 1** puis
saute a l'**etape 4** (elle fait le reste toute seule).

---

## 0. Recuperer le projet

```bash
tar -xf passerelle.tar
cd passerelle
```

---

## 1. Installation automatique (daemon + panneau de controle graphique)

```bash
./scripts/install.sh
```

Ce script installe les dependances systeme, Rust si besoin, compile et
installe `passerelle-daemon` dans `~/.local/bin`, ajoute un raccourci
"Passerelle" dans le menu applications, et propose un service systemd
utilisateur pour le demarrage automatique.

Une fois lance :

```bash
passerelle-gui                              # ouvre le panneau de controle
# ou, sans interface graphique :
passerelle-daemon --serial-port /dev/ttyACM0 --serial-baud 115200 --ws-port 8080
```

Demarrage automatique via systemd (optionnel, propose par le script) :

```bash
systemctl --user enable --now passerelle-daemon
journalctl --user -u passerelle-daemon -f    # voir les logs en direct
```

---

## 2. Firmware ESP32 (FireBeetle 2 ESP32-S3)

```bash
./scripts/install-esp-idf.sh      # une seule fois -- installe ESP-IDF (~1-2 Go)
./scripts/build-esp32.sh          # compile le firmware

# Flasher (adapte le port si besoin, ex: /dev/ttyACM0)
source ~/esp/esp-idf/export.sh
cd esp32-firmware
idf.py -p /dev/ttyACM0 flash monitor
```

`Ctrl+]` pour quitter le monitor serie.

Le composant `led_strip` est fourni directement dans
`esp32-firmware/components/led_strip/` (vendorise) : pas besoin d'acces
internet au Component Manager d'Espressif pour compiler.

---

## 3. Application Android (`continium`)

Necessite le [SDK Flutter](https://docs.flutter.dev/get-started/install/linux)
installe et accessible dans le `PATH`.

```bash
# Verifier l'installation Flutter
flutter doctor

# Compiler (via le script, ou les commandes flutter directement)
./scripts/build-android.sh debug      # APK de developpement, rapide
./scripts/build-android.sh release    # APK optimise pour diffusion

# Equivalent manuel :
cd android-app
flutter pub get
flutter build apk --release
```

APK genere dans `android-app/build/app/outputs/flutter-apk/app-release.apk`
-- a transferer sur le telephone (cable USB, `adb install app-release.apk`,
ou simplement copier le fichier et l'ouvrir depuis le telephone).

```bash
adb install android-app/build/app/outputs/flutter-apk/app-release.apk
```

---

## 4. Panneau de controle graphique -- utilisation

Le panneau (`linux-gui/passerelle_gui.py`, lance via `passerelle-gui` apres
l'etape 1) regroupe les etapes 1 a 3 dans une interface :

- **Etat du daemon** : demarrer / arreter / recompiler, choix du port serie
  et du port WebSocket, detection automatique des ports (`/dev/ttyACM*`,
  `/dev/ttyUSB*`).
- **Onglet Firmware ESP32** : installer ESP-IDF, compiler, flasher --
  chaque bouton lance la commande correspondante et affiche la sortie en
  direct.
- **Onglet Application Android** : compiler l'APK (debug/release), ouvrir
  le dossier de sortie.
- **Onglet Journal** : sortie du daemon en direct.

Lancement manuel sans passer par `install.sh` :

```bash
sudo apt install python3-tk    # ou: sudo dnf install python3-tkinter
python3 linux-gui/passerelle_gui.py
```

---

## 5. Verifications rapides

```bash
# Le daemon tourne et ecoute bien sur le port WebSocket
ss -tln | grep 8080

# Le port serie de l'ESP32 est bien detecte
ls /dev/ttyACM* /dev/ttyUSB* 2>/dev/null

# Logs du daemon (si lance via systemd)
journalctl --user -u passerelle-daemon -f
```

---

## Recapitulatif express (systeme deja installe)

```bash
passerelle-gui
```

C'est tout : le reste (build firmware, build APK, demarrage/arret du
daemon) se pilote depuis l'interface.
