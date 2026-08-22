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
# every linked script follows. Idempotent — re-run any time. Pre-existing
# files that are not ours are never touched (PB-7 review F7).

set -euo pipefail

PLUGIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOCAL_BIN="$HOME/.local/bin"

usage() {
  echo "usage: install.sh [--box user@host]" >&2
  exit 1
}

# ── Validate arguments BEFORE touching anything ────────────────────────────
box_target=""
while (( $# > 0 )); do
  case "$1" in
    --box)
      [[ -n "${2:-}" ]] || usage
      box_target="$2"
      shift 2
      ;;
    *)
      usage
      ;;
  esac
done

if [[ -n "$box_target" ]] && ! [[ "$box_target" =~ ^[A-Za-z0-9.][A-Za-z0-9._-]*@[A-Za-z0-9._-]+(:[1-9][0-9]{0,4})?$ ]]; then
  echo "install.sh: --box expects user@host[:port], got '$box_target'" >&2
  exit 1
fi

for script in botmarchy-muster botmarchy-focus botmarchy-usage-update; do
  if [[ ! -f "$PLUGIN_DIR/bin/$script" ]]; then
    echo "install.sh: missing $PLUGIN_DIR/bin/$script — incomplete plugin?" >&2
    exit 1
  fi
done

# ── Local cache dir (P1.8): OpenSSH never creates the ControlPath socket's
# parent directory — create it NOW so a first poll on a clean install cannot
# exit 255 before the panel has ever run. 0700: bot message snippets land
# here (muster-state.json).
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/botmarchy"
mkdir -p -m 700 "$CACHE_DIR"

# ── Local symlinks (idempotent; never clobber foreign files) ───────────────
mkdir -p "$LOCAL_BIN"

link_owned() {
  # Owned = absent, or a symlink into THIS plugin dir (a previous install).
  local target="$1" name
  name="$(basename "$target")"
  [[ ! -e "$target" ]] && return 0
  [[ -L "$target" ]] && [[ "$(readlink -f "$target" 2>/dev/null)" == "$PLUGIN_DIR/bin/$name" ]]
}

for script in botmarchy-muster botmarchy-focus botmarchy-usage-update; do
  target="$LOCAL_BIN/$script"

  if ! link_owned "$target"; then
    echo "install.sh: refusing to replace $target (not a previous Muster install)" >&2
    exit 1
  fi

  rm -f "$target"
  ln -s "$PLUGIN_DIR/bin/$script" "$target"
  echo "linked $target -> $PLUGIN_DIR/bin/$script"
done

# ── systemd user units (usage-record timer, PB-16 F1) ──────────────────────
UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
if [[ -d "$PLUGIN_DIR/systemd" ]]; then
  mkdir -p "$UNIT_DIR"
  for unit in botmarchy-usage.service botmarchy-usage.timer; do
    unit_target="$UNIT_DIR/$unit"
    # Symlink like the bins (P3.10): `omarchy plugin update` refreshes the
    # plugin dir, and a copied unit would silently drift from it.
    if [[ -e "$unit_target" && ! -L "$unit_target" ]]; then
      echo "install.sh: refusing to replace $unit_target (not a previous Muster unit)" >&2
      exit 1
    fi
    rm -f "$unit_target"
    ln -s "$PLUGIN_DIR/systemd/$unit" "$unit_target"
  done
  systemctl --user daemon-reload 2>/dev/null || true
  echo "installed botmarchy-usage.timer (enable: systemctl --user enable --now botmarchy-usage.timer)"
fi

# ── Gateway box (optional): same SSH options for ssh+scp, atomic install ──
if [[ -n "$box_target" ]]; then
  # Split [user@]host[:port] — ssh wants -p, scp wants -P (P2.14).
  box_port="$(printf '%s' "$box_target" | sed -n 's/.*:\([0-9]\+\)$/\1/p')"
  box_host="$(printf '%s' "$box_target" | sed 's/:[0-9]*$//')"
  SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=8)
  [[ -n "$box_port" ]] && SSH_OPTS+=(-p "$box_port")
  SCP_OPTS=(-o BatchMode=yes -o ConnectTimeout=8)
  [[ -n "$box_port" ]] && SCP_OPTS+=(-P "$box_port")
  SSH_HOST_ARGS=("${SSH_OPTS[@]}" -- "$box_host")

  if ! ssh "${SSH_HOST_ARGS[@]}" 'mkdir -p ~/.local/bin'; then
    echo "install.sh: could not reach $box_target over SSH" >&2
    exit 1
  fi

  # Upload to a temp path, then mv into place — a failed transfer must not
  # truncate the working remote helper (PB-7 review F8).
  remote_tmp="$(ssh "${SSH_HOST_ARGS[@]}" 'mktemp /tmp/muster-snapshot.XXXXXX')"
  if ! scp -q "${SCP_OPTS[@]}" \
    "$PLUGIN_DIR/box/muster-snapshot.py" "$box_host:$remote_tmp"; then
    ssh "${SSH_HOST_ARGS[@]}" "rm -f '$remote_tmp'" || true
    echo "install.sh: upload to $box_target failed" >&2
    exit 1
  fi
  ssh "${SSH_HOST_ARGS[@]}" "chmod +x '$remote_tmp' && mv '$remote_tmp' ~/.local/bin/botmarchy-muster-snapshot"

  # Usage-record aggregator (F1): SAME push discipline as the snapshot
  # (P3.13 — a failed usage upload used to exit silently with a stray tmp
  # file on the box; now it fails loudly with cleanup, like the snapshot).
  remote_tmp2="$(ssh "${SSH_HOST_ARGS[@]}" 'mktemp /tmp/muster-usage.XXXXXX')"
  if ! scp -q "${SCP_OPTS[@]}" \
    "$PLUGIN_DIR/box/muster-usage.py" "$box_host:$remote_tmp2"; then
    ssh "${SSH_HOST_ARGS[@]}" "rm -f '$remote_tmp2'" || true
    echo "install.sh: usage-helper upload to $box_target failed" >&2
    exit 1
  fi
  ssh "${SSH_HOST_ARGS[@]}" "chmod +x '$remote_tmp2' && mv '$remote_tmp2' ~/.local/bin/botmarchy-muster-usage"

  # Version round-trip (MP-3/QW1): prove the deployed helper is the copy
  # this plugin ships — the pre-MP-3 box copy had silently skewed from the
  # plugin for weeks.
  deployed="$(ssh "${SSH_HOST_ARGS[@]}" 'botmarchy-muster-snapshot --version 2>/dev/null' || true)"
  expected="$(python3 "$PLUGIN_DIR/box/muster-snapshot.py" --version 2>/dev/null || true)"
  if [[ "$deployed" == "$expected" && -n "$deployed" ]]; then
    echo "installed botmarchy-muster-snapshot $deployed on $box_target"
  else
    echo "WARNING: version mismatch on $box_target — deployed '$deployed', expected '$expected'. Re-run with --box." >&2
  fi
fi

echo
echo "Done. If the bar widget is not showing yet:"
echo "  omarchy plugin enable dev.botmarchy.muster --section right"
echo "  pkill quickshell   # re-renders the bar (auto-respawns)"
echo
echo "To point it at your gateway:"
echo "  omarchy bar set dev.botmarchy.muster sshTarget user@host"
echo "  omarchy bar set dev.botmarchy.muster intervalSec 10"
echo
echo "Default placement is the far right edge. To sit it beside other"
echo "agent widgets instead (example, agents-adjacent slot):"
echo "  omarchy bar move dev.botmarchy.muster --section right --index 6"
