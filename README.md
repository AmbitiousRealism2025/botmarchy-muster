# Botmarchy Muster

Your Botmarchy bot court at a glance: a roster roll call in the Omarchy bar.
Hover for per-bot activity, click for the roster window, middle-click to jump
straight to the
[Botmarchy](https://github.com/AmbitiousRealism2025/botmarchy) app, right-click
to refresh.

Works against a self-hosted Botmarchy/Hermes gateway on a machine you reach
over SSH — no cloud service involved.

## Install

```sh
omarchy plugin add https://github.com/AmbitiousRealism2025/botmarchy-muster.git --enable
~/.config/omarchy/plugins/dev.botmarchy.muster/install.sh --box user@your-gateway
```

The plugin install clones this repo; `install.sh` then links the companion
scripts onto your PATH and (with `--box`) pushes the snapshot script to the
gateway. If the bar doesn't show the widget after install:

```sh
omarchy plugin enable dev.botmarchy.muster --section right
pkill quickshell   # re-renders the bar; it auto-respawns
```

## Configure

```sh
omarchy bar set dev.botmarchy.muster sshTarget user@host   # gateway SSH target
omarchy bar set dev.botmarchy.muster intervalSec 10         # poll cadence (s)
```

Default placement is the far-right end of the bar. To move it (e.g. beside
the agents widget):

```sh
omarchy bar move dev.botmarchy.muster --section right --index 6
```

Or run `botmarchy-muster` once for the guided setup. State lives in
`~/.config/botmarchy/muster.json`.

## What talks to what

- The **bar widget** (Panel.qml) polls `ssh <target> botmarchy-muster-snapshot`
  every `intervalSec`, reading a small JSON roster snapshot. The last good
  snapshot stays on screen when the gateway is unreachable (in the panel's
  memory — it does not persist across a shell restart; the first poll after
  a restart starts fresh).
- **`botmarchy-muster-snapshot`** runs ON the gateway (installed by
  `install.sh --box`): reads the Hermes profiles' SQLite state directly —
  no HTTP, no session token, no dashboard dependency.
- **`botmarchy-muster`** is the roster window (fuzzel/wofi): keyboard-first,
  arrows/j-k + Enter to engage. Super+Alt+B in the default Botmarchy keymap.
- **`botmarchy-focus`** focuses (or launches) the Botmarchy app window via
  Hyprland.

## Keymap (Botmarchy default)

`Super+Alt+B` → roster window. Add to `~/.config/hypr/bindings.conf`:

```
bind = SUPER ALT, B, exec, botmarchy-muster
```

## Uninstall

```sh
omarchy plugin remove dev.botmarchy.muster
rm -f ~/.local/bin/botmarchy-muster ~/.local/bin/botmarchy-focus
# If install.sh --box was used, also remove the gateway-side helper:
#   ssh user@your-gateway 'rm -f ~/.local/bin/botmarchy-muster-snapshot'
```

## Lineage

Part of the Botmarchy project — a local Hermes bot GUI for Omarchy — and
developed in the [botmarchy](https://github.com/AmbitiousRealism2025/botmarchy)
monorepo (`omarchy-integration/muster/`). This repo is the installable
distribution.
