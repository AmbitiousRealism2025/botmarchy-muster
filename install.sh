#!/usr/bin/env bash
# Botmarchy Muster — plugin installer.
#
# `omarchy plugin add` only clones the plugin (Panel.qml + manifest). This
# script puts the companion scripts where the panel expects them:
#
#   bin/botmarchy-muster   → ~/.local/bin   (roster window; Panel launch path)
#   bin/botmarchy-focus    → ~/.local/bin   (focus/launch helper)
#   box/muster-snapshot.py → the GATEWAY box, as ~/.local/bin/botmarchy-muster-snapshot
#                            (only with --box user@host; skipped otherwise)
#
# Symlinks, not copies: `omarchy plugin update` refreshes the plugin dir and
# every linked script follows. Idempotent — re-run any time.

set -euo pipefail

PLUGIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOCAL_BIN="$HOME/.local/bin"

mkdir -p "$LOCAL_BIN"

for script in botmarchy-muster botmarchy-focus; do
  target="$LOCAL_BIN/$script"
  rm -f "$target"
  ln -s "$PLUGIN_DIR/bin/$script" "$target"
  echo "linked $target -> $PLUGIN_DIR/bin/$script"
done

# --box user@host: push the snapshot script to the gateway (idempotent).
if [[ "${1:-}" == "--box" ]]; then
  box="${2:?usage: install.sh [--box user@host]}"
  ssh -o BatchMode=yes "$box" 'mkdir -p ~/.local/bin'
  scp -q "$PLUGIN_DIR/box/muster-snapshot.py" "$box:~/.local/bin/botmarchy-muster-snapshot"
  ssh -o BatchMode=yes "$box" 'chmod +x ~/.local/bin/botmarchy-muster-snapshot'
  echo "installed botmarchy-muster-snapshot on $box"
elif [[ $# -gt 0 ]]; then
  echo "usage: install.sh [--box user@host]" >&2
  exit 1
fi

echo
echo "Done. If the bar widget is not showing yet:"
echo "  omarchy plugin enable dev.botmarchy.muster --section right"
echo "  pkill quickshell   # re-renders the bar (auto-respawns)"
echo
echo "To point it at your gateway:"
echo "  omarchy bar set dev.botmarchy.muster sshTarget user@host"
echo "  omarchy bar set dev.botmarchy.muster intervalSec 10"
