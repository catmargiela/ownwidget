import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import QtQuick.Layouts
import qs.Commons

// Desktop card (below windows) showing coding agents. Data comes from collect.py.
Item {
  id: root

  readonly property string pluginDir: Qt.resolvedUrl(".").toString().replace("file://", "")
  property var snap: ({ sessions: [], activity: [], usage: {} })
  property real nowSec: Date.now() / 1000
  property var notifiedStates: ({})
  property bool initialized: false

  readonly property var claude: snap.usage && snap.usage.claude ? snap.usage.claude : null
  readonly property bool needsYou: {
    var list = snap.sessions || []
    for (var i = 0; i < list.length; i++) {
      var s = list[i]
      if (s.state === "permission") return true
      if (s.state === "reply" && nowSec - s.since < 900) return true
    }
    return false
  }

  // Blinking is a slow on/off toggle, not an animation: a continuous animation makes the
  // compositor repaint at the monitor's refresh rate (240 Hz here) and costs ~40 % of a core.
  property bool blink: true
  readonly property bool anyWorking: (snap.sessions || []).some(function(s) { return s.state === "working" })
  Timer {
    interval: 900; repeat: true
    running: root.needsYou || root.anyWorking
    onTriggered: root.blink = !root.blink
    onRunningChanged: if (!running) root.blink = true
  }

  readonly property color fg: Color.foreground
  readonly property color accent: Color.accent
  readonly property color urgent: Color.urgent
  readonly property color muted: Color.muted
  readonly property string font: Style.font.family

  function stateColor(state) {
    if (state === "permission") return urgent
    if (state === "reply") return accent
    if (state === "working") return "#7fbf7f"
    return muted
  }

  function stateLabel(s) {
    if (s.state === "permission") return "attend une permission"
    if (s.state === "reply") return nowSec - s.since < 900 ? "attend votre réponse" : "inactif"
    if (s.state === "working") return "travaille"
    return "ouvert"
  }

  function duration(sec) {
    sec = Math.max(0, Math.floor(sec))
    if (sec < 60) return sec + " s"
    if (sec < 3600) return Math.floor(sec / 60) + " min"
    if (sec < 86400) return Math.floor(sec / 3600) + " h " + ("0" + Math.floor(sec % 3600 / 60)).slice(-2)
    return Math.floor(sec / 86400) + " j"
  }

  function tokens(n) {
    if (n >= 1e9) return (n / 1e9).toFixed(1) + " G"
    if (n >= 1e6) return (n / 1e6).toFixed(1) + " M"
    if (n >= 1e3) return Math.round(n / 1e3) + " k"
    return String(n || 0)
  }

  function limitLabel(label) {
    if (label.indexOf("5-hour") >= 0) return "Session 5 h"
    if (label.indexOf("7-day") >= 0) return "Semaine"
    return label
  }

  function clock(epoch) {
    return Qt.formatTime(new Date(epoch * 1000), "HH:mm")
  }

  // Notification with a "Y aller" button that jumps to the session's terminal.
  // New-session notices are skipped when that terminal already has focus.
  function notifyJump(title, body, address, urgency, skipIfFocused) {
    var script = (skipIfFocused ? '[ "$(hyprctl activewindow -j | jq -r .address)" = "$4" ] && exit 0; ' : '')
      + 'a=$(notify-send -a Agents -u "$1" -A open="Y aller" "$2" "$3"); '
      + '[ "$a" = open ] && [ -n "$4" ] && hyprctl dispatch "hl.dsp.focus({ window = \\"address:$4\\" })"'
    Quickshell.execDetached(["sh", "-c", script, "agents-desk", urgency, title, body, address || ""])
  }

  function notifyTransitions() {
    var seen = {}
    var list = snap.sessions || []
    for (var i = 0; i < list.length; i++) {
      var s = list[i]
      var who = (s.tool === "codex" ? "Codex" : "Claude") + " · " + s.project
      seen[s.id] = s.state
      if (initialized && !(s.id in notifiedStates))
        notifyJump(who, "Nouvelle session", s.window, "normal", true)
      else if (s.state === "permission" && notifiedStates[s.id] !== "permission")
        notifyJump(who, "Attend une permission", s.window, "critical", false)
    }
    notifiedStates = seen
    initialized = true
  }

  // Long-running watcher: emits one JSON line only when something changed.
  Process {
    id: collectProc
    running: true
    command: ["python3", "-I", root.pluginDir + "collect.py"]
    stdout: SplitParser {
      onRead: line => {
        try {
          root.snap = JSON.parse(line)
          root.notifyTransitions()
        } catch (e) {}
      }
    }
    onExited: restartTimer.start()
  }

  Timer { id: restartTimer; interval: 5000; onTriggered: collectProc.running = true }

  Process { id: usageProc; command: ["omarchy-agent-usage-update"] }

  Timer {
    interval: 2000; running: true; repeat: true
    onTriggered: root.nowSec = Date.now() / 1000
  }

  Timer {
    interval: 300000; running: true; repeat: true; triggeredOnStart: true
    onTriggered: if (!usageProc.running) usageProc.running = true
  }

  // Jump to the terminal hosting the session (switches workspace if needed).
  function openSession(address) {
    if (!address) return
    Quickshell.execDetached(["hyprctl", "dispatch", "hl.dsp.focus({ window = \"address:" + address + "\" })"])
  }

  Variants {
    model: Quickshell.screens

    PanelWindow {
      id: win
      required property var modelData
      screen: modelData
      anchors { top: true; right: true }
      margins { top: 60; right: 40 }
      implicitWidth: 440
      implicitHeight: card.implicitHeight
      color: "transparent"
      WlrLayershell.namespace: "rebenga-agents-desk"
      WlrLayershell.layer: WlrLayer.Bottom
      WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
      exclusionMode: ExclusionMode.Ignore

      Rectangle {
        id: card
        anchors.left: parent.left
        anchors.right: parent.right
        implicitHeight: content.implicitHeight + 32
        radius: Math.max(6, Style.cornerRadius)
        color: Qt.rgba(Color.background.r, Color.background.g, Color.background.b, 0.82)
        border.width: root.needsYou ? 2 : 1
        border.color: !root.needsYou ? Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.15)
                    : root.blink ? root.urgent : Qt.rgba(root.urgent.r, root.urgent.g, root.urgent.b, 0.25)

        ColumnLayout {
          id: content
          anchors { left: parent.left; right: parent.right; top: parent.top; margins: 16 }
          spacing: 10

          // Header
          RowLayout {
            Layout.fillWidth: true
            Text {
              text: "Agents"
              color: root.fg; font.family: root.font; font.pixelSize: 18; font.bold: true
            }
            Text {
              text: root.claude && root.claude.tier ? root.claude.tier : ""
              color: root.muted; font.family: root.font; font.pixelSize: 12
            }
            Item { Layout.fillWidth: true }
            Text {
              visible: root.needsYou
              text: "● on vous attend"
              color: root.urgent; font.family: root.font; font.pixelSize: 12; font.bold: true
            }
          }

          // 1 + 2. Active sessions
          SectionTitle { label: "Sessions actives" }
          Text {
            visible: (root.snap.sessions || []).length === 0
            text: "Aucune session ouverte"
            color: root.muted; font.family: root.font; font.pixelSize: 12
          }
          Repeater {
            model: root.snap.sessions || []
            delegate: Rectangle {
              required property var modelData
              Layout.fillWidth: true
              implicitHeight: sessionCol.implicitHeight + 14
              radius: 4
              color: mouse.containsMouse ? Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.08)
                                         : Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.04)
              border.width: modelData.state === "permission" ? 1 : 0
              border.color: root.urgent

              MouseArea {
                id: mouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: modelData.window ? Qt.PointingHandCursor : Qt.ArrowCursor
                onClicked: root.openSession(modelData.window)
              }

              ColumnLayout {
                id: sessionCol
                anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter; margins: 10 }
                spacing: 2
                RowLayout {
                  Layout.fillWidth: true
                  spacing: 8
                  Rectangle {
                    width: 9; height: 9; radius: 5
                    color: root.stateColor(modelData.state)
                    opacity: modelData.state === "working" && !root.blink ? 0.3 : 1
                  }
                  Text {
                    text: modelData.project
                    color: root.fg; font.family: root.font; font.pixelSize: 14; font.bold: true
                    elide: Text.ElideRight
                    Layout.maximumWidth: 170
                  }
                  Text {
                    text: modelData.tool === "codex" ? "Codex" : "Claude"
                    color: root.muted; font.family: root.font; font.pixelSize: 11
                  }
                  Item { Layout.fillWidth: true }
                  Text {
                    text: root.duration(root.nowSec - modelData.startedAt)
                    color: root.muted; font.family: root.font; font.pixelSize: 11
                  }
                }
                Text {
                  Layout.fillWidth: true
                  text: root.stateLabel(modelData)
                        + (modelData.since && modelData.state !== "working" ? " · depuis " + root.duration(root.nowSec - modelData.since) : "")
                  color: root.stateColor(modelData.state); font.family: root.font; font.pixelSize: 12
                }
                Text {
                  Layout.fillWidth: true
                  visible: modelData.lastAction !== ""
                  text: modelData.lastAction
                  color: root.muted; font.family: root.font; font.pixelSize: 11
                  elide: Text.ElideRight
                }
              }
            }
          }

          // 3. Activity feed
          SectionTitle { label: "Activité"; visible: (root.snap.activity || []).length > 0 }
          Repeater {
            model: root.snap.activity || []
            delegate: RowLayout {
              required property var modelData
              Layout.fillWidth: true
              spacing: 8
              Text {
                text: root.clock(modelData.time)
                color: root.muted; font.family: root.font; font.pixelSize: 11
              }
              Text {
                text: modelData.project
                color: root.accent; font.family: root.font; font.pixelSize: 11
                Layout.maximumWidth: 90
                elide: Text.ElideRight
              }
              Text {
                Layout.fillWidth: true
                text: modelData.text
                color: root.fg; font.family: root.font; font.pixelSize: 11
                elide: Text.ElideRight
              }
            }
          }

          // 4. Limits with projection
          SectionTitle { label: "Limites Claude"; visible: !!root.claude && root.claude.limits.length > 0 }
          Repeater {
            model: root.claude ? root.claude.limits : []
            delegate: ColumnLayout {
              required property var modelData
              Layout.fillWidth: true
              spacing: 3
              readonly property real pct: modelData.percent
              readonly property bool risky: modelData.projected !== null && modelData.projected >= 1
              RowLayout {
                Layout.fillWidth: true
                Text {
                  text: root.limitLabel(modelData.label)
                  color: root.fg; font.family: root.font; font.pixelSize: 12
                }
                Text {
                  text: Math.round(pct * 100) + " %"
                  color: pct >= 0.9 ? root.urgent : root.fg
                  font.family: root.font; font.pixelSize: 12; font.bold: true
                }
                Item { Layout.fillWidth: true }
                Text {
                  text: "remise à zéro dans " + root.duration(modelData.resetsAt - root.nowSec)
                  color: root.muted; font.family: root.font; font.pixelSize: 11
                }
              }
              Rectangle {
                Layout.fillWidth: true
                implicitHeight: 6; radius: 3
                color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.1)
                Rectangle {
                  width: parent.width * Math.min(1, pct); height: parent.height; radius: 3
                  color: pct >= 0.9 ? root.urgent : root.accent
                }
                Rectangle {
                  visible: modelData.projected !== null
                  x: parent.width * Math.min(1, modelData.projected || 0) - 1
                  width: 2; height: parent.height + 4; y: -2
                  color: risky ? root.urgent : root.muted
                }
              }
              Text {
                visible: modelData.projected !== null
                text: risky ? "à ce rythme : limite atteinte avant la remise à zéro"
                            : "à ce rythme : ~" + Math.round((modelData.projected || 0) * 100) + " % à la remise à zéro"
                color: risky ? root.urgent : root.muted
                font.family: root.font; font.pixelSize: 10
              }
            }
          }

          // 5. Stats
          SectionTitle { label: "Statistiques"; visible: !!root.claude }
          RowLayout {
            visible: !!root.claude
            Layout.fillWidth: true
            spacing: 16
            Stat { value: root.claude ? root.tokens(root.claude.todayTokens) : ""; label: "tokens aujourd'hui" }
            Stat { value: root.claude ? String(root.claude.todayPrompts) : ""; label: "demandes" }
            Stat { value: root.claude ? String(root.claude.todaySessions) : ""; label: "sessions" }
            Stat { value: root.claude ? String(root.claude.activeDays) : ""; label: "jours actifs" }
          }
          // 7-day bars
          RowLayout {
            id: week
            visible: !!root.claude
            Layout.fillWidth: true
            Layout.preferredHeight: 54
            spacing: 6
            readonly property var days: root.claude ? root.claude.days : []
            readonly property real peak: {
              var m = 1
              for (var i = 0; i < days.length; i++) m = Math.max(m, days[i].tokens)
              return m
            }
            Repeater {
              model: week.days
              delegate: ColumnLayout {
                required property var modelData
                required property int index
                Layout.fillWidth: true
                Layout.fillHeight: true
                spacing: 2
                Item { Layout.fillHeight: true }
                Rectangle {
                  Layout.fillWidth: true
                  Layout.preferredHeight: Math.max(2, 34 * modelData.tokens / week.peak)
                  radius: 2
                  color: index === week.days.length - 1 ? root.accent : Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.35)
                }
                Text {
                  Layout.alignment: Qt.AlignHCenter
                  text: ["di", "lu", "ma", "me", "je", "ve", "sa"][new Date(modelData.date + "T12:00:00").getDay()]
                  color: root.muted; font.family: root.font; font.pixelSize: 10
                }
              }
            }
          }
        }
      }
    }
  }

  component SectionTitle: Text {
    property string label
    text: label.toUpperCase()
    color: root.muted
    font.family: root.font; font.pixelSize: 10; font.bold: true; font.letterSpacing: 1.2
    Layout.topMargin: 4
  }

  component Stat: ColumnLayout {
    property string value
    property string label
    spacing: 0
    Text { text: parent.value; color: root.fg; font.family: root.font; font.pixelSize: 16; font.bold: true }
    Text { text: parent.label; color: root.muted; font.family: root.font; font.pixelSize: 10 }
  }
}
