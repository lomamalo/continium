# Panneau de contrôle Passerelle (Linux)

Interface graphique Tkinter (aucune dépendance externe hors `python3-tk`)
pour piloter tout le projet sans taper de commandes.

## Lancer

```bash
sudo apt install python3-tk     # Debian/Ubuntu/Raspberry Pi OS
# ou : sudo dnf install python3-tkinter   (Fedora)

python3 passerelle_gui.py
```

Ou, après `../scripts/install.sh` :

```bash
passerelle-gui
```

## Fonctionnalités

- **État du daemon** : démarrer / arrêter / recompiler, sélection du port
  série (détection automatique `/dev/ttyACM*`, `/dev/ttyUSB*`) et du port
  WebSocket. Statut affiché en direct (point vert/rouge).
- **Firmware ESP32** : installer ESP-IDF, compiler, flasher -- chaque
  action lance le script correspondant (`../scripts/*.sh`) et affiche sa
  sortie en direct.
- **Application Android** : compiler l'APK (debug ou release) via
  `../scripts/build-android.sh`, ouvrir le dossier de sortie.
- **Journal** : sortie du daemon en direct.

La configuration (port série, baud, port WebSocket) est mémorisée dans
`~/.config/passerelle/gui.json`.

## Implémentation

Toute action longue (compilation, flash, etc.) tourne dans un thread
séparé via `subprocess.Popen`, et sa sortie est poussée dans une file
`queue.Queue` consommée par la boucle Tkinter via `after()` -- l'interface
ne se fige jamais pendant une compilation.
