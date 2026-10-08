import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland
import QtQuick
import QtQuick.Layouts
import qs.Commons

// Desktop card (top-left, below windows): CPU, memory, battery, network, NVIDIA power state,
// fans, top processes, disk and the biggest regenerable folders with one-click cleaning
// (always behind a confirmation). Data comes from `sysstat.py watch`.
Item {
  id: root

  readonly property string script: Qt.resolvedUrl("sysstat.py").toString().replace("file://", "")
  property var s: null                 // latest snapshot
  property var confirm: null           // { title, message, kind, path, label, size }
  property bool cleaning: false
  property real nowSec: Date.now() / 1000

  readonly property color fg: Color.foreground
  readonly property color accent: Color.accent
  readonly property color urgent: Color.urgent
  readonly property color muted: Color.muted
  readonly property color good: "#8fbf7f"
  readonly property string font: Style.font.family
  readonly property string iconFont: "JetBrainsMono Nerd Font"
  readonly property int radius: Math.max(8, Style.cornerRadius)

  // Nerd Font glyphs
  readonly property string gCpu: "\u{F0EE0}"
  readonly property string gMem: "\u{F035B}"
  readonly property string gBat: "\u{F0079}"
  readonly property string gPlug: "\u{F06A5}"
  readonly property string gNet: "\u{F0318}"
  readonly property string gGpu: "\u{F08AE}"
  readonly property string gFan: "\u{F0210}"
  readonly property string gDisk: "\u{F02CA}"
  readonly property string gBroom: "\u{F00E2}"
  readonly property string gRefresh: "\u{F0450}"
  readonly property string gTrash: "\u{F0A7A}"
  readonly property string gCopy: "\u{F018F}"
  readonly property string gAlert: "\u{F002A}"

  function tint(c, a) { return Qt.rgba(c.r, c.g, c.b, a) }

  function bytes(n, digits) {
    n = Number(n || 0)
    var u = ["o", "Ko", "Mo", "Go", "To"], i = 0
    while (n >= 1024 && i < u.length - 1) { n /= 1024; i++ }
    return (i === 0 ? Math.round(n) : n.toFixed(digits === undefined ? 1 : digits)) + " " + u[i]
  }
  function rate(n) { return bytes(n, n >= 1048576 ? 1 : 0) + "/s" }
  function duration(sec) {
    sec = Math.max(0, Math.floor(sec))
    if (sec < 3600) return Math.floor(sec / 60) + " min"
    if (sec < 86400) return Math.floor(sec / 3600) + " h " + ("0" + Math.floor(sec % 3600 / 60)).slice(-2)
    return Math.floor(sec / 86400) + " j " + Math.floor(sec % 86400 / 3600) + " h"
  }
  function tempColor(t) { return t === null || t === undefined ? muted : t >= 90 ? urgent : t >= 75 ? accent : fg }

  function askClean(row) {
    if (row.kind === "pacman") {
      Quickshell.execDetached(["wl-copy", "sudo paccache -rk1"])
      Quickshell.execDetached(["notify-send", "-a", "Système", "Commande copiée", "sudo paccache -rk1 — garde la dernière version de chaque paquet"])
      return
    }
    var trash = row.kind === "trash"
    confirm = {
      kind: row.kind, path: row.path, label: row.label, size: row.size,
      title: trash ? "Vider la corbeille ?" : "Supprimer « " + row.label + " » ?",
      message: trash ? "Les éléments de la corbeille seront supprimés définitivement."
             : row.kind === "node_modules" ? "Suppression définitive. Réinstallable avec npm / pnpm install."
             : "Suppression définitive. L'application recrée son cache au besoin ; fermez-la d'abord si elle tourne.",
      confirmLabel: trash ? "Vider" : "Supprimer"
    }
  }

  function doClean() {
    if (!confirm || cleaning) return
    cleaning = true
    cleanProc.command = ["python3", "-I", script, "clean", confirm.kind, confirm.path]
    cleanProc.running = true
  }

  function rescan() { if (watchProc.running) watchProc.write("scan\n") }

  Process {
    id: watchProc
    running: true
    stdinEnabled: true
    command: ["python3", "-I", root.script, "watch"]
    stdout: SplitParser {
      onRead: line => { try { root.s = JSON.parse(line) } catch (e) {} }
    }
    onExited: restart.start()
  }
  Timer { id: restart; interval: 5000; onTriggered: watchProc.running = true }
  Timer { interval: 30000; running: true; repeat: true; onTriggered: root.nowSec = Date.now() / 1000 }

  Process {
    id: cleanProc
    stdout: StdioCollector {
      onStreamFinished: {
        root.cleaning = false
        var r
        try { r = JSON.parse(text) } catch (e) { r = { ok: false, message: "Erreur inattendue" } }
        var label = root.confirm ? root.confirm.label : ""
        root.confirm = null
        Quickshell.execDetached(["notify-send", "-a", "Système", label,
          r.ok ? r.message + " · " + root.bytes(r.freed) + " libérés" : r.message])
        root.rescan()
      }
    }
  }

  // ---------- card ----------
  Variants {
    model: Quickshell.screens
    PanelWindow {
      required property var modelData
      screen: modelData
      anchors { top: true; left: true }
      margins { top: 60; left: 40 }
      implicitWidth: 430
      implicitHeight: card.implicitHeight
      color: "transparent"
      exclusionMode: ExclusionMode.Ignore
      WlrLayershell.namespace: "rebenga-system-desk"
      WlrLayershell.layer: WlrLayer.Bottom
      WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

      Rectangle {
        id: card
        width: parent.width
        implicitHeight: col.implicitHeight + 32
        radius: root.radius + 2
        color: root.tint(Color.background, 0.82)
        border.width: 1
        border.color: root.tint(root.fg, 0.15)

        ColumnLayout {
          id: col
          anchors { left: parent.left; right: parent.right; top: parent.top; margins: 16 }
          spacing: 10

          // Header
          RowLayout {
            Layout.fillWidth: true
            Text { text: "Système"; color: root.fg; font.family: root.font; font.pixelSize: 18; font.bold: true }
            Text {
              Layout.fillWidth: true
              horizontalAlignment: Text.AlignRight
              elide: Text.ElideLeft
              text: root.s ? root.s.cpu.cores + " threads · allumé depuis " + root.duration(root.s.uptime) : ""
              color: root.muted; font.family: root.font; font.pixelSize: 11
            }
          }

          // 2×2 tiles
          GridLayout {
            Layout.fillWidth: true
            columns: 2
            rowSpacing: 8
            columnSpacing: 8

            Tile {
              glyph: root.gCpu
              title: "Processeur"
              value: root.s ? Math.round(root.s.cpu.percent) + " %" : "–"
              detail: root.s && root.s.cpu.temp !== null ? Math.round(root.s.cpu.temp) + " °C · charge " + root.s.cpu.load.toFixed(1) : ""
              detailColor: root.s ? root.tempColor(root.s.cpu.temp) : root.muted
              history: root.s ? root.s.cpu.history : []
              maxValue: 100
            }
            Tile {
              glyph: root.gMem
              title: "Mémoire"
              value: root.s ? root.bytes(root.s.memory.used) : "–"
              detail: root.s ? "sur " + root.bytes(root.s.memory.total, 0) + (root.s.memory.swapUsed > 0 ? " · swap " + root.bytes(root.s.memory.swapUsed) : "") : ""
              fraction: root.s ? root.s.memory.used / root.s.memory.total : 0
            }
            Tile {
              readonly property var b: root.s ? root.s.battery : null
              glyph: b && b.plugged ? root.gPlug : root.gBat
              title: b && b.plugged ? "Secteur" : "Batterie"
              value: b ? b.percent + " %" : "–"
              detail: !b ? "" : b.status === "Discharging"
                      ? b.watts + " W" + (b.remaining ? " · " + root.duration(b.remaining) + " restantes" : "")
                      : b.status === "Charging" ? "en charge" + (b.remaining ? " · pleine dans " + root.duration(b.remaining) : "")
                      : "branché, pas de charge"
              detailColor: b && b.status === "Discharging" && b.percent <= 20 ? root.urgent : root.muted
              fraction: b ? b.percent / 100 : 0
            }
            Tile {
              glyph: root.gNet
              title: "Réseau"
              value: root.s ? "↓ " + root.rate(root.s.network.down) : "–"
              detail: root.s ? "↑ " + root.rate(root.s.network.up) : ""
              history: root.s ? root.s.network.downHistory : []
              maxValue: 0
            }
          }

          // NVIDIA
          Rectangle {
            id: gpuBox
            readonly property var g: root.s ? root.s.gpu : null
            readonly property bool awake: !!g && g.state === "active"
            readonly property var holders: g && g.users ? g.users.filter(function(n) { return n !== "Hyprland" }) : []
            visible: !!g && g.present
            Layout.fillWidth: true
            implicitHeight: gpuCol.implicitHeight + 16
            radius: root.radius
            color: root.tint(root.fg, 0.05)
            ColumnLayout {
              id: gpuCol
              anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter; margins: 10 }
              spacing: 4
              RowLayout {
                Layout.fillWidth: true
                spacing: 8
                Text { text: root.gGpu; color: root.fg; font.family: root.iconFont; font.pixelSize: 16 }
                Text { text: "NVIDIA"; color: root.fg; font.family: root.font; font.pixelSize: 13; font.bold: true }
                Rectangle {
                  implicitWidth: stateText.implicitWidth + 14; implicitHeight: 20; radius: 10
                  color: root.tint(gpuBox.awake ? root.accent : root.good, 0.2)
                  Text {
                    id: stateText
                    anchors.centerIn: parent
                    text: gpuBox.awake ? "allumée" : "en veille"
                    color: gpuBox.awake ? root.accent : root.good
                    font.family: root.font; font.pixelSize: 10; font.bold: true
                  }
                }
                Text {
                  Layout.fillWidth: true
                  horizontalAlignment: Text.AlignRight
                  elide: Text.ElideRight
                  visible: gpuBox.awake && gpuBox.g.temp !== undefined
                  text: visible ? Math.round(gpuBox.g.temp) + " °C · " + gpuBox.g.watts.toFixed(1) + " W · "
                                  + Math.round(gpuBox.g.memUsed) + " Mo VRAM" : ""
                  color: root.muted; font.family: root.font; font.pixelSize: 11
                }
              }
              Text {
                Layout.fillWidth: true
                visible: gpuBox.awake
                wrapMode: Text.Wrap
                maximumLineCount: 2
                elide: Text.ElideRight
                text: gpuBox.holders.length ? "Maintenue allumée par : " + gpuBox.holders.join(", ")
                                                   : "Aucune application ne l'utilise — elle devrait se mettre en veille."
                color: gpuBox.holders.length ? root.accent : root.muted
                font.family: root.font; font.pixelSize: 11
              }
            }
          }

          // Fans + NVMe
          RowLayout {
            Layout.fillWidth: true
            spacing: 14
            visible: !!root.s && (root.s.fans.length > 0 || root.s.nvmeTemp !== null)
            Text { text: root.gFan; color: root.muted; font.family: root.iconFont; font.pixelSize: 14 }
            Repeater {
              model: root.s ? root.s.fans : []
              delegate: Text {
                required property var modelData
                text: modelData.label + " " + modelData.rpm
                color: root.fg; font.family: root.font; font.pixelSize: 11
              }
            }
            Text { text: "tr/min"; color: root.muted; font.family: root.font; font.pixelSize: 10 }
            Item { Layout.fillWidth: true }
            Text {
              visible: !!root.s && root.s.nvmeTemp !== null
              text: root.s && root.s.nvmeTemp !== null ? "SSD " + Math.round(root.s.nvmeTemp) + " °C" : ""
              color: root.s ? root.tempColor(root.s.nvmeTemp) : root.muted; font.family: root.font; font.pixelSize: 11
            }
          }

          // Top processes
          SectionTitle { label: "Processus" }
          RowLayout {
            Layout.fillWidth: true
            spacing: 16
            ProcList { title: "Processeur"; rows: root.s ? root.s.topCpu : []; showCpu: true }
            ProcList { title: "Mémoire"; rows: root.s ? root.s.topMem : []; showCpu: false }
          }

          // Disk
          RowLayout {
            Layout.fillWidth: true
            SectionTitle { label: "Disque" }
            Text {
              Layout.fillWidth: true
              horizontalAlignment: Text.AlignRight
              elide: Text.ElideLeft
              text: !root.s ? "" : root.s.scanning ? "analyse…"
                  : root.s.scannedAt ? "analysé il y a " + root.duration(root.nowSec - root.s.scannedAt) : ""
              color: root.muted; font.family: root.font; font.pixelSize: 10
            }
            SmallButton { glyph: root.gRefresh; label: "Analyser"; enabled: !!root.s && !root.s.scanning; onClicked: root.rescan() }
          }
          Repeater {
            model: root.s ? root.s.disks : []
            delegate: ColumnLayout {
              required property var modelData
              Layout.fillWidth: true
              spacing: 3
              RowLayout {
                Layout.fillWidth: true
                Text { text: root.gDisk; color: root.muted; font.family: root.iconFont; font.pixelSize: 13 }
                Text { text: modelData.mount; color: root.fg; font.family: root.font; font.pixelSize: 12 }
                Text {
                  Layout.fillWidth: true
                  horizontalAlignment: Text.AlignRight
                  elide: Text.ElideLeft
                  text: root.bytes(modelData.used, 0) + " / " + root.bytes(modelData.total, 0) + " · " + root.bytes(modelData.free, 0) + " libres"
                  color: root.muted; font.family: root.font; font.pixelSize: 11
                }
              }
              Bar { fraction: modelData.used / modelData.total }
            }
          }

          // Biggest folders
          Repeater {
            model: root.s ? root.s.big : []
            delegate: RowLayout {
              required property var modelData
              Layout.fillWidth: true
              spacing: 8
              Text {
                Layout.fillWidth: true
                text: modelData.label
                color: root.fg; font.family: root.font; font.pixelSize: 11
                elide: Text.ElideMiddle
              }
              Text {
                text: root.bytes(modelData.size)
                color: modelData.size > 2 * 1073741824 ? root.accent : root.muted
                font.family: root.font; font.pixelSize: 11; font.bold: modelData.size > 2 * 1073741824
              }
              SmallButton {
                visible: modelData.kind !== ""
                glyph: modelData.kind === "pacman" ? root.gCopy : modelData.kind === "trash" ? root.gTrash : root.gBroom
                label: modelData.kind === "pacman" ? "Commande" : modelData.kind === "trash" ? "Vider" : "Nettoyer"
                danger: modelData.kind !== "pacman"
                onClicked: root.askClean(modelData)
              }
            }
          }
        }
      }
    }
  }

  // ---------- confirmation ----------
  Variants {
    model: Quickshell.screens
    PanelWindow {
      required property var modelData
      screen: modelData
      visible: !!root.confirm && (!Hyprland.focusedMonitor || Hyprland.focusedMonitor.name === modelData.name)
      anchors { top: true; bottom: true; left: true; right: true }
      color: "transparent"
      exclusionMode: ExclusionMode.Ignore
      WlrLayershell.namespace: "rebenga-system-confirm"
      WlrLayershell.layer: WlrLayer.Overlay
      WlrLayershell.keyboardFocus: visible ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
      onVisibleChanged: if (visible) { dialog.confirmFocused = false; keys.forceActiveFocus(); popIn.restart() }

      Rectangle {
        anchors.fill: parent
        color: Qt.rgba(0, 0, 0, 0.45)
        MouseArea { anchors.fill: parent; onPressed: if (!root.cleaning) root.confirm = null }
      }

      Item {
        id: keys
        focus: true
        Keys.onPressed: event => {
          if (event.key === Qt.Key_Escape && !root.cleaning) root.confirm = null
          else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) { if (dialog.confirmFocused) root.doClean(); else root.confirm = null }
          else if ([Qt.Key_Left, Qt.Key_Right, Qt.Key_Tab, Qt.Key_Backtab].indexOf(event.key) >= 0) dialog.confirmFocused = !dialog.confirmFocused
          event.accepted = true
        }
      }

      Rectangle {
        id: dialog
        property bool confirmFocused: false
        anchors.centerIn: parent
        width: 420
        height: dCol.implicitHeight + 40
        radius: root.radius + 4
        color: root.tint(Color.background, 0.99)
        border.width: 1
        border.color: root.tint(root.urgent, 0.45)
        opacity: 0
        MouseArea { anchors.fill: parent; onPressed: mouse => mouse.accepted = true }
        ParallelAnimation {
          id: popIn
          NumberAnimation { target: dialog; property: "opacity"; from: 0; to: 1; duration: 140 }
          NumberAnimation { target: dialog; property: "scale"; from: 0.94; to: 1; duration: 200; easing.type: Easing.OutBack }
        }

        ColumnLayout {
          id: dCol
          anchors { left: parent.left; right: parent.right; top: parent.top; margins: 20 }
          spacing: 12
          RowLayout {
            Layout.fillWidth: true
            spacing: 14
            Rectangle {
              implicitWidth: 44; implicitHeight: 44; radius: root.radius
              color: root.tint(root.urgent, 0.15)
              Text { anchors.centerIn: parent; text: root.gTrash; color: root.urgent; font.family: root.iconFont; font.pixelSize: 22 }
            }
            ColumnLayout {
              Layout.fillWidth: true
              spacing: 3
              Text {
                Layout.fillWidth: true
                text: root.confirm ? root.confirm.title : ""
                color: root.fg; font.family: root.font; font.pixelSize: 15; font.bold: true; wrapMode: Text.Wrap
              }
              Text {
                Layout.fillWidth: true
                text: root.confirm ? root.confirm.message : ""
                color: root.muted; font.family: root.font; font.pixelSize: 12; wrapMode: Text.Wrap
              }
            }
          }
          Text {
            Layout.fillWidth: true
            text: root.confirm ? root.bytes(root.confirm.size) + " à libérer" : ""
            color: root.accent; font.family: root.font; font.pixelSize: 12; font.bold: true
          }
          RowLayout {
            Layout.fillWidth: true
            spacing: 8
            Item { Layout.fillWidth: true }
            DialogButton { label: "Annuler"; focused: !dialog.confirmFocused; enabled: !root.cleaning; onClicked: root.confirm = null; onHovered: dialog.confirmFocused = false }
            DialogButton {
              label: root.cleaning ? "…" : (root.confirm ? root.confirm.confirmLabel : "")
              primary: true; focused: dialog.confirmFocused; enabled: !root.cleaning
              onClicked: root.doClean(); onHovered: dialog.confirmFocused = true
            }
          }
          Text {
            Layout.alignment: Qt.AlignRight
            text: "↵ valider le bouton actif   ← → changer   Échap annuler"
            color: root.muted; font.family: root.font; font.pixelSize: 9
          }
        }
      }
    }
  }

  // ---------- components ----------

  component SectionTitle: Text {
    property string label
    text: label.toUpperCase()
    color: root.muted
    font.family: root.font; font.pixelSize: 10; font.bold: true; font.letterSpacing: 1.2
    Layout.topMargin: 2
  }

  component Bar: Rectangle {
    property real fraction: 0
    Layout.fillWidth: true
    implicitHeight: 6; radius: 3
    color: root.tint(root.fg, 0.1)
    Rectangle {
      width: parent.width * Math.max(0, Math.min(1, parent.fraction)); height: parent.height; radius: 3
      color: parent.fraction >= 0.9 ? root.urgent : root.accent
      Behavior on width { NumberAnimation { duration: 300; easing.type: Easing.OutCubic } }
    }
  }

  // Stat tile: glyph + title, big value, detail line, then a sparkline (history) or a bar (fraction).
  component Tile: Rectangle {
    id: tile
    property string glyph
    property string title
    property string value
    property string detail
    property color detailColor: root.muted
    property var history: []
    property real maxValue: 100      // 0 = auto-scale
    property real fraction: -1
    Layout.preferredWidth: (col.width - 8) / 2
    Layout.maximumWidth: (col.width - 8) / 2
    implicitHeight: tCol.implicitHeight + 18
    radius: root.radius
    color: root.tint(root.fg, 0.05)
    ColumnLayout {
      id: tCol
      anchors { left: parent.left; right: parent.right; top: parent.top; margins: 10 }
      spacing: 3
      RowLayout {
        spacing: 6
        Text { text: tile.glyph; color: root.muted; font.family: root.iconFont; font.pixelSize: 13 }
        Text { text: tile.title; color: root.muted; font.family: root.font; font.pixelSize: 10 }
      }
      Text { Layout.fillWidth: true; elide: Text.ElideRight; text: tile.value; color: root.fg; font.family: root.font; font.pixelSize: 18; font.bold: true }
      Text {
        Layout.fillWidth: true
        text: tile.detail
        color: tile.detailColor; font.family: root.font; font.pixelSize: 10
        elide: Text.ElideRight
      }
      Canvas {
        id: spark
        visible: tile.history.length > 1
        Layout.fillWidth: true
        Layout.preferredHeight: 22
        onPaint: {
          var ctx = getContext("2d")
          ctx.reset()
          var h = tile.history
          if (h.length < 2) return
          var max = tile.maxValue > 0 ? tile.maxValue : Math.max.apply(null, h.concat([1]))
          ctx.beginPath()
          for (var i = 0; i < h.length; i++) {
            var x = i / (h.length - 1) * width
            var y = height - 1 - (h[i] / max) * (height - 2)
            if (i === 0) ctx.moveTo(x, y); else ctx.lineTo(x, y)
          }
          ctx.strokeStyle = root.accent
          ctx.lineWidth = 1.5
          ctx.stroke()
          ctx.lineTo(width, height); ctx.lineTo(0, height); ctx.closePath()
          ctx.fillStyle = root.tint(root.accent, 0.15)
          ctx.fill()
        }
        Connections { target: tile; function onHistoryChanged() { spark.requestPaint() } }
      }
      Bar { visible: tile.fraction >= 0 && tile.history.length <= 1; fraction: tile.fraction; Layout.topMargin: 6 }
    }
  }

  component ProcList: ColumnLayout {
    id: procList
    property string title
    property var rows: []
    property bool showCpu: true
    Layout.preferredWidth: (col.width - 16) / 2
    Layout.maximumWidth: (col.width - 16) / 2
    spacing: 2
    Text { text: procList.title; color: root.muted; font.family: root.font; font.pixelSize: 10 }
    Repeater {
      model: procList.rows
      delegate: RowLayout {
        required property var modelData
        Layout.fillWidth: true
        Text {
          Layout.fillWidth: true
          text: modelData.name
          color: root.fg; font.family: root.font; font.pixelSize: 11
          elide: Text.ElideRight
        }
        Text {
          text: procList.showCpu ? modelData.cpu.toFixed(1) + " %" : root.bytes(modelData.mem, 1)
          color: root.muted; font.family: root.font; font.pixelSize: 11
        }
      }
    }
  }

  component SmallButton: Rectangle {
    id: sb
    property string glyph
    property string label
    property bool danger: false
    signal clicked()
    readonly property color tone: danger ? root.urgent : root.fg
    implicitHeight: 22
    implicitWidth: sbRow.implicitWidth + 14
    radius: 5
    opacity: enabled ? 1 : 0.4
    color: sbMouse.containsMouse ? root.tint(tone, 0.16) : root.tint(tone, 0.07)
    Behavior on color { ColorAnimation { duration: 90 } }
    Row {
      id: sbRow
      anchors.centerIn: parent
      spacing: 4
      Text { text: sb.glyph; color: sb.tone; font.family: root.iconFont; font.pixelSize: 11; anchors.verticalCenter: parent.verticalCenter }
      Text { text: sb.label; color: sb.tone; font.family: root.font; font.pixelSize: 10; anchors.verticalCenter: parent.verticalCenter }
    }
    MouseArea {
      id: sbMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: if (sb.enabled) sb.clicked()
    }
  }

  component DialogButton: Rectangle {
    id: btn
    property string label
    property bool primary: false
    property bool focused: false
    signal clicked()
    signal hovered()
    implicitWidth: Math.max(96, bText.implicitWidth + 28)
    implicitHeight: 36
    radius: root.radius
    opacity: enabled ? 1 : 0.5
    color: primary ? (bMouse.containsMouse ? Qt.lighter(root.urgent, 1.12) : root.urgent)
                   : (bMouse.containsMouse ? root.tint(root.fg, 0.12) : root.tint(root.fg, 0.06))
    border.width: focused ? 2 : 0
    border.color: primary ? Qt.lighter(root.urgent, 1.4) : root.accent
    Text {
      id: bText
      anchors.centerIn: parent
      text: btn.label
      color: btn.primary ? Color.background : root.fg
      font.family: root.font; font.pixelSize: 13; font.bold: btn.primary
    }
    MouseArea {
      id: bMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onEntered: btn.hovered()
      onClicked: if (btn.enabled) btn.clicked()
    }
  }
}
