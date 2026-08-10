#!/usr/bin/env python3
"""
Envoie le fichier actuellement ouvert dans l'editeur au tampon Passerelle.

Detection de la fenetre active :
  - Hyprland : `hyprctl activewindow` (titre apres "-> ")
  - X11      : `xdotool getactivewindow getwindowname`

Resolution du chemin : le titre de l'editeur (VS Code, gedit, Kate, vim...)
contient generalement le nom du fichier, parfois le chemin absolu. On retire
les suffixes connus, puis on cherche le fichier dans les dossiers usuels.
Si rien ne matche : selecteur de fichier (zenity) ou argument --file.

Usage :
  python3 scripts/send-active-file.py
  python3 scripts/send-active-file.py --file /chemin/vers/notes.md
  python3 scripts/send-active-file.py --daemon http://127.0.0.1:8081
"""
from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import urllib.request
from pathlib import Path

DEFAULT_DAEMON = "http://127.0.0.1:8081"

# Suffixes de titre par editeur, a retirer pour retrouver le nom du fichier.
TITLE_SUFFIXES = [
    " - Visual Studio Code", " - Code - OSS", " - gedit", " - Kate",
    " - Sublime Text", " - Atom", " - emacs", " - Emacs", " - VIM",
    " - NVIM", " - vim", " - nvim", " - nano", " - Text Editor",
    " - Obsidian", " - LibreOffice Writer", " - Writer", " - Firefox",
    " - Tor Browser", " - Google Chrome", " - Chromium",
]

# Dossiers ou chercher le fichier par nom (profondeur 2 max).
SEARCH_DIRS = ["~/Bureau", "~/Documents", "~/Téléchargements", "~/Images",
               "~/Projets", "~/dev", "~/code", "~/projects", "~"]


def active_window_title() -> str | None:
    try:
        out = subprocess.run(
            ["hyprctl", "activewindow"], capture_output=True, text=True, timeout=3
        ).stdout
        for line in out.splitlines():
            if "-> " in line:
                return line.split("-> ", 1)[1].rstrip(":").strip()
    except (FileNotFoundError, subprocess.SubprocessError):
        pass
    try:
        out = subprocess.run(
            ["xdotool", "getactivewindow", "getwindowname"],
            capture_output=True, text=True, timeout=3,
        )
        if out.returncode == 0:
            return out.stdout.strip()
    except (FileNotFoundError, subprocess.SubprocessError):
        pass
    return None


def strip_suffixes(title: str) -> str:
    for suffix in TITLE_SUFFIXES:
        if title.lower().endswith(suffix.lower()):
            return title[: -len(suffix)].strip()
    return title


def resolve_path(title: str) -> Path | None:
    """Tente d'extraire un chemin existant depuis le titre de la fenetre."""
    candidate = strip_suffixes(title).strip()
    if not candidate:
        return None

    # "notes.md — /home/me/proj — Visual Studio Code" -> nom + dossiers.
    parts = [p.strip() for p in re.split(r"\s+[—-]\s+", candidate) if p.strip()]

    dirs_to_try: list[Path] = []
    name: str | None = None
    for i, part in enumerate(parts):
        if part.startswith("/"):
            p = Path(part)
            if p.is_file():
                return p
            if p.is_dir():
                dirs_to_try.append(p)
        elif i == 0:
            name = part

    # Chemin absolu direct dans le titre (gedit/Kate).
    if name is None and parts and parts[0].startswith("/"):
        p = Path(parts[0])
        if p.is_file():
            return p

    if name is None:
        return None

    # nom seul : chercher dans les dossiers usuels + dossiers du titre + cwd.
    search_dirs = [*SEARCH_DIRS, *[str(d) for d in dirs_to_try], str(Path.cwd())]
    found: list[Path] = []
    for base in search_dirs:
        root = Path(base).expanduser()
        if not root.is_dir():
            continue
        direct = root / name
        if direct.is_file():
            found.append(direct)
            continue
        try:
            for child in root.iterdir():
                if child.is_file() and child.name == name:
                    found.append(child)
                elif child.is_dir() and not child.name.startswith("."):
                    try:
                        for sub in child.iterdir():
                            if sub.is_file() and sub.name == name:
                                found.append(sub)
                    except PermissionError:
                        pass
        except PermissionError:
            pass
    return found[0] if len(found) == 1 else (found[0] if found else None)


def pick_file(basename: str | None) -> Path | None:
    try:
        import tkinter as tk
        from tkinter import filedialog

        root = tk.Tk()
        root.withdraw()
        root.attributes("-topmost", True)
        path = filedialog.askopenfilename(
            title="Envoyer un fichier au tampon",
            initialfile=basename or "",
        )
        root.destroy()
        if path:
            return Path(path)
        return None
    except Exception:  # noqa: BLE001
        try:
            out = subprocess.run(
                ["zenity", "--file-selection",
                 *([] if not basename else ["--filename", basename])],
                capture_output=True, text=True, timeout=60,
            )
            if out.returncode == 0 and out.stdout.strip():
                return Path(out.stdout.strip())
        except (FileNotFoundError, subprocess.SubprocessError):
            pass
    return None


def kind_for_path(path: Path) -> str:
    ext = path.suffix.lower().lstrip(".")
    return {
        "md": "markdown", "markdown": "markdown",
        "txt": "texte", "text": "texte", "log": "texte", "csv": "texte",
        "json": "code", "html": "code", "htm": "code",
        "rs": "code", "c": "code", "h": "code", "py": "code", "js": "code",
        "ts": "code", "go": "code", "java": "code", "cpp": "code",
        "sh": "code", "toml": "code", "yaml": "code", "yml": "code",
    }.get(ext, "texte")


def read_content(path: Path) -> tuple[str, str]:
    """Retourne (content, kind). Les binaires sont decrits, pas lus."""
    size = path.stat().st_size
    if size > 4 * 1024 * 1024:
        return f"(fichier trop gros : {size} octets)", "texte"
    try:
        return path.read_text(encoding="utf-8", errors="strict"), kind_for_path(path)
    except (UnicodeDecodeError, OSError):
        return f"(fichier binaire : {size} octets)", "texte"


def send(daemon: str, path: Path) -> bool:
    content, kind = read_content(path)
    payload = json.dumps({
        "content": content,
        "source": "hotkey",
        "category": "fichier",
        "kind": kind,
        "title": path.name,
        "meta": {"path": str(path), "mime": "text/markdown" if kind == "markdown" else "text/plain"},
    }).encode("utf-8")
    req = urllib.request.Request(
        daemon.rstrip("/") + "/continuity",
        data=payload, headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=10) as resp:
        return resp.status == 200


def main() -> int:
    ap = argparse.ArgumentParser(description="Envoie le fichier actif au tampon Passerelle")
    ap.add_argument("--file", help="chemin du fichier (contourne la detection)")
    ap.add_argument("--daemon", default=DEFAULT_DAEMON, help=f"daemon HTTP (defaut: {DEFAULT_DAEMON})")
    ap.add_argument("--print", action="store_true", help="affiche seulement le fichier detecte")
    args = ap.parse_args()

    path: Path | None = None
    title = None
    if args.file:
        path = Path(args.file).expanduser()
        if not path.is_file():
            print(f"ERREUR : fichier introuvable : {path}")
            return 2
    else:
        title = active_window_title()
        if title:
            path = resolve_path(title)
    if path is None:
        name = strip_suffixes(title).strip() if title else None
        if not args.print:
            print(f"Detection impossible (fenetre : {title or 'inconnue'}) "
                  f"-- ouverture du selecteur de fichier...")
        path = pick_file(Path(name).name if name else None)
        if path is None:
            print("ERREUR : aucun fichier choisi")
            return 1
    if args.print:
        print(path)
        return 0
    try:
        send(args.daemon, path)
    except Exception as e:  # noqa: BLE001
        print(f"ERREUR : envoi echoue ({e})")
        return 1
    print(f"OK : {path.name} ({path}) envoye au tampon")
    return 0


if __name__ == "__main__":
    sys.exit(main())
