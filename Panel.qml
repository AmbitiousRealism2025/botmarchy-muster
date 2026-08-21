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
  // hand-off). XDG default; created on demand by ssh itself.
  readonly property string cacheDir: {
    var xdg = Quickshell.env("XDG_CACHE_HOME")
    return (xdg && xdg.length > 0 ? xdg : Quickshell.env("HOME") + "/.cache") + "/botmarchy"
  }

  readonly property string configuredTarget: String(setting("sshTarget", "")).trim()
  readonly property string fileTarget: String(musterConfig.ssh || "").trim()
  readonly property string sshTarget: configuredTarget || fileTarget

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
  readonly property bool stale: generated === 0 || Date.now() / 1000 - generated > 900

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
  }

  function engage(index) {
    if (index < 0 || index >= bots.length) return
    // Deep-link engage (MP-1): land on the CHOSEN bot's chat, not just the
    // window — botmarchy-focus --bot opens hermes://bot/<name> when the app
    // is running (or boots it into that bot).
    // PROFILE name (bots[index].profile), not the display name — the app's
    // deep link routes by profile ("test-bot"), while .name is the human
    // label ("testbot"); a display name would create a dead navigation.
    var botId = bots[index].profile || bots[index].name
    var args = ["botmarchy-focus"]
    if (botId) args.push("--bot", botId)
    Quickshell.execDetached(args)
    // Engaging IS the read: clear the unread dot box-side (watermark ack),
    // then refresh so the roster reflects it immediately (MP-4).
    if (botId && bots[index].has_new === true) {
      Quickshell.execDetached(["ssh",
        "-o", "BatchMode=yes", "-o", "ConnectTimeout=3",
        "-o", "ControlMaster=auto",
        "-o", "ControlPath=" + root.cacheDir + "/cm-%C",
        "-o", "ControlPersist=10m",
        root.sshTarget, "botmarchy-muster-snapshot", "--ack", botId])
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

  function refresh() {
    if (pollProc.running || sshTarget === "") return
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
    // opens a fresh master (verified fallback).
    command: ["ssh",
      "-o", "BatchMode=yes", "-o", "ConnectTimeout=2",
      "-o", "ControlMaster=auto",
      "-o", "ControlPath=" + root.cacheDir + "/cm-%C",
      "-o", "ControlPersist=10m",
      root.sshTarget, "botmarchy-muster-snapshot"]

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          root.snapshot = JSON.parse(text || "")
          if (root.selectedIndex >= root.bots.length) root.selectedIndex = 0
          // Cache hand-off (MP-4): the roster CLI reads this when the
          // gateway is unreachable (freshness-gated client-side).
          Quickshell.execDetached(["bash", "-c",
            'mkdir -p "$HOME/.cache/botmarchy" && printf %s "$1" > "$HOME/.cache/botmarchy/muster-state.json"',
            "_", String(text)])
        } catch (e) {
          // unreachable or unparsable: keep the previous snapshot; the
          // generated timestamp ages it out to the dimmed stale state.
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

        // roster rows
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
