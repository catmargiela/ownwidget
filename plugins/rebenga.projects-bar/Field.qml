import QtQuick
import QtQuick.Layouts
import qs.Commons

// Single-line text input with placeholder and optional leading glyph.
Rectangle {
  id: f
  property string placeholder
  property string value
  property string glyph: ""
  property alias input: input
  signal edited(string v)
  signal accepted()
  signal escaped()
  signal navigate(int dir)
  function focusInput() { input.forceActiveFocus(); input.selectAll() }
  Layout.fillWidth: true
  implicitHeight: 34
  radius: Math.max(6, Style.cornerRadius)
  color: Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.06)
  border.width: 1
  border.color: input.activeFocus ? Color.accent : "transparent"
  Text {
    id: lead
    visible: f.glyph !== ""
    anchors { left: parent.left; leftMargin: 10; verticalCenter: parent.verticalCenter }
    text: f.glyph
    color: Color.muted; font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 14
  }
  TextInput {
    id: input
    anchors { fill: parent; leftMargin: f.glyph ? 32 : 10; rightMargin: 10 }
    verticalAlignment: TextInput.AlignVCenter
    text: f.value
    color: Color.foreground; font.family: Style.font.family; font.pixelSize: 13
    selectByMouse: true
    selectionColor: Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.4)
    clip: true
    onTextEdited: f.edited(text)
    onAccepted: f.accepted()
    Keys.onEscapePressed: f.escaped()
    Keys.onUpPressed: f.navigate(-1)
    Keys.onDownPressed: f.navigate(1)
    Keys.onTabPressed: f.navigate(1)
    Keys.onBacktabPressed: f.navigate(-1)
    Text {
      visible: !input.text
      text: f.placeholder
      color: Color.muted; font: input.font
      anchors.verticalCenter: parent.verticalCenter
    }
  }
  MouseArea { anchors.fill: parent; cursorShape: Qt.IBeamCursor; onPressed: mouse => { input.forceActiveFocus(); mouse.accepted = false } }
}
