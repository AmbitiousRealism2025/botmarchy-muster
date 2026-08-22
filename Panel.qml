import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Botmarchy Muster — the court's roll call.
//
// Layer 1 (glance): bar label "⚔ 4" / "⚔ 4 · 2 ⚙" (dimmed when stale)
// Layer 2 (peek):   hover tooltip — per-bot status + last message
// Layer 3 (decide): click (or Super+Alt+B via IPC) opens the roster panel
//                   below the bar — keyboard-first (↑/↓ or j/k to move,
//                   Enter engages that bot's chat via hermes://bot/<name>,
//                   Esc closes, r refreshes);
//                   row click engages with the mouse. Persists until
//                   dismissed: outside click, Escape, or the icon again.
//
// Data: ssh to the Botmarchy gateway box runs botmarchy-muster-snapshot
// (one JSON line; reads profile state.db's read-only — no dashboard, no
// session token). Last good snapshot stays on screen when unreachable.
//
// Configuration (Omarchy convention: QML fallbacks must work from a bare
// layout entry): shell.json entry → ~/.config/botmarchy/muster.json
// (written by the roster CLI onboarding) → unconfigured warning state.

Panel {
  id: root
  moduleName: "dev.botmarchy.muster"
  ipcTarget: "dev.botmarchy.muster"
  manageIpc: false

  // --- configuration chain -------------------------------------------------
  property var musterConfig: ({})

  // Socket + cache home for the SSH ControlMaster (and MP-4's cache
  // hand-off). XDG default; created by setupProc before the first ssh —
  // OpenSSH will NOT create the parent of a ControlPath socket (P1.8).
  readonly property string cacheDir: {
    var xdg = Quickshell.env("XDG_CACHE_HOME")
    return (xdg && xdg.length > 0 ? xdg : Quickshell.env("HOME") + "/.cache") + "/botmarchy"
  }

  readonly property string configuredTarget: String(setting("sshTarget", "")).trim()
  readonly property string fileTarget: String(musterConfig.ssh || "").trim()
  readonly property string sshTarget: configuredTarget || fileTarget

  // Target format (P2.2/P2.14): [user@]host[:port] with a conservative
  // charset — a leading dash or metacharacter must never reach an argv
  // slot ssh would parse as an option. Invalid → treated as misconfigured.
  readonly property bool validTarget: /^[A-Za-z0-9.][A-Za-z0-9._-]*(@[A-Za-z0-9._-]+)?(:[1-9][0-9]{0,4})?$/.test(sshTarget)
  readonly property string sshHost: sshTarget.replace(/:[0-9]+$/, "")
  readonly property string sshPort: (sshTarget.match(/:([0-9]+)$/)||[])[1] || ""

  // Bot profile names (P2.1): mirror the gateway's _PROFILE_ID_RE — the
  // ack ssh hands the id to a remote shell, so only this shape may pass.
  function validBotProfile(id) {
    return typeof id === "string" && /^[a-z0-9][a-z0-9_-]{0,63}$/.test(id)
  }

  readonly property int configuredInterval: Number(setting("intervalSec", 0)) || 0
  readonly property int fileInterval: Number(musterConfig.interval) || 0
  readonly property int intervalSec: Math.max(2, configuredInterval || fileInterval || 10)

  // --- data ------------------------------------------------------------------
  property var snapshot: ({})

  readonly property var bots: (snapshot && snapshot.bots) || []
  readonly property int workingCount: {
    var n = 0
    for (var i = 0; i < bots.length; i++) if (bots[i].working) n++
    return n
  }
  readonly property int unreadCount: {
    var n = 0
    for (var i = 0; i < bots.length; i++) if (bots[i].has_new) n++
    return n
  }
  readonly property color dim: Qt.darker(Color.popups.text, 1.4)
  readonly property double generated: (snapshot && snapshot.generated) || 0
  // Local receive epoch of the current snapshot (P1.7): the gateway's
  // `generated` can skew from this machine's clock, and a QML binding on
  // Date.now() alone never re-evaluates — so staleness compares a
  // locally-stamped epoch against a timer-driven nowTick. Cache loads
  // seed receivedAt from the envelope's cachedAt stamp.
  property double receivedAt: 0
  property double nowTick: 0
  readonly property bool stale: generated === 0 || (nowTick - receivedAt > 900)

  // --- keyboard cursor ---------------------------------------------------
  property int selectedIndex: 0
  property bool cursorActive: bots.length > 0

  function clampIndex(i) {
    if (bots.length === 0) return 0
    return ((i % bots.length) + bots.length) % bots.length
  }

  function moveCursor(delta) {
    cursorActive = true
    selectedIndex = clampIndex(selectedIndex + delta)
    rosterFlick.followSelection()
  }

  function engage(index) {
    if (index < 0 || index >= bots.length) return
    // Deep-link engage (MP-1): land on the CHOSEN bot's chat, not just the
    // window — botmarchy-focus --bot opens hermes://bot/<name> when the app
    // is running (or boots it into that bot).
    // PROFILE name (bots[index].profile) ONLY (P2.1): it is the gateway
    // directory name, charset-safe by construction. The .name display title
    // is free-text from the remote profile.yaml — never hand it to a shell.
    var botId = bots[index].profile
    var okId = validBotProfile(botId)
    var args = ["botmarchy-focus"]
    if (okId) args.push("--bot", botId)
    Quickshell.execDetached(args)
    // Engaging IS the read: clear the unread dot box-side (watermark ack),
    // then refresh so the roster reflects it immediately (MP-4).
    if (okId && bots[index].has_new === true) {
      var ack = ["ssh",
        "-o", "BatchMode=yes", "-o", "ConnectTimeout=3",
        "-o", "ControlMaster=auto",
        "-o", "ControlPath=" + root.cacheDir + "/cm-%C",
        "-o", "ControlPersist=10m"]
      if (root.sshPort !== "") ack.push("-p", root.sshPort)
      ack.push("--", root.sshHost, "botmarchy-muster-snapshot", "--ack", botId)
      Quickshell.execDetached(ack)
      ackRefresh.restart()
    }
    close()
  }

  function engageSelected() {
    if (!cursorActive && bots.length > 0) {
      cursorActive = true
      selectedIndex = 0
      return
    }
    engage(selectedIndex)
  }

  // Avatar chip corner radius by shape (MP-5): round-family shapes render
  // as circles; square keeps corners; triangle/hexagon fall back to circle
  // (radius-only approximation — full polygon parity isn't worth Canvas
  // machinery at 14px, documented limitation).
  function chipRadius(shape) {
    if (shape === "square" || shape === "squircle") return Style.space(3)
    return Style.space(7)
  }

  function agoText(ts) {
    if (!ts) return "?"
    var s = Math.max(0, Math.floor(Date.now() / 1000 - ts))
    if (s < 60) return s + "s"
    if (s < 3600) return Math.floor(s / 60) + "m"
    if (s < 86400) return Math.floor(s / 3600) + "h"
    return Math.floor(s / 86400) + "d"
  }

  // ── Idle-aware polling (PB-16 F3) ─────────────────────────────────────
  // While the session is idle (Omarchy screensaver up or hyprlock running)
  // nobody can see the bar — polls are pure waste (and battery). The check
  // itself is cheap and cached (probe every ~60s max); on the idle→active
  // transition the roster refreshes immediately.
  property bool sessionIdle: false
  property real lastIdleProbe: 0

  function probeSessionIdle() {
    var now = Date.now() / 1000
    if (now - root.lastIdleProbe < 60 && root.lastIdleProbe > 0) return
    root.lastIdleProbe = now
    idleProbeProc.running = true
  }

  Process {
    id: idleProbeProc
    running: false
    command: ["bash", "-c",
      "if hyprctl -j clients 2>/dev/null | grep -q 'org.omarchy.screensaver' || pidof hyprlock >/dev/null 2>&1; then echo idle; else echo active; fi"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var was = root.sessionIdle
        root.sessionIdle = String(text).trim() === "idle"
        if (was && !root.sessionIdle) root.refresh()  // wake → immediate refresh
      }
    }
  }

  function refresh() {
    if (pollProc.running || sshTarget === "" || !validTarget || !cacheReady) return
    probeSessionIdle()
    if (root.sessionIdle) return
    pollProc.running = true
  }

  onOpenedChanged: if (opened) {
    // fresh data + reset cursor each time the panel is summoned
    refresh()
    selectedIndex = 0
    cursorActive = bots.length > 0
  }

  FileView {
    path: Quickshell.env("HOME") + "/.config/botmarchy/muster.json"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      try {
        root.musterConfig = JSON.parse(String(text || "{}")) || {}
      } catch (e) {
        root.musterConfig = ({})
      }
    }
    onLoadFailed: root.musterConfig = ({})
  }

  Process {
    id: pollProc

    // ControlMaster (MP-3/CM5): one authenticated connection per ~10min
    // instead of per poll (~8.6k/day → ~144/day at the default cadence).
    // ControlPersist keeps the socket warm; if it dies, ssh transparently
    // opens a fresh master (verified fallback). `--` ends option parsing —
    // a dash-leading host can never reparse as an ssh option (P2.2).
    command: {
      var cmd = ["ssh",
        "-o", "BatchMode=yes", "-o", "ConnectTimeout=2",
        "-o", "ControlMaster=auto",
        "-o", "ControlPath=" + root.cacheDir + "/cm-%C",
        "-o", "ControlPersist=10m"]
      if (root.sshPort !== "") cmd.push("-p", root.sshPort)
      cmd.push("--", root.sshHost, "botmarchy-muster-snapshot")
      return cmd
    }

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          root.snapshot = JSON.parse(text || "")
          root.receivedAt = Date.now() / 1000
          if (root.selectedIndex >= root.bots.length) root.selectedIndex = 0
          // Cache hand-off (MP-4, hardened P2.15): the roster CLI reads this
          // when the gateway is unreachable (freshness-gated client-side).
          // Atomic (tmp+mv), 0700 dir, XDG-resolved, and stamped with the
          // normalized target + local cache time so a restore can only ever
          // render data that belongs to the gateway it was polled from.
          var envelope = JSON.stringify({
            target: root.sshTarget,
            cachedAt: root.receivedAt,
            snapshot: root.snapshot
          })
          Quickshell.execDetached(["bash", "-c",
            'mkdir -p -m 700 "$1" && printf %s "$2" > "$1/muster-state.json.tmp" && mv "$1/muster-state.json.tmp" "$1/muster-state.json"',
            "_", root.cacheDir, envelope])
        } catch (e) {
          // unreachable or unparsable: keep the previous snapshot; the
          // receivedAt epoch ages it out to the dimmed stale state (P1.7:
          // nowTick keeps that evaluation live even while polls fail).
        }
      }
    }

    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: if (text && text.trim().length > 0)
        console.warn("muster", "snapshot ssh stderr:", text.trim())
    }
  }

  Timer {
    interval: root.intervalSec * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  // Staleness heartbeat (P1.7): a QML binding only re-evaluates when one of
  // its referenced PROPERTIES changes — Date.now() is not reactive, so a
  // dead gateway would leave the label bright forever. This timer keeps
  // `stale` honest while polls fail; 15s granularity against a 900s
  // threshold is plenty and costs nothing.
  Timer {
    interval: 15000
    running: true
    repeat: true
    onTriggered: root.nowTick = Date.now() / 1000
  }

  Component.onCompleted: {
    root.nowTick = Date.now() / 1000
    setupProc.running = true
  }

  // P1.8: OpenSSH never creates the ControlPath socket's parent directory
  // (unix_listener has no mkdir) — without this, a clean install's first
  // ssh exits 255 before the panel ever writes its first cache. Also seeds
  // the roster from the last good cache (P2.15) so a Quickshell restart
  // during an outage still renders the court.
  property bool cacheReady: false
  Process {
    id: setupProc
    running: false
    command: ["bash", "-c",
      'mkdir -p -m 700 "$1" && cat "$1/muster-state.json" 2>/dev/null || true',
      "_", root.cacheDir]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.cacheReady = true
        try {
          var env = JSON.parse(String(text || ""))
          // Source-keyed restore: only data polled from THIS target, and
          // only while we have nothing fresher (a live poll overwrites it).
          if (env && env.snapshot && env.target === root.sshTarget && root.generated === 0) {
            root.snapshot = env.snapshot
            root.receivedAt = Number(env.cachedAt) || 0   // ages to stale via nowTick
          }
        } catch (e) {
          // no cache / corrupt cache: cold start, first poll fills it
        }
        // Always pull fresh once setup is done — a live poll overwrites
        // any restored cache; the restore only bridges the outage window.
        root.refresh()
      }
    }
  }

  // After an engage-ack: the ack ssh returns in ms via ControlMaster; give
  // it a beat, then pull a fresh snapshot so the dot clears immediately.
  Timer {
    id: ackRefresh
    interval: 700
    repeat: false
    running: false
    onTriggered: root.refresh()
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { root.refresh(); return "ok" }
  }

  // --- layer 1 + 2: the bar button ------------------------------------------
  // Label states (glance layer). Working state is called out with the ⚙
  // badge count; idle/empty stay quiet. The label text renders in theme
  // FOREGROUND like every bar widget — Botmarchy's accent (the theme's
  // accent key, same source as the app's garnish) appears on STATE fills
  // (panel row selection, badge chips), not on label text: accent-as-text
  // measures 3.16:1 under the active theme vs 11.27:1 for foreground.
  readonly property string labelText: {
    if (sshTarget === "") return "⚔ ⚠"
    if (!validTarget) return "⚔ ⚠"
    if (bots.length === 0) return "⚔ –"
    var label = `⚔ ${bots.length}`
    if (workingCount > 0) label += ` · ${workingCount} ⚙`
    if (unreadCount > 0) label += ` · ${unreadCount} ✦`
    return label
  }

  readonly property string tooltipText: {
    if (sshTarget === "") {
      return ["Botmarchy Muster — not configured", "",
        "Set sshTarget here in shell.json, or run", "`botmarchy-muster` once to answer setup."].join("\n")
    }
    if (!validTarget) {
      return ["Botmarchy Muster — invalid sshTarget", "",
        `“${sshTarget}” is not [user@]host[:port] in the safe charset.`, "Fix it in shell.json or ~/.config/botmarchy/muster.json."].join("\n")
    }
    var lines = ["Botmarchy — bot roster  ·  " + (stale ? "stale" : "live")]
    for (var i = 0; i < bots.length; i++) {
      var b = bots[i]
      lines.push(`${b.working ? "▶" : "●"} ${b.name} — ${b.last_message || "no messages"}`)
    }
    if (bots.length === 0) lines.push("(no bots on the gateway yet)")
    lines.push("─")
    lines.push("click: roster · middle-click: jump to Botmarchy · right-click: refresh")
    return lines.join("\n")
  }

  visible: true
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  WidgetButton {
    id: button

    anchors.fill: parent
    bar: root.bar
    text: root.labelText
    fontSize: Style.font.caption
    horizontalMargin: 6
    // Brightness = freshness, not activity (PB-8 A1): the court's healthy
    // IDLE state is the common case and must read at full weight — dim only
    // when data is stale (gateway unreachable >900s / never fetched). Idle
    // dimming made the widget effectively invisible at its far-edge slot.
    dimmed: root.sshTarget !== "" && root.stale
    tooltipText: root.tooltipText
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton) {
        root.refresh()
      } else if (buttonCode === Qt.MiddleButton) {
        // Jump straight to the app (README contract): focus-or-launch.
        Quickshell.execDetached(["botmarchy-focus"])
      } else {
        root.toggle()
      }
    }
  }

  // --- layer 3: the roster panel ---------------------------------------------
  KeyboardPanel {
    id: panel

    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(420))
    contentHeight: panel.fittedContentHeight(rosterColumn.implicitHeight + Style.space(24), Style.space(520))

    PanelKeyCatcher {
      id: keyCatcher

      anchors.fill: parent

      onMoveRequested: function(dx, dy) {
        if (dy !== 0) root.moveCursor(dy)
      }
      onActivateRequested: root.engageSelected()
      onCloseRequested: root.close()
      onTextKey: function(t) {
        if (t === "j") root.moveCursor(1)
        else if (t === "k") root.moveCursor(-1)
        else if (t === "r" || t === "R") root.refresh()
      }

      Column {
        id: rosterColumn

        anchors.fill: parent
        spacing: Style.space(4)

        // header — brand mark + plain product name (QW3: the court
        // vocabulary lives in the body copy, the header reads as the app).
        Row {
          id: headerRow

          width: parent.width
          spacing: Style.space(8)

          Image {
            source: Qt.resolvedUrl("assets/botmarchy-icon.png")
            sourceSize.width: Style.font.bodySmall * 1.4
            sourceSize.height: Style.font.bodySmall * 1.4
            anchors.verticalCenter: parent.verticalCenter
            fillMode: Image.PreserveAspectFit
            mipmap: true
          }
          Text {
            text: "Botmarchy"
            color: Color.popups.text
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.bodySmall
            font.bold: true
          }
          Text {
            text: root.stale ? "stale" : `${root.bots.length} bots · ${root.workingCount} working`
            color: root.dim
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.bodySmall
            anchors.baseline: parent.baseline
          }
        }

        // roster rows (P3.21: Flickable — a long court must not clip, and
        // the keyboard cursor keeps itself in view)
        Flickable {
          id: rosterFlick

          clip: true
          width: parent.width
          height: rosterColumn.height - headerRow.height - Style.space(4)
          contentWidth: width
          contentHeight: rosterRows.implicitHeight + Style.space(4)
          interactive: true

          // Follow the selection: whenever the cursor moves past the visible
          // band, scroll it into view (top-weighted like every list).
          function followSelection() {
            const row = Style.space(44) + Style.space(4)
            const y = root.selectedIndex * row
            if (y < contentY) contentY = y
            else if (y + row > contentY + height - Style.space(4)) contentY = y + row - height + Style.space(4)
          }

          Column {
            id: rosterRows

            width: parent.width
            spacing: Style.space(4)

            Repeater {
              model: root.bots

              delegate: Rectangle {
              required property var modelData
              required property int index

              width: parent.width
              height: Style.space(44)
              radius: Style.cornerRadius
              color: mouse.hovered || (root.cursorActive && root.selectedIndex === index)
                ? Style.selectedFillFor(Color.popups.text, Color.accent)
                : "transparent"

              Row {
                anchors.fill: parent
                anchors.leftMargin: Style.space(8)
                anchors.rightMargin: Style.space(8)
                spacing: Style.space(8)

                // Mark: ▶ working (strongest); accent dot = idle with news
                // (the decide layer's unread signal, MP-4); dim ● = idle/seen.
                Loader {
                  active: !modelData.working && modelData.has_new === true
                  sourceComponent: Component {
                    Rectangle {
                      width: Style.space(7); height: Style.space(7)
                      radius: width / 2
                      color: Color.accent
                      anchors.verticalCenter: parent.verticalCenter
                    }
                  }
                }
                Text {
                  visible: modelData.working || modelData.has_new !== true
                  text: modelData.working ? "▶" : "●"
                  color: modelData.working ? Color.bar.active : root.dim
                  font.pixelSize: Style.font.body
                  anchors.verticalCenter: parent.verticalCenter
                }
                // Avatar chip (MP-5): the bot's own color from profile
                // ui_meta — the roster reads as the same court as the app.
                // Absent meta falls back to a muted chip so rows stay aligned.
                Rectangle {
                  width: Style.space(14); height: Style.space(14)
                  radius: root.chipRadius(modelData.avatar ? modelData.avatar.shape : "")
                  color: modelData.avatar && modelData.avatar.color
                    ? modelData.avatar.color
                    : Qt.alpha(root.dim, 0.45)
                  anchors.verticalCenter: parent.verticalCenter
                }
                Text {
                  text: modelData.name
                  color: Color.popups.text
                  font.pixelSize: Style.font.body
                  font.bold: true
                  elide: Text.ElideRight
                  width: parent.width * 0.28
                  anchors.verticalCenter: parent.verticalCenter
                }
                Text {
                  text: root.agoText(modelData.last_activity)
                  color: root.dim
                  font.pixelSize: Style.font.bodySmall
                  anchors.verticalCenter: parent.verticalCenter
                }
                Text {
                  text: modelData.last_message || ""
                  color: root.dim
                  font.pixelSize: Style.font.bodySmall
                  elide: Text.ElideRight
                  width: parent.width - Style.space(8) * 3 - parent.children[0].width - parent.children[1].width - parent.children[2].width - Style.space(16)
                  anchors.verticalCenter: parent.verticalCenter
                }
              }

              MouseArea {
                id: mouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                  root.selectedIndex = index
                  root.engage(index)
                }
              }
              }
            }
          }
        }

        // empty / unconfigured states
        Text {
          visible: root.sshTarget === ""
          width: parent.width
          wrapMode: Text.WordWrap
          color: root.dim
          font.pixelSize: Style.font.bodySmall
          text: "Not configured. Set sshTarget in shell.json (omarchy bar set dev.botmarchy.muster sshTarget user@host), or run botmarchy-muster once to answer setup."
        }
        Text {
          visible: root.sshTarget !== "" && !root.validTarget
          width: parent.width
          wrapMode: Text.WordWrap
          color: root.dim
          font.pixelSize: Style.font.bodySmall
          text: "Invalid sshTarget — expected [user@]host[:port] with letters, digits, dots, dashes, underscores. Fix it in shell.json or ~/.config/botmarchy/muster.json."
        }
        Text {
          visible: root.sshTarget !== "" && root.bots.length === 0
          width: parent.width
          color: root.dim
          font.pixelSize: Style.font.bodySmall
          text: "No bots on the gateway yet — open Botmarchy to create one."
        }

        // footer hint
        Text {
          width: parent.width
          color: root.dim
          font.pixelSize: Style.font.caption
          font.italic: true
          text: "↑/↓ or j/k move · Enter engage · r refresh · Esc close"
        }
      }
    }
  }
}
