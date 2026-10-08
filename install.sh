#!/usr/bin/env bash
# Install the ownwidget plugins into the Omarchy shell.
#   ./install.sh            link plugins, copy icons, enable them
#   ./install.sh --uninstall disable and unlink
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/plugins"
PLUGINS=(rebenga.agents-desk rebenga.projects-bar rebenga.system-desk)

say() { printf '\033[1m%s\033[0m\n' "$*"; }

if [[ ${1:-} == "--uninstall" ]]; then
  for p in "${PLUGINS[@]}"; do
    omarchy plugin disable "$p" >/dev/null 2>&1 || true
    [[ -L "$DEST/$p" ]] && rm "$DEST/$p" && say "unlinked $p"
  done
  omarchy restart shell >/dev/null 2>&1 || true
  exit 0
fi

command -v omarchy >/dev/null || { echo "omarchy not found: these plugins need the Omarchy shell" >&2; exit 1; }
mkdir -p "$DEST"

for p in "${PLUGINS[@]}"; do
  if [[ -e "$DEST/$p" && ! -L "$DEST/$p" ]]; then
    echo "$DEST/$p exists and is not a link — move it away first" >&2
    exit 1
  fi
  ln -sfn "$REPO/plugins/$p" "$DEST/$p"
  say "linked $p"
done

# App icons come from the installed system (not shipped in the repo).
assets="$REPO/plugins/rebenga.projects-bar/assets"
mkdir -p "$assets"
copy_icon() { [[ -f "$1" ]] && cp "$1" "$assets/$2" || echo "  (icon missing: $1)"; }
copy_icon /usr/share/omarchy/shell/plugins/agents/assets/claude.svg claude.svg
copy_icon /usr/share/icons/hicolor/scalable/apps/org.gnome.Nautilus.svg files.svg
if [[ -f /usr/share/pixmaps/vscode.png ]]; then
  if command -v magick >/dev/null; then magick /usr/share/pixmaps/vscode.png -resize 128x128 "$assets/vscode.png"
  else cp /usr/share/pixmaps/vscode.png "$assets/vscode.png"; fi
fi

for p in "${PLUGINS[@]}"; do omarchy plugin enable "$p" >/dev/null && say "enabled $p"; done
# Plugin hot-reload keeps old QML cached; a restart picks up new code.
omarchy restart shell >/dev/null 2>&1 || true

cat <<MSG

Done. Optional keybindings for ~/.config/hypr/bindings.lua:

  o.bind("SUPER + ALT + A", "Agents: next Claude/Codex session", "python3 -I $DEST/rebenga.agents-desk/collect.py --jump")
  o.bind("SUPER + ALT + P", "Projects picker", "omarchy-shell projects picker")
MSG
