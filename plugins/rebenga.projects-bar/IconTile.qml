import QtQuick
import qs.Commons

// Rounded tile holding an app image (assets/…) or a Nerd Font glyph.
Rectangle {
  id: tile
  property string image: ""
  property string glyph: ""
  property color glyphColor: Color.foreground
  property int size: 30
  implicitWidth: size; implicitHeight: size
  radius: Math.max(6, Style.cornerRadius)
  color: Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.07)
  Image {
    visible: tile.image !== ""
    anchors.centerIn: parent
    width: tile.size * 0.6; height: width
    sourceSize.width: 48; sourceSize.height: 48
    source: tile.image ? Qt.resolvedUrl(tile.image) : ""
    smooth: true
    fillMode: Image.PreserveAspectFit
  }
  Text {
    visible: tile.image === ""
    anchors.centerIn: parent
    text: tile.glyph
    color: tile.glyphColor
    font.family: "JetBrainsMono Nerd Font"; font.pixelSize: Math.round(tile.size * 0.53)
  }
}
