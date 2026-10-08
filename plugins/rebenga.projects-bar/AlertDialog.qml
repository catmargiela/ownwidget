import QtQuick
import QtQuick.Layouts
import qs.Commons

// Confirmation alert. `alert` = { title, message, risks: [], details: [], confirmLabel, danger, loading }.
// Cancel has focus by default; ←/→/Tab switch buttons, Enter activates the focused one, Esc cancels.
Rectangle {
  id: dialog
  property var ctx
  readonly property var alert: ctx.alert
  readonly property color fg: Color.foreground
  readonly property color tone: alert && alert.danger ? Color.urgent : Color.accent
  property bool confirmFocused: false

  width: 440
  height: col.implicitHeight + 40
  radius: Math.max(12, Style.cornerRadius + 4)
  color: Qt.rgba(Color.background.r, Color.background.g, Color.background.b, 0.99)
  border.width: 1
  border.color: Qt.rgba(tone.r, tone.g, tone.b, 0.45)

  function open() {
    confirmFocused = false
    keys.forceActiveFocus()
    popIn.restart()
  }

  function activate() {
    if (confirmFocused) ctx.confirmAlert()
    else ctx.cancelAlert()
  }

  scale: 0.96
  opacity: 0
  ParallelAnimation {
    id: popIn
    NumberAnimation { target: dialog; property: "opacity"; from: 0; to: 1; duration: 140; easing.type: Easing.OutCubic }
    NumberAnimation { target: dialog; property: "scale"; from: 0.94; to: 1; duration: 200; easing.type: Easing.OutBack }
  }

  // Swallow clicks so the backdrop doesn't cancel.
  MouseArea { anchors.fill: parent; onPressed: mouse => mouse.accepted = true }

  Item {
    id: keys
    focus: true
    Keys.onPressed: event => {
      if (event.key === Qt.Key_Escape) { dialog.ctx.cancelAlert(); event.accepted = true }
      else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) { dialog.activate(); event.accepted = true }
      else if (event.key === Qt.Key_Left || event.key === Qt.Key_Right || event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
        dialog.confirmFocused = !dialog.confirmFocused; event.accepted = true
      }
    }
  }

  ColumnLayout {
    id: col
    anchors { left: parent.left; right: parent.right; top: parent.top; margins: 20 }
    spacing: 12

    RowLayout {
      Layout.fillWidth: true
      spacing: 14
      IconTile {
        size: 44
        glyph: dialog.alert && dialog.alert.danger ? dialog.ctx.gTrash : dialog.ctx.gAlert
        glyphColor: dialog.tone
        color: Qt.rgba(dialog.tone.r, dialog.tone.g, dialog.tone.b, 0.15)
      }
      ColumnLayout {
        Layout.fillWidth: true
        spacing: 3
        Text {
          Layout.fillWidth: true
          text: dialog.alert ? dialog.alert.title : ""
          color: dialog.fg; font.family: Style.font.family; font.pixelSize: 15; font.bold: true
          wrapMode: Text.Wrap
        }
        Text {
          Layout.fillWidth: true
          text: dialog.alert ? dialog.alert.message : ""
          color: Color.muted; font.family: Style.font.family; font.pixelSize: 12
          wrapMode: Text.Wrap
        }
      }
    }

    // Contents (e.g. projects inside a group)
    Text {
      Layout.fillWidth: true
      visible: !!dialog.alert && !!dialog.alert.details && dialog.alert.details.length > 0
      text: dialog.alert && dialog.alert.details ? dialog.alert.details.join("  ·  ") : ""
      color: dialog.fg; font.family: Style.font.family; font.pixelSize: 11
      wrapMode: Text.Wrap
    }

    // Risks
    Rectangle {
      visible: !!dialog.alert && (dialog.alert.loading || (dialog.alert.risks && dialog.alert.risks.length > 0))
      Layout.fillWidth: true
      implicitHeight: riskCol.implicitHeight + 16
      radius: Math.max(6, Style.cornerRadius)
      color: Qt.rgba(Color.urgent.r, Color.urgent.g, Color.urgent.b, 0.1)
      ColumnLayout {
        id: riskCol
        anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter; margins: 10 }
        spacing: 4
        Text {
          visible: !!dialog.alert && !!dialog.alert.loading
          text: "Vérification du travail non sauvegardé…"
          color: Color.muted; font.family: Style.font.family; font.pixelSize: 11
        }
        Repeater {
          model: dialog.alert && dialog.alert.risks ? dialog.alert.risks : []
          delegate: RowLayout {
            required property string modelData
            Layout.fillWidth: true
            spacing: 8
            Text { text: dialog.ctx.gAlert; color: Color.urgent; font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 12 }
            Text {
              Layout.fillWidth: true
              text: modelData
              color: dialog.fg; font.family: Style.font.family; font.pixelSize: 11
              wrapMode: Text.Wrap
            }
          }
        }
      }
    }

    Text {
      Layout.fillWidth: true
      visible: !!dialog.alert && !!dialog.alert.error
      text: dialog.alert && dialog.alert.error ? dialog.alert.error : ""
      color: Color.urgent; font.family: Style.font.family; font.pixelSize: 11
      wrapMode: Text.Wrap
    }

    // Buttons
    RowLayout {
      Layout.fillWidth: true
      Layout.topMargin: 6
      spacing: 8
      Item { Layout.fillWidth: true }
      AlertButton {
        label: "Annuler"
        focused: !dialog.confirmFocused
        onClicked: dialog.ctx.cancelAlert()
        onHovered: dialog.confirmFocused = false
      }
      AlertButton {
        label: dialog.alert && dialog.alert.busy ? "…" : (dialog.alert ? dialog.alert.confirmLabel : "")
        primary: true
        tone: dialog.tone
        enabled: !!dialog.alert && !dialog.alert.loading && !dialog.alert.busy
        focused: dialog.confirmFocused
        onClicked: dialog.ctx.confirmAlert()
        onHovered: dialog.confirmFocused = true
      }
    }

    Text {
      Layout.alignment: Qt.AlignRight
      text: "↵ valider le bouton actif   ← → changer   Échap annuler"
      color: Color.muted; font.family: Style.font.family; font.pixelSize: 9
    }
  }

  component AlertButton: Rectangle {
    id: btn
    property string label
    property bool primary: false
    property bool focused: false
    property color tone: Color.accent
    signal clicked()
    signal hovered()
    implicitWidth: Math.max(96, bText.implicitWidth + 28)
    implicitHeight: 36
    radius: Math.max(6, Style.cornerRadius)
    opacity: enabled ? 1 : 0.5
    color: primary ? (bMouse.containsMouse ? Qt.lighter(tone, 1.12) : tone)
                   : (bMouse.containsMouse ? Qt.rgba(dialog.fg.r, dialog.fg.g, dialog.fg.b, 0.12) : Qt.rgba(dialog.fg.r, dialog.fg.g, dialog.fg.b, 0.06))
    border.width: focused ? 2 : 0
    border.color: primary ? Qt.lighter(tone, 1.4) : Color.accent
    Behavior on color { ColorAnimation { duration: 90 } }
    Text {
      id: bText
      anchors.centerIn: parent
      text: btn.label
      color: btn.primary ? Color.background : dialog.fg
      font.family: Style.font.family; font.pixelSize: 13; font.bold: btn.primary
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
