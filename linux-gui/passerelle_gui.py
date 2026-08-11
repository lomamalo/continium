#!/usr/bin/env python3
"""
Passerelle - Panneau de controle Linux.
Continium — conçu et développé par Malo Lemoine (github.com/lomamalo/continium).

Petite interface graphique (Tkinter, aucune dependance externe hors
python3-tk) pour piloter le daemon, compiler/flasher le firmware ESP32,
et compiler l'application Android -- sans avoir a taper de commandes.

Lance directement : python3 linux-gui/passerelle_gui.py
Ou via le lanceur installe par scripts/install.sh (menu applications).
"""
from __future__ import annotations

import glob
import json
import os
import queue
import shutil
import signal
import subprocess
import sys
import threading
import time
import tkinter as tk
import urllib.error
import urllib.request
from pathlib import Path
from tkinter import ttk, filedialog, messagebox

# ---------------------------------------------------------------------------
# Palette (identique a l'app Android, voir android-app/lib/main.dart)
# ---------------------------------------------------------------------------
BG = "#0A0A0A"
CARD = "#141414"
CARD_ALT = "#1B1B1B"
DIVIDER = "#2A2A2A"
ACCENT = "#64FFDA"
TEXT_PRIMARY = "#E0E0E0"
TEXT_SECONDARY = "#888888"
GREEN = "#4CAF50"
RED = "#FF5252"
ORANGE = "#FFAB40"
BLUE = "#448AFF"

PROJECT_ROOT = Path(__file__).resolve().parent.parent
DAEMON_DIR = PROJECT_ROOT / "linux-daemon"
FIRMWARE_DIR = PROJECT_ROOT / "esp32-firmware"
ANDROID_DIR = PROJECT_ROOT / "android-app"
SCRIPTS_DIR = PROJECT_ROOT / "scripts"
LOGO_PATH = PROJECT_ROOT / "android-app" / "assets" / "continium.png"

CONFIG_DIR = Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config")) / "passerelle"
CONFIG_FILE = CONFIG_DIR / "gui.json"

DEFAULT_CONFIG = {
    "serial_port": "/dev/ttyACM0",
    "serial_baud": "115200",
    "ws_port": "8080",
    "http_port": "8081",
    "clipboard_watch": "1",
}


def load_config() -> dict:
    try:
        with open(CONFIG_FILE, "r", encoding="utf-8") as f:
            data = json.load(f)
        merged = dict(DEFAULT_CONFIG)
        merged.update(data)
        return merged
    except (FileNotFoundError, json.JSONDecodeError):
        return dict(DEFAULT_CONFIG)


def save_config(cfg: dict) -> None:
    CONFIG_DIR.mkdir(parents=True, exist_ok=True)
    with open(CONFIG_FILE, "w", encoding="utf-8") as f:
        json.dump(cfg, f, indent=2)


def detect_serial_ports() -> list[str]:
    candidates = sorted(glob.glob("/dev/ttyACM*") + glob.glob("/dev/ttyUSB*"))
    return candidates


class ProcessRunner:
    """Lance une commande dans un thread separe et pousse chaque ligne de
    sortie dans une queue thread-safe consommee par l'UI via `after()`."""

    def __init__(self, out_queue: "queue.Queue[str]"):
        self.out_queue = out_queue
        self.proc: subprocess.Popen | None = None
        self._thread: threading.Thread | None = None

    def running(self) -> bool:
        return self.proc is not None and self.proc.poll() is None

    def start(self, cmd: list[str], cwd: Path | None = None, shell_cmd: str | None = None,
              on_exit=None):
        if self.running():
            self.out_queue.put("[deja en cours]\n")
            return

        def target():
            try:
                if shell_cmd is not None:
                    self.proc = subprocess.Popen(
                        ["bash", "-lc", shell_cmd], cwd=str(cwd) if cwd else None,
                        stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                        text=True, bufsize=1,
                    )
                else:
                    self.proc = subprocess.Popen(
                        cmd, cwd=str(cwd) if cwd else None,
                        stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                        text=True, bufsize=1,
                    )
                assert self.proc.stdout is not None
                for line in self.proc.stdout:
                    self.out_queue.put(line)
                self.proc.wait()
                self.out_queue.put(f"\n[termine, code {self.proc.returncode}]\n")
            except FileNotFoundError as e:
                self.out_queue.put(f"\n[erreur] commande introuvable: {e}\n")
            except Exception as e:  # noqa: BLE001
                self.out_queue.put(f"\n[erreur] {e}\n")
            finally:
                if on_exit:
                    self.out_queue.put(("__EXIT__", on_exit))

        self._thread = threading.Thread(target=target, daemon=True)
        self._thread.start()

    def stop(self):
        if self.running():
            try:
                self.proc.send_signal(signal.SIGTERM)
            except ProcessLookupError:
                pass


class StatusDot(tk.Canvas):
    def __init__(self, master, color=RED, size=12, **kw):
        super().__init__(master, width=size, height=size, bg=CARD,
                          highlightthickness=0, **kw)
        self.size = size
        self._id = self.create_oval(1, 1, size - 1, size - 1, fill=color, outline="")

    def set_color(self, color):
        self.itemconfig(self._id, fill=color)


class Section(tk.Frame):
    """Carte arrondie-ish (tkinter ne fait pas de vrais coins arrondis,
    on simule avec un cadre + bordure fine, coherent avec le style dark)."""

    def __init__(self, master, title, icon_text="", **kw):
        super().__init__(master, bg=CARD, highlightbackground=DIVIDER,
                          highlightthickness=1, **kw)
        header = tk.Frame(self, bg=CARD)
        header.pack(fill="x", padx=14, pady=(12, 6))
        tk.Label(header, text=title, bg=CARD, fg=ACCENT,
                  font=("Sans", 11, "bold")).pack(side="left")
        self.body = tk.Frame(self, bg=CARD)
        self.body.pack(fill="both", expand=True, padx=14, pady=(0, 14))


class PasserelleGUI(tk.Tk):
    def __init__(self):
        super().__init__()
        self.title("Passerelle - Panneau de controle")
        self.geometry("880x640")
        self.configure(bg=BG)
        self.minsize(760, 560)

        self.cfg = load_config()
        self.daemon_runner = ProcessRunner(self._make_queue("daemon"))
        self.firmware_runner = ProcessRunner(self._make_queue("firmware"))
        self.android_runner = ProcessRunner(self._make_queue("android"))

        self._build_style()
        self._build_layout()
        self.after(150, self._poll_queues)
        self.after(1000, self._refresh_daemon_status)

        self.protocol("WM_DELETE_WINDOW", self._on_close)

    # -- infra ---------------------------------------------------------
    def _make_queue(self, name):
        q: "queue.Queue[str]" = queue.Queue()
        setattr(self, f"_{name}_queue", q)
        return q

    def _build_style(self):
        style = ttk.Style(self)
        try:
            style.theme_use("clam")
        except tk.TclError:
            pass
        style.configure("TNotebook", background=BG, borderwidth=0)
        style.configure("TNotebook.Tab", background=CARD, foreground=TEXT_SECONDARY,
                         padding=(14, 8), borderwidth=0)
        style.map("TNotebook.Tab",
                  background=[("selected", CARD_ALT)],
                  foreground=[("selected", ACCENT)])
        style.configure("TCombobox", fieldbackground=CARD_ALT, background=CARD_ALT,
                         foreground=TEXT_PRIMARY, arrowcolor=TEXT_PRIMARY)
        style.configure("Accent.TButton", background=ACCENT, foreground="#04201A",
                         font=("Sans", 10, "bold"), padding=(12, 6), borderwidth=0)
        style.map("Accent.TButton", background=[("active", "#8CFFE8")])
        style.configure("Flat.TButton", background=CARD_ALT, foreground=TEXT_PRIMARY,
                         padding=(10, 6), borderwidth=1)
        style.map("Flat.TButton", background=[("active", DIVIDER)])
        style.configure("Danger.TButton", background=RED, foreground="#210000",
                         padding=(10, 6), borderwidth=0)
        style.configure("Flat.TCheckbutton", background=BG, foreground=TEXT_SECONDARY,
                         focuscolor=BG, indicatormargin=2)

    def _build_layout(self):
        header = tk.Frame(self, bg=BG)
        header.pack(fill="x", padx=18, pady=(16, 8))

        if LOGO_PATH.exists():
            try:
                img = tk.PhotoImage(file=str(LOGO_PATH))
                # sous-echantillonnage grossier si l'image est grande
                factor = max(1, img.width() // 40)
                if factor > 1:
                    img = img.subsample(factor, factor)
                self._logo_img = img
                tk.Label(header, image=img, bg=BG).pack(side="left", padx=(0, 10))
            except tk.TclError:
                pass

        title_box = tk.Frame(header, bg=BG)
        title_box.pack(side="left")
        tk.Label(title_box, text="Passerelle", bg=BG, fg=TEXT_PRIMARY,
                  font=("Sans", 16, "bold")).pack(anchor="w")
        tk.Label(title_box, text="Continuite PC <-> telephone via ESP32",
                  bg=BG, fg=TEXT_SECONDARY, font=("Sans", 9)).pack(anchor="w")

        # -- status card --
        status = Section(self, "Etat du daemon")
        status.pack(fill="x", padx=18, pady=6)

        row = tk.Frame(status.body, bg=CARD)
        row.pack(fill="x")
        self.status_dot = StatusDot(row, color=RED)
        self.status_dot.pack(side="left", padx=(0, 8))
        self.status_label = tk.Label(row, text="Arrete", bg=CARD, fg=TEXT_PRIMARY,
                                       font=("Sans", 10, "bold"))
        self.status_label.pack(side="left")

        btns = tk.Frame(row, bg=CARD)
        btns.pack(side="right")
        ttk.Button(btns, text="Demarrer", style="Accent.TButton",
                   command=self.start_daemon).pack(side="left", padx=4)
        ttk.Button(btns, text="Arreter", style="Danger.TButton",
                   command=self.stop_daemon).pack(side="left", padx=4)
        ttk.Button(btns, text="Recompiler le daemon", style="Flat.TButton",
                   command=self.build_daemon).pack(side="left", padx=4)

        cfg_row = tk.Frame(status.body, bg=CARD)
        cfg_row.pack(fill="x", pady=(12, 0))

        self.port_var = tk.StringVar(value=self.cfg["serial_port"])
        self.baud_var = tk.StringVar(value=self.cfg["serial_baud"])
        self.wsport_var = tk.StringVar(value=self.cfg["ws_port"])

        self._labeled_entry(cfg_row, "Port serie ESP32", self.port_var, width=16)
        self.port_combo = ttk.Combobox(cfg_row, textvariable=self.port_var, width=16,
                                         values=detect_serial_ports())
        self.port_combo.pack(side="left", padx=(0, 4))
        ttk.Button(cfg_row, text="Detecter", style="Flat.TButton",
                   command=self._detect_ports).pack(side="left", padx=(0, 16))

        self._labeled_entry(cfg_row, "Baud", self.baud_var, width=8)
        self._labeled_entry(cfg_row, "Port WebSocket", self.wsport_var, width=8)
        self.http_port_var = tk.StringVar(value=self.cfg.get("http_port", "8081"))
        self._labeled_entry(cfg_row, "Port HTTP", self.http_port_var, width=8)

        # -- notebook --
        nb = ttk.Notebook(self)
        nb.pack(fill="both", expand=True, padx=18, pady=(10, 16))

        self.cont_status, self.cont_log = self._build_continuity_tab(nb)
        self.log_text = self._build_log_tab(nb, "Journal du daemon")
        self._build_firmware_tab(nb)
        self._build_android_tab(nb)

        self.last_clipboard = None
        self._poll_clipboard()

    def _labeled_entry(self, parent, label, var, width=12):
        box = tk.Frame(parent, bg=CARD)
        box.pack(side="left", padx=(0, 4))
        tk.Label(box, text=label, bg=CARD, fg=TEXT_SECONDARY,
                  font=("Sans", 8)).pack(anchor="w")
        e = tk.Entry(box, textvariable=var, width=width, bg=CARD_ALT,
                      fg=TEXT_PRIMARY, insertbackground=TEXT_PRIMARY,
                      relief="flat", highlightthickness=1,
                      highlightbackground=DIVIDER, highlightcolor=ACCENT)
        e.pack()
        return e

    def _build_continuity_tab(self, nb):
        """Continuity: tout ce qui se passe sur le PC (copier-coller, liens
        YouTube, textes) est envoye automatiquement sur le telephone, plus un
        champ d'ajout manuel. Envoi = POST JSON au daemon (endpoint /continuity)."""
        frame = tk.Frame(nb, bg=BG)
        nb.add(frame, text="Continuity")

        status = tk.Frame(frame, bg=BG)
        status.pack(fill="x", padx=8, pady=(10, 4))
        self.cont_dot = StatusDot(status, color=ORANGE, size=10)
        self.cont_dot.pack(side="left", padx=(0, 6))
        self.cont_status = tk.Label(
            status, text="Surveillance du presse-papiers : arretee",
            bg=BG, fg=TEXT_SECONDARY, font=("Sans", 9),
        )
        self.cont_status.pack(side="left")
        self.cont_watch_var = tk.BooleanVar(value=self.cfg.get("clipboard_watch", "1") == "1")
        ttk.Checkbutton(
            status, text="Surveiller le presse-papiers", variable=self.cont_watch_var,
            command=self._toggle_clipboard_watch, style="Flat.TCheckbutton",
        ).pack(side="right")

        manual = Section(frame, "Ajouter un element manuellement")
        manual.pack(fill="x", padx=8, pady=4)
        self.cont_entry = tk.Text(
            manual.body, height=3, bg=CARD_ALT, fg=TEXT_PRIMARY,
            insertbackground=TEXT_PRIMARY, relief="flat",
            highlightthickness=1, highlightbackground=DIVIDER,
            highlightcolor=ACCENT, wrap="word", font=("Sans", 10),
        )
        self.cont_entry.pack(fill="x")
        ttk.Button(
            manual.body, text="Envoyer sur le telephone", style="Accent.TButton",
            command=self.send_manual_item,
        ).pack(anchor="e", pady=(8, 0))
        ttk.Button(
            manual.body, text="Envoyer le fichier actif", style="Flat.TButton",
            command=self.send_active_file,
        ).pack(anchor="e", pady=(4, 0))

        log_box = Section(frame, "Elements envoyes recemment")
        log_box.pack(fill="both", expand=True, padx=8, pady=4)
        self.cont_log = tk.Text(
            log_box.body, bg="#050505", fg=TEXT_PRIMARY, insertbackground=TEXT_PRIMARY,
            relief="flat", wrap="word", state="disabled", font=("Monospace", 9),
        )
        self.cont_log.pack(fill="both", expand=True)
        return self.cont_status, self.cont_log

    def _toggle_clipboard_watch(self):
        self.cfg["clipboard_watch"] = "1" if self.cont_watch_var.get() else "0"
        save_config(self.cfg)
        self._update_clipboard_status()

    def _update_clipboard_status(self, daemon_up=None):
        watching = self.cont_watch_var.get()
        if not watching:
            self.cont_dot.set_color(RED)
            text = "Surveillance du presse-papiers : arretee"
        elif daemon_up:
            self.cont_dot.set_color(GREEN)
            text = "Surveillance activee - daemon connecte"
        else:
            self.cont_dot.set_color(ORANGE)
            text = "Surveillance activee - daemon injoignable"
        self.cont_status.configure(text=text)

    def _daemon_up(self):
        # GET / renvoie 404 (aucune route GET) : une reponse HTTP quelconque
        # prouve que le daemon repond. Seule une erreur de connexion (refus)
        # signifie qu'il est arrete.
        try:
            urllib.request.urlopen(
                f"http://127.0.0.1:{self.cfg.get('http_port', '8081')}/", timeout=0.4
            )
            return True
        except urllib.error.HTTPError:
            return True
        except Exception:  # noqa: BLE001
            return False

    def _poll_clipboard(self):
        count = getattr(self, "_poll_count", 0) + 1
        self._poll_count = count
        try:
            if self.cont_watch_var.get():
                try:
                    content = self.clipboard_get()
                except tk.TclError:
                    content = ""
                content = (content or "").strip()
                if content and content != self.last_clipboard:
                    self.last_clipboard = content
                    self._send_to_daemon(content, "clipboard", log=True)
                # La sonde daemon ne sert qu'a l'affichage de la pastille et
                # ne bloque jamais le chemin d'envoi (toutes les ~1 s seulement).
                if count == 1 or count % 5 == 0:
                    self._update_clipboard_status(self._daemon_up())
        finally:
            self.after(200, self._poll_clipboard)

    def send_manual_item(self):
        content = self.cont_entry.get("1.0", "end").strip()
        if not content:
            messagebox.showinfo("Passerelle", "Rien a envoyer : le champ est vide.")
            return
        self._send_to_daemon(content, "manual", log=True)
        self.cont_entry.delete("1.0", "end")

    def send_active_file(self):
        """Lance scripts/send_active_file.py (detection de la fenetre active
        via hyprctl/xdotool, selecteur de fichier en secours) et affiche le
        resultat dans le journal Continuity sans bloquer l'UI."""

        def run():
            script = SCRIPTS_DIR / "send_active_file.py"
            http_port = self.cfg.get("http_port", "8081")
            try:
                proc = subprocess.run(
                    [sys.executable, str(script), "--daemon", f"http://127.0.0.1:{http_port}"],
                    capture_output=True, text=True, timeout=120,
                )
                out = (proc.stdout or "").strip() or (proc.stderr or "").strip()
            except Exception as e:  # noqa: BLE001
                out = f"ERREUR : {e}"
            self.after(0, lambda: self._append(
                self.cont_log, f"[{time.strftime('%H:%M:%S')}] fichier actif : {out}\n"))

        threading.Thread(target=run, daemon=True).start()

    def _send_to_daemon(self, content, source, log=True):
        url = f"http://127.0.0.1:{self.cfg.get('http_port', '8081')}/continuity"
        payload = json.dumps({"content": content, "source": source}).encode("utf-8")
        try:
            req = urllib.request.Request(
                url, data=payload, headers={"Content-Type": "application/json"})
            with urllib.request.urlopen(req, timeout=5) as resp:
                ok = resp.status == 200
        except Exception as e:  # noqa: BLE001
            ok = False
            detail = str(e)
        if ok:
            self._update_clipboard_status(daemon_up=True)
            if log:
                self._append(self.cont_log,
                             f"[{time.strftime('%H:%M:%S')}] {source}: {content[:120]}\n")
        elif log:
            self._append(self.cont_log,
                         f"[{time.strftime('%H:%M:%S')}] ECHEC envoi ({source}): {detail}\n")

    def _build_log_tab(self, nb, title):
        frame = tk.Frame(nb, bg=BG)
        nb.add(frame, text="Journal")
        text = tk.Text(frame, bg="#050505", fg=TEXT_PRIMARY, insertbackground=TEXT_PRIMARY,
                        relief="flat", wrap="word", state="disabled",
                        font=("Monospace", 9))
        text.pack(fill="both", expand=True, padx=4, pady=4)
        return text

    def _build_firmware_tab(self, nb):
        frame = tk.Frame(nb, bg=BG)
        nb.add(frame, text="Firmware ESP32")

        info = tk.Label(
            frame,
            text=(
                "Etapes : 1) installer ESP-IDF (une seule fois)  "
                "2) compiler  3) flasher sur la carte via le port serie ci-dessus."
            ),
            bg=BG, fg=TEXT_SECONDARY, wraplength=780, justify="left",
        )
        info.pack(anchor="w", padx=8, pady=(10, 10))

        btns = tk.Frame(frame, bg=BG)
        btns.pack(anchor="w", padx=8, pady=4)
        ttk.Button(btns, text="1. Installer ESP-IDF", style="Flat.TButton",
                   command=self.install_esp_idf).pack(side="left", padx=4)
        ttk.Button(btns, text="2. Compiler le firmware", style="Flat.TButton",
                   command=self.build_firmware).pack(side="left", padx=4)
        ttk.Button(btns, text="3. Flasher l'ESP32", style="Accent.TButton",
                   command=self.flash_firmware).pack(side="left", padx=4)

        self.firmware_log = tk.Text(frame, bg="#050505", fg=TEXT_PRIMARY,
                                     insertbackground=TEXT_PRIMARY, relief="flat",
                                     wrap="word", state="disabled", font=("Monospace", 9))
        self.firmware_log.pack(fill="both", expand=True, padx=8, pady=8)

    def _build_android_tab(self, nb):
        frame = tk.Frame(nb, bg=BG)
        nb.add(frame, text="Application Android")

        info = tk.Label(
            frame,
            text=(
                "Necessite le SDK Flutter installe et accessible dans le PATH. "
                "Genere un APK debug ou release pret a installer sur telephone."
            ),
            bg=BG, fg=TEXT_SECONDARY, wraplength=780, justify="left",
        )
        info.pack(anchor="w", padx=8, pady=(10, 10))

        btns = tk.Frame(frame, bg=BG)
        btns.pack(anchor="w", padx=8, pady=4)
        ttk.Button(btns, text="Compiler APK (debug)", style="Flat.TButton",
                   command=lambda: self.build_android("debug")).pack(side="left", padx=4)
        ttk.Button(btns, text="Compiler APK (release)", style="Accent.TButton",
                   command=lambda: self.build_android("release")).pack(side="left", padx=4)
        ttk.Button(btns, text="Ouvrir le dossier de sortie", style="Flat.TButton",
                   command=self.open_apk_folder).pack(side="left", padx=4)

        self.android_log = tk.Text(frame, bg="#050505", fg=TEXT_PRIMARY,
                                    insertbackground=TEXT_PRIMARY, relief="flat",
                                    wrap="word", state="disabled", font=("Monospace", 9))
        self.android_log.pack(fill="both", expand=True, padx=8, pady=8)

    # -- actions ---------------------------------------------------------
    def _save_cfg(self):
        self.cfg["serial_port"] = self.port_var.get()
        self.cfg["serial_baud"] = self.baud_var.get()
        self.cfg["ws_port"] = self.wsport_var.get()
        self.cfg["http_port"] = self.http_port_var.get() if hasattr(self, "http_port_var") else self.cfg.get("http_port", "8081")
        save_config(self.cfg)

    def _detect_ports(self):
        ports = detect_serial_ports()
        self.port_combo["values"] = ports
        if ports:
            self.port_var.set(ports[0])
        else:
            messagebox.showinfo("Passerelle", "Aucun port serie detecte (/dev/ttyACM*, /dev/ttyUSB*).")

    def daemon_binary(self) -> Path:
        return DAEMON_DIR / "target" / "release" / "passerelle-daemon"

    def start_daemon(self):
        self._save_cfg()
        binary = self.daemon_binary()
        if not binary.exists():
            if not messagebox.askyesno(
                "Passerelle",
                "Le daemon n'est pas encore compile. Le compiler maintenant "
                "(cargo build --release) ? Cela peut prendre une a deux minutes.",
            ):
                return
            self.build_daemon(then_start=True)
            return
        self._append(self.log_text, f"$ {binary} --serial-port {self.port_var.get()} "
                                     f"--serial-baud {self.baud_var.get()} --ws-port {self.wsport_var.get()} "
                                     f"--http-port {self.http_port_var.get()}\n")
        self.daemon_runner.start([
            str(binary),
            "--serial-port", self.port_var.get(),
            "--serial-baud", self.baud_var.get(),
            "--ws-port", self.wsport_var.get(),
            "--http-port", self.http_port_var.get(),
        ])

    def stop_daemon(self):
        self.daemon_runner.stop()

    def build_daemon(self, then_start=False):
        self._append(self.log_text, "$ cargo build --release\n")
        self.daemon_runner.start(
            ["cargo", "build", "--release"], cwd=DAEMON_DIR,
            on_exit=(self.start_daemon if then_start else None),
        )

    def install_esp_idf(self):
        script = SCRIPTS_DIR / "install-esp-idf.sh"
        self._append(self.firmware_log, f"$ {script}\n")
        self.firmware_runner.start(["bash", str(script)])

    def build_firmware(self):
        script = SCRIPTS_DIR / "build-esp32.sh"
        self._append(self.firmware_log, f"$ {script}\n")
        self.firmware_runner.start(["bash", str(script)])

    def flash_firmware(self):
        self._save_cfg()
        port = self.port_var.get()
        cmd = (
            f'source "$HOME/esp/esp-idf/export.sh" && '
            f'cd "{FIRMWARE_DIR}" && idf.py -p {port} flash'
        )
        self._append(self.firmware_log, f"$ {cmd}\n")
        self.firmware_runner.start([], shell_cmd=cmd)

    def build_android(self, mode: str):
        script = SCRIPTS_DIR / "build-android.sh"
        self._append(self.android_log, f"$ {script} {mode}\n")
        self.android_runner.start(["bash", str(script), mode])

    def open_apk_folder(self):
        out_dir = ANDROID_DIR / "build" / "app" / "outputs" / "flutter-apk"
        if not out_dir.exists():
            messagebox.showinfo("Passerelle", "Aucun APK compile pour le moment.")
            return
        opener = shutil.which("xdg-open")
        if opener:
            subprocess.Popen([opener, str(out_dir)])
        else:
            filedialog.askdirectory(initialdir=str(out_dir))

    # -- queue polling / log rendering -----------------------------------
    def _append(self, widget: tk.Text, text: str):
        widget.configure(state="normal")
        widget.insert("end", text)
        widget.see("end")
        widget.configure(state="disabled")

    def _poll_queues(self):
        for widget, q in (
            (self.log_text, self._daemon_queue),
            (self.firmware_log, self._firmware_queue),
            (self.android_log, self._android_queue),
        ):
            try:
                while True:
                    item = q.get_nowait()
                    if isinstance(item, tuple) and item and item[0] == "__EXIT__":
                        callback = item[1]
                        if callback:
                            self.after(300, callback)
                        continue
                    self._append(widget, item)
            except queue.Empty:
                pass
        self.after(150, self._poll_queues)

    def _refresh_daemon_status(self):
        running = self.daemon_runner.running()
        self.status_dot.set_color(GREEN if running else RED)
        self.status_label.configure(text="En cours" if running else "Arrete")
        self.after(1000, self._refresh_daemon_status)

    def _on_close(self):
        self._save_cfg()
        self.destroy()


def main():
    if sys.platform != "linux":
        print("Ce panneau de controle est concu pour Linux.")
    app = PasserelleGUI()
    app.mainloop()


if __name__ == "__main__":
    main()
