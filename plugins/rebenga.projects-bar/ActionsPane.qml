import QtQuick
import QtQuick.Layouts
import qs.Commons

// Header + branch picker + action rows for a project or a group.
// Shared by the bar popup and the centre picker. All state lives in `ctx` (Bar.qml).
ColumnLayout {
  id: pane
  property var ctx
  property var target: ctx.target          // { kind: "project"|"group", item }
  property bool showKeys: true
  property string keyPrefix: ""
  readonly property var item: target ? target.item : null
  readonly property bool isProject: !!target && target.kind === "project"
  readonly property var info: ctx.branchInfo
  readonly property bool hasGit: isProject && !!item && !!item.git
  readonly property color fg: Color.foreground
  property bool branchesOpen: false
  property string filter: ""

  spacing: 2

  onTargetChanged: { branchesOpen = false; filter = "" }

  function matches(name) { return !filter || name.toLowerCase().indexOf(filter.toLowerCase()) >= 0 }

  readonly property var branchRows: {
    if (!info || !info.ok) return []
    var rows = []
    for (var i = 0; i < info.local.length; i++)
      if (matches(info.local[i])) rows.push({ name: info.local[i], remote: false })
    for (var j = 0; j < info.remote.length; j++)
      if (matches(info.remote[j])) rows.push({ name: info.remote[j], remote: true })
    return rows.slice(0, 40)
  }
  readonly property bool canCreateBranch: {
    if (!filter || !info || !info.ok) return false
    if (!/^[A-Za-z0-9][A-Za-z0-9._\/-]*$/.test(filter)) return false
    return info.local.indexOf(filter) < 0 && info.remote.indexOf(filter) < 0
  }

  // ---- header ----
  RowLayout {
    Layout.fillWidth: true
    Layout.bottomMargin: 6
    spacing: 10
    IconTile {
      size: 36
      glyph: !pane.isProject ? ctx.gFolder : (pane.item && pane.item.git ? ctx.gGit : ctx.gFolder)
      glyphColor: Color.accent
      color: Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.18)
    }
    ColumnLayout {
      Layout.fillWidth: true
      spacing: 1
      Text {
        Layout.fillWidth: true
        text: pane.item ? pane.item.name : ""
        color: pane.fg; font.family: Style.font.family; font.pixelSize: 15; font.bold: true
        elide: Text.ElideRight
      }
      Text {
        Layout.fillWidth: true
        text: pane.item ? ctx.prettyPath(pane.item.path) : ""
        color: Color.muted; font.family: Style.font.family; font.pixelSize: 11
        elide: Text.ElideMiddle
      }
    }
  }

  // ---- branch picker (git projects) ----
  Rectangle {
    visible: pane.hasGit
    Layout.fillWidth: true
    Layout.bottomMargin: 6
    implicitHeight: branchCol.implicitHeight + 12
    radius: Math.max(6, Style.cornerRadius)
    color: Qt.rgba(pane.fg.r, pane.fg.g, pane.fg.b, 0.05)

    ColumnLayout {
      id: branchCol
      anchors { left: parent.left; right: parent.right; top: parent.top; margins: 6 }
      spacing: 4

      Rectangle {
        Layout.fillWidth: true
        implicitHeight: 30
        radius: Math.max(5, Style.cornerRadius - 2)
        color: headMouse.containsMouse ? Qt.rgba(pane.fg.r, pane.fg.g, pane.fg.b, 0.07) : "transparent"
        RowLayout {
          anchors { fill: parent; leftMargin: 6; rightMargin: 6 }
          spacing: 8
          Text { text: ctx.gBranch; color: Color.accent; font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 14 }
          Text {
            Layout.fillWidth: true
            text: ctx.branchSel.name || (pane.info && pane.info.ok ? pane.info.current : (pane.item && pane.item.git ? pane.item.git.branch : ""))
            color: pane.fg; font.family: Style.font.family; font.pixelSize: 12
            elide: Text.ElideRight
          }
          Text {
            visible: ctx.branchSel.name !== "" && pane.info && ctx.branchSel.name !== pane.info.current
            text: ctx.branchSel.isNew ? "nouvelle · worktree" : "worktree"
            color: Color.accent; font.family: Style.font.family; font.pixelSize: 10
          }
          Text {
            text: ctx.gChevron
            rotation: pane.branchesOpen ? 180 : 0
            Behavior on rotation { NumberAnimation { duration: 120 } }
            color: Color.muted; font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 14
          }
        }
        MouseArea {
          id: headMouse
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: {
            pane.branchesOpen = !pane.branchesOpen
            if (pane.branchesOpen) branchField.focusInput()
          }
        }
      }

      Field {
        id: branchField
        visible: pane.branchesOpen
        glyph: ctx.gSearch
        placeholder: "Filtrer ou nouvelle branche…"
        value: pane.filter
        onEdited: v => pane.filter = v
        onEscaped: pane.branchesOpen = false
        onAccepted: {
          if (pane.branchRows.length) ctx.selectBranch(pane.branchRows[0].name, false)
          else if (pane.canCreateBranch) ctx.selectBranch(pane.filter, true)
          pane.branchesOpen = false
        }
      }

      Flickable {
        visible: pane.branchesOpen
        Layout.fillWidth: true
        Layout.preferredHeight: Math.min(160, branchList.implicitHeight)
        contentHeight: branchList.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        ColumnLayout {
          id: branchList
          width: parent.width
          spacing: 1
          Text {
            visible: !pane.info
            text: "Chargement des branches…"
            color: Color.muted; font.family: Style.font.family; font.pixelSize: 11
          }
          Repeater {
            model: pane.branchRows
            delegate: Rectangle {
              id: brow
              required property var modelData
              readonly property bool isCurrent: pane.info && modelData.name === pane.info.current
              readonly property bool isSel: (ctx.branchSel.name || (pane.info ? pane.info.current : "")) === modelData.name
              Layout.fillWidth: true
              implicitHeight: 26
              radius: 4
              color: bMouse.containsMouse ? Qt.rgba(pane.fg.r, pane.fg.g, pane.fg.b, 0.08) : "transparent"
              RowLayout {
                anchors { fill: parent; leftMargin: 8; rightMargin: 8 }
                spacing: 6
                Text {
                  text: brow.isSel ? ctx.gCheck : (brow.modelData.remote ? ctx.gCloud : ctx.gBranch)
                  color: brow.isSel ? Color.accent : Color.muted
                  font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 12
                }
                Text {
                  Layout.fillWidth: true
                  text: brow.modelData.name
                  color: pane.fg; font.family: Style.font.family; font.pixelSize: 12
                  elide: Text.ElideRight
                }
                Text {
                  visible: brow.isCurrent || (!!pane.info && !!pane.info.worktrees[brow.modelData.name])
                  text: brow.isCurrent ? "actuelle" : "worktree"
                  color: Color.muted; font.family: Style.font.family; font.pixelSize: 10
                }
              }
              MouseArea {
                id: bMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: { ctx.selectBranch(brow.modelData.name, false); pane.branchesOpen = false }
              }
            }
          }
          Rectangle {
            visible: pane.canCreateBranch
            Layout.fillWidth: true
            implicitHeight: 26
            radius: 4
            color: nMouse.containsMouse ? Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.15) : "transparent"
            RowLayout {
              anchors { fill: parent; leftMargin: 8; rightMargin: 8 }
              spacing: 6
              Text { text: ctx.gBranchPlus; color: Color.accent; font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 12 }
              Text {
                Layout.fillWidth: true
                text: "Créer la branche « " + pane.filter + " »"
                color: Color.accent; font.family: Style.font.family; font.pixelSize: 12
                elide: Text.ElideRight
              }
            }
            MouseArea {
              id: nMouse
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: { ctx.selectBranch(pane.filter, true); pane.branchesOpen = false }
            }
          }
        }
      }
    }
  }

  // ---- actions ----
  Repeater {
    model: ctx.actionsFor(pane.target)
    delegate: Rectangle {
      id: act
      required property var modelData
      readonly property bool danger: !!modelData.danger
      readonly property color tone: danger ? Color.urgent : pane.fg
      Layout.fillWidth: true
      Layout.topMargin: danger ? 6 : 0
      implicitHeight: 44
      radius: Math.max(6, Style.cornerRadius)
      color: actMouse.containsMouse ? Qt.rgba(tone.r, tone.g, tone.b, danger ? 0.14 : 0.08) : "transparent"
      // hairline above the destructive action
      Rectangle {
        visible: act.danger
        anchors { left: parent.left; right: parent.right; bottom: parent.top; bottomMargin: 3; leftMargin: 6; rightMargin: 6 }
        height: 1
        color: Qt.rgba(pane.fg.r, pane.fg.g, pane.fg.b, 0.1)
      }
      Behavior on color { ColorAnimation { duration: 90 } }
      RowLayout {
        anchors { fill: parent; leftMargin: 6; rightMargin: 8 }
        spacing: 10
        IconTile {
          image: act.modelData.image || ""
          glyph: act.modelData.glyph || ""
          glyphColor: act.tone
          color: act.danger ? Qt.rgba(act.tone.r, act.tone.g, act.tone.b, 0.12) : Qt.rgba(pane.fg.r, pane.fg.g, pane.fg.b, 0.07)
        }
        ColumnLayout {
          Layout.fillWidth: true
          spacing: 0
          Text {
            text: act.modelData.label
            color: act.tone; font.family: Style.font.family; font.pixelSize: 13
          }
          Text {
            Layout.fillWidth: true
            visible: !!act.modelData.hint
            text: act.modelData.hint || ""
            color: Color.muted; font.family: Style.font.family; font.pixelSize: 10
            elide: Text.ElideMiddle
          }
        }
        Keycap { visible: pane.showKeys && !!act.modelData.key; label: pane.keyPrefix + String(act.modelData.key || "").toUpperCase() }
      }
      MouseArea {
        id: actMouse
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: ctx.run(act.modelData)
      }
    }
  }

  Text {
    Layout.fillWidth: true
    Layout.topMargin: 4
    visible: ctx.busyMessage !== ""
    text: ctx.busyMessage
    wrapMode: Text.Wrap
    color: ctx.busyError ? Color.urgent : Color.muted
    font.family: Style.font.family; font.pixelSize: 11
  }
}
