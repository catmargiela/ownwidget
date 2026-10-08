import QtQuick
import qs.Commons

Rectangle {
  property string label
  implicitWidth: Math.max(20, keyText.implicitWidth + 10); implicitHeight: 20
  radius: 4
  color: "transparent"
  border.width: 1
  border.color: Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.18)
  Text {
    id: keyText
    anchors.centerIn: parent
    text: parent.label
    color: Color.muted; font.family: Style.font.family; font.pixelSize: 10
  }
}
