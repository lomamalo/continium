#!/usr/bin/env bash
# Passerelle — installation PERMANENTE de l'extension navigateur dans Firefox.
#
#   ./install-extension.sh
#
# 1. Prepare le XPI dans ~/.local/share/passerelle-extension/
# 2. Desactive la verification de signature pour CE profil (user.js —
#    re-applique a chaque demarrage, reversible en supprimant user.js)
# 3. Il reste UN clic a faire dans Firefox (affiche automatiquement) :
#    about:addons -> engrenage -> "Installer un module depuis un fichier"
#    -> selectionner passerelle.xpi. L'extension est ensuite permanente.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXT_DIR="$HOME/.local/share/passerelle-extension"

echo "==> Passerelle : installation permanente de l'extension Firefox"

# 1. Construire le XPI
mkdir -p "$EXT_DIR"
cd "$ROOT/extension-navigateur"
XPI="$EXT_DIR/passerelle.xpi"
rm -f "$XPI"
zip -qr "$XPI" manifest.json content.js background.js popup.html popup.js
echo "==> [1/3] XPI pret : $XPI"

# 2. Trouver le profil Firefox par defaut (dossier standard ou XDG).
#    La section [InstallXXXX] indique le profil utilise par cette install.
PROFILE_DIR=""
for MOZ_ROOT in "$HOME/.mozilla" "$HOME/.config/mozilla"; do
  INI="$MOZ_ROOT/firefox/profiles.ini"
  [ -f "$INI" ] || continue
  PICK=$(awk -F= '/^\[Install/ {in_install=1; next} /^\[/ {in_install=0} in_install && /^Default=/ {sub(/^Default=/,""); print; exit}' "$INI")
  if [ -n "$PICK" ] && [ -d "$MOZ_ROOT/firefox/$PICK" ]; then
    PROFILE_DIR="$MOZ_ROOT/firefox/$PICK"
    break
  fi
done

if [ -z "$PROFILE_DIR" ] || [ ! -d "$PROFILE_DIR" ]; then
  echo "ERREUR : profil Firefox introuvable. Utilise le chemin par defaut"
  echo "manuellement : copie '$XPI' puis "
  echo "about:addons -> Installer un module depuis un fichier."
  exit 1
fi
echo "==> [2/3] Profil Firefox : $PROFILE_DIR"

# 3. user.js : signature non requise pour ce profil (permanent, sans sudo)
UJ="$PROFILE_DIR/user.js"
touch "$UJ"
if ! grep -q "xpinstall.signatures.required" "$UJ"; then
  printf '\nuser_pref("xpinstall.signatures.required", false);\n' >> "$UJ"
  echo "    verification de signature desactivee (user.js)"
fi

# 4. Instruction finale + ouverture de about:addons
echo "==> [3/3] Termine."
echo
echo "Derniere etape (1 clic, a faire une seule fois) :"
echo "  - Redemarre Firefox (ouvre about:addons maintenant ?)  "
echo "  - about:addons -> engrenage (roue) -> 'Installer un module"
echo "    depuis un fichier...' -> choisis :"
echo "      $XPI"
echo
echo "L'extension Passerelle sera alors installee DEFINITIVEMENT"
echo "(visible dans about:addons, survive aux redemarrages)."
echo
echo "Pour desinstaller : supprime l'extension dans about:addons"
echo "et retire la ligne 'xpinstall.signatures.required' de $UJ"
