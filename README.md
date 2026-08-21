# Botmarchy Muster

Your Botmarchy bot court at a glance: a roster roll call in the Omarchy bar.

The companion plugin for [Botmarchy](https://github.com/AmbitiousRealism2025/botmarchy) — the local-first Hermes bot GUI for Omarchy. It polls your self-hosted gateway over SSH (read-only) and surfaces the court everywhere Omarchy already lives: the bar, the roster panel, and the OS agents panel.

**What you get**

- **Bar roll call** — `⚔ 3` bots at rest, `⚔ 3 · 1 ⚙` when one is working, `· 2 ✦` when bots have news you haven't engaged. Dimmed only when data is stale.
- **Roster panel** — click the bar (or `Super+Alt+B`): per-bot status, recency, message previews, avatar color chips. Keyboard-first: `↑/↓`/`j/k` move, `Enter` engages, `r` refreshes, `Esc` closes.
- **Engage the chosen bot** — `Enter` (or middle-click the bar) jumps straight into *that bot's chat* in the Botmarchy app via its `hermes://` deep link. Cold app? It boots into the bot.
- **Unread that respects you** — the ✦ signal persists until you actually engage that bot (not until the next poll), then clears.
- **OS agents panel** — writes a `botmarchy` usage record the first-party Omarchy agents widget renders natively: tokens by day and by model, your court beside Claude and Codex.
- **Theme-native** — inherits the active Omarchy theme (colors + shell styling) exactly like first-party widgets; follows theme switches live.

**How it talks to your gateway** — one read-only SSH channel: `state.db` opened `mode=ro`, `profile.yaml` for avatar colors, no HTTP, no tokens, no writes. A shared ControlMaster connection keeps polling cheap (~0.02s warm). Polls pause while the session is idle.

## Prerequisites

- [Botmarchy](https://github.com/AmbitiousRealism2025/botmarchy) (the app) — for the engage deep link; the roster works without it running.
- Your Hermes gateway on a machine you reach over SSH (the box Muster polls).

## Install

```sh
omarchy plugin add https://github.com/AmbitiousRealism2025/botmarchy-muster.git --enable
~/.config/omarchy/plugins/dev.botmarchy.muster/install.sh --box user@your-gateway
```

The plugin add clones this repo; `install.sh` links the companion scripts onto your PATH and (with `--box`) pushes the two gateway-side scripts to your box — atomically, with a version round-trip check. If the bar doesn't show the widget after install:

```sh
omarchy plugin enable dev.botmarchy.muster --section right
omarchy-restart-shell
```

## Configure

```sh
omarchy bar set dev.botmarchy.muster sshTarget user@host   # gateway SSH target
omarchy bar set dev.botmarchy.muster intervalSec 10         # poll cadence (s)
```

Default placement is the far-right end of the bar. To move it (e.g. beside the agents widget):

```sh
omarchy bar move dev.botmarchy.muster --section right --index 6
```

A systemd user timer refreshes the OS agents-panel usage record every 15 minutes — enable it with:

```sh
systemctl --user enable --now botmarchy-usage.timer
```

(the unit files are installed by `install.sh`; source them from the repo's `systemd/` if your install predates that).

## What talks to what

- The **bar widget** (Panel.qml) polls `ssh <target> botmarchy-muster-snapshot` every `intervalSec`. The last good snapshot stays on screen when the gateway is unreachable; the label dims when data goes stale (>15 min).
- **`botmarchy-muster-snapshot`** runs ON the gateway: reads Hermes profiles' SQLite state directly — read-only (`mode=ro`, 2s lock timeout), no HTTP, no session token. Also maintains the unread watermark and answers `--ack` when you engage a bot.
- **`botmarchy-muster-usage`** (also on the gateway) aggregates the court's token/message usage into the record the OS agents panel renders.
- **`botmarchy-muster`** is the roster window (fuzzel/wofi): keyboard-first, arrows/j-k + Enter to engage. First run asks cadence + target once.
- **`botmarchy-focus`** focuses (or launches) the Botmarchy app; with `--bot <name>` it engages that specific bot via the deep link.

## Keymap (Botmarchy default)

`Super+Alt+B` → roster window. Add to `~/.config/hypr/bindings.conf`:

```
bind = SUPER ALT, B, exec, botmarchy-muster
```

Bar: click = roster · middle-click = jump to the app · right-click = refresh.

## Uninstall

```sh
systemctl --user disable --now botmarchy-usage.timer 2>/dev/null || true
omarchy plugin remove dev.botmarchy.muster
rm -f ~/.local/bin/botmarchy-muster ~/.local/bin/botmarchy-focus ~/.local/bin/botmarchy-usage-update
rm -f ~/.local/state/omarchy/agents/usage/botmarchy.json
# If install.sh --box was used, also remove the gateway-side helpers:
#   ssh user@your-gateway 'rm -f ~/.local/bin/botmarchy-muster-snapshot ~/.local/bin/botmarchy-muster-usage'
```

## Security notes for reviewers

Plugins run unsandboxed — this one does exactly what the README says and nothing else: read-only SQLite opens, YAML reads, SSH with `BatchMode=yes` (no interactive prompts), one notification CLI call. No telemetry, no writes outside `~/.cache/botmarchy/` (sockets, cache, watermark) and the agents-usage record. Read the source; it's short.

## Lineage

Part of the Botmarchy project — a local Hermes bot GUI for Omarchy — and developed in the [botmarchy](https://github.com/AmbitiousRealism2025/botmarchy) monorepo (`omarchy-integration/muster/`). This repo is the installable distribution. MIT; see LICENSE.
