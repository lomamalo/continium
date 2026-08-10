# Protocole série ESP32 <-> PC

Ce document décrit le protocole texte/JSON échangé entre le firmware
ESP32-S3 (FireBeetle 2) et le daemon Rust `passerelle-daemon`, sur le port
USB Serial/JTAG (`/dev/ttyACM0`, 115200 bauds).

## Direction ESP32 -> PC (messages asynchrones, JSON lines)

| Message | Déclencheur | Exemple |
|---|---|---|
| boot | Démarrage du firmware | `{"type":"boot","status":"ready","firmware":"0.1.0"}` |
| alive | Toutes les 1000 ms | `{"type":"alive","state":1,"ble_connected":true,"charging":false,"battery_mv":3980}` |
| button | Appui court (<2s) sur GPIO 0 | `{"type":"button","event":"short"}` |
| button | Appui long (>=2s) sur GPIO 0 | `{"type":"button","event":"long","action":"pairing"}` |

`ble_connected`, `charging` et `battery_mv` sont l'état réel du device (lu
par `ble.c`/`battery.c`) : c'est cette télémétrie qui pilote à la fois le
"jeu de LED" embarqué (`ledgame.c`) et la carte de continuité côté app
Android (`continuity_card.dart`), donc les deux sont toujours cohérents
avec le matériel.

## Jeu de LED (`ledgame.c`)

Animation ambiante continue, calculée à partir de l'état réel BLE +
batterie (pas besoin de commande) :

| Situation | Rendu |
|---|---|
| Boot (`STATE_INIT`) | Jaune, clignotement rapide |
| Erreur (`STATE_ERROR`) | Rouge, clignotement rapide |
| Non connecté, sur batterie, niveau correct | Bleu, respiration lente |
| Non connecté, sur batterie, niveau bas | Rouge, pulsation unique lente (toutes les 3s) |
| Non connecté, en charge | Ambre, respiration (fixe si pleine charge) |
| Connecté (BLE), sur batterie | Vert, "battement de coeur" (double pulsation) |
| Connecté (BLE), en charge | Cyan, respiration (fixe si pleine charge) |
| Fenêtre de pairing (`pair`, ou appui long bouton) | Magenta, clignotement, 5s |

Les commandes `led <couleur>` et `identify` prennent temporairement la main
sur la LED puis le jeu automatique reprend tout seul (pas de commande
"stop" à envoyer).

## Direction PC -> ESP32 (commandes REPL)

> **Statut actuel : non fonctionnel.** Les commandes ci-dessous sont bien
> écrites sur le port série par le daemon, mais l'ESP32 ne les lit pas :
> `console_read_line()` (basé sur `fgets`/`select` sur stdin USB
> Serial/JTAG) provoque un reset Interrupt Watchdog sur cette combinaison
> matériel/IDF. Le firmware tourne donc actuellement en mode "output-only".
> `handle_command()` reste implémentée et prête à être branchée dès que ce
> point sera résolu (piste : UART dédié, ou version d'IDF corrigée).

| Commande | Réponse attendue |
|---|---|
| `ping` | `pong` |
| `state` | `{"type":"state","value":<state>}` |
| `led <couleur>` | `{"type":"led","color":"<couleur>"}` (red, green, blue, yellow, white, off) |
| `pair` | `{"type":"pairing","status":"started"}` |
| `reset` | `{"type":"reset","status":"ok"}` puis reboot |
| `identify` | `{"type":"identify","status":"ok"}` (LED blanche clignote 5x) |
| `info` | `{"type":"info","chip":"esp32s3","mac":"...","firmware":"0.1.0","state":<n>,"uptime_ms":<n>,"ble_connected":<bool>,"charging":<bool>,"battery_mv":<n>}` |

## États (`app_state_t`)

| Valeur | Nom | LED |
|---|---|---|
| 0 | STATE_INIT | Jaune clignotant |
| 1 | STATE_READY | Bleu clignotant |
| 2 | STATE_PAIRING | Magenta clignotant |
| 3 | STATE_PAIRED | Vert fixe |
| 4 | STATE_ERROR | Rouge clignotant |

## Relais par le daemon

Le daemon ne parse ni ne transforme les lignes JSON venant de l'ESP32 : il
les relaie telles quelles, 1:1, à tous les clients WebSocket connectés.
Dans l'autre sens, chaque message texte reçu d'un client WebSocket est
écrit tel quel (+ `\n`) sur le port série.
