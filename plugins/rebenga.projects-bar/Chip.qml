import QtQuick
import qs.Commons

// Selectable pill with an optional Nerd Font glyph.
Rectangle {
  id: c
  property string label
  property string glyph: ""
  property bool selected: false
  signal clicked()
  readonly property color fg: Color.foreground
  implicitHeight: 30
  implicitWidth: cRow.implicitWidth + 20
  radius: Math.max(6, Style.cornerRadius)
  opacity: enabled ? 1 : 0.45
  color: selected ? Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.22)
       : cMouse.containsMouse ? Qt.rgba(fg.r, fg.g, fg.b, 0.1) : Qt.rgba(fg.r, fg.g, fg.b, 0.05)
  border.width: 1
  border.color: selected ? Color.accent : "transparent"
  Behavior on color { ColorAnimation { duration: 90 } }
  Row {
    id: cRow
    anchors.centerIn: parent
    spacing: 6
    Text {
      visible: c.glyph !== ""
      text: c.glyph
      color: c.selected ? Color.accent : Color.muted
      font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 13
      anchors.verticalCenter: parent.verticalCenter
    }
    Text {
      text: c.label
      color: c.fg; font.family: Style.font.family; font.pixelSize: 12
      anchors.verticalCenter: parent.verticalCenter
    }
  }
  MouseArea {
    id: cMouse
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onClicked: if (c.enabled) c.clicked()
  }
}
