import QtQuick
import QtQuick.Layouts
import qs.Commons

// "New project" / "New group" form. All state lives in `ctx` (Bar.qml).
ColumnLayout {
  id: pane
  property var ctx
  property bool showClose: true
  readonly property color fg: Color.foreground
  readonly property bool isGroup: ctx.createKind === "group"
  readonly property bool ghOk: !!ctx.gh && ctx.gh.ok === true
  spacing: 8

  function focusName() { (isGroup ? groupField : nameField).focusInput() }
  Connections {
    target: pane.ctx
    function onCreateKindChanged() { Qt.callLater(pane.focusName) }
  }

  // ---- header ----
  RowLayout {
    Layout.fillWidth: true
    Layout.bottomMargin: 2
    spacing: 10
    IconTile {
      size: 36
      glyph: pane.isGroup ? ctx.gFolderPlus : ctx.gPlus
      glyphColor: Color.accent
      color: Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.18)
    }
    ColumnLayout {
      Layout.fillWidth: true
      spacing: 1
      Text {
        text: pane.isGroup ? "Nouveau groupe" : "Nouveau projet"
        color: pane.fg; font.family: Style.font.family; font.pixelSize: 15; font.bold: true
      }
      Text {
        Layout.fillWidth: true
        text: pane.isGroup ? "~/Documents/" + (ctx.newGroupName || "…")
                           : "~/Documents/" + (ctx.newGroup || "…") + "/" + (ctx.newName || "…")
        color: Color.muted; font.family: Style.font.family; font.pixelSize: 11
        elide: Text.ElideMiddle
      }
    }
    Rectangle {
      visible: pane.showClose
      implicitWidth: 26; implicitHeight: 26; radius: 13
      color: closeMouse.containsMouse ? Qt.rgba(pane.fg.r, pane.fg.g, pane.fg.b, 0.1) : "transparent"
      Text { anchors.centerIn: parent; text: ctx.gClose; color: Color.muted; font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 14 }
      MouseArea { id: closeMouse; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: ctx.closeAll() }
    }
  }

  // ---- Projet | Groupe ----
  RowLayout {
    Layout.fillWidth: true
    spacing: 6
    Chip { Layout.fillWidth: true; glyph: ctx.gPlus; label: "Projet"; selected: !pane.isGroup; onClicked: ctx.createKind = "project" }
    Chip { Layout.fillWidth: true; glyph: ctx.gFolderPlus; label: "Groupe"; selected: pane.isGroup; onClicked: ctx.createKind = "group" }
  }

  // ---- group form ----
  Label { visible: pane.isGroup; text: "Nom du groupe" }
  Field {
    id: groupField
    visible: pane.isGroup
    glyph: ctx.gFolder
    placeholder: "clients"
    value: ctx.newGroupName
    onEdited: v => ctx.newGroupName = v
    onAccepted: ctx.submitCreate()
    onEscaped: ctx.closeAll()
  }

  // ---- project form ----
  Label { visible: !pane.isGroup; text: "Groupe" }
  Flow {
    visible: !pane.isGroup
    Layout.fillWidth: true
    spacing: 6
    Repeater {
      model: ctx.groups
      delegate: Chip {
        required property var modelData
        glyph: ctx.gFolder
        label: modelData.name
        selected: ctx.newGroup === modelData.name
        onClicked: { ctx.newGroup = modelData.name; ctx.pickOwner() }
      }
    }
  }
  Label { visible: !pane.isGroup; text: "Nom" }
  Field {
    id: nameField
    visible: !pane.isGroup
    placeholder: "mon-projet"
    value: ctx.newName
    onEdited: v => ctx.newName = v
    onAccepted: ctx.submitCreate()
    onEscaped: ctx.closeAll()
  }
  Label { visible: !pane.isGroup; text: "Type" }
  RowLayout {
    visible: !pane.isGroup
    Layout.fillWidth: true
    spacing: 6
    Chip { Layout.fillWidth: true; glyph: ctx.gFolder; label: "Dossier"; selected: ctx.newMode === "folder"; onClicked: ctx.newMode = "folder" }
    Chip { Layout.fillWidth: true; glyph: ctx.gGit; label: "Git local"; selected: ctx.newMode === "git"; onClicked: ctx.newMode = "git" }
    Chip { Layout.fillWidth: true; glyph: ctx.gGithub; label: "GitHub"; selected: ctx.newMode === "github"; onClicked: ctx.newMode = "github" }
  }

  // GitHub options, gated on gh auth
  Rectangle {
    visible: !pane.isGroup && ctx.newMode === "github"
    Layout.fillWidth: true
    implicitHeight: ghText.implicitHeight + 14
    radius: Math.max(6, Style.cornerRadius)
    color: ctx.gh && !ctx.gh.ok ? Qt.rgba(Color.urgent.r, Color.urgent.g, Color.urgent.b, 0.12)
                                : Qt.rgba(pane.fg.r, pane.fg.g, pane.fg.b, 0.05)
    Text {
      id: ghText
      anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter; margins: 10 }
      wrapMode: Text.Wrap
      text: ctx.ghLoading ? "Vérification de gh…"
          : !ctx.gh ? "" : ctx.gh.ok ? ctx.gCheck + "  " + ctx.gh.message
          : ctx.gClose + "  " + ctx.gh.message + " — lancez « gh auth login »"
      color: ctx.gh && !ctx.gh.ok ? Color.urgent : Color.muted
      font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 11
    }
  }
  Label { visible: !pane.isGroup && ctx.newMode === "github" && pane.ghOk; text: "Propriétaire" }
  Flow {
    visible: !pane.isGroup && ctx.newMode === "github" && pane.ghOk
    Layout.fillWidth: true
    spacing: 6
    Repeater {
      model: pane.ghOk ? ctx.gh.owners : []
      delegate: Chip {
        required property var modelData
        label: modelData
        selected: ctx.newOwner === modelData
        onClicked: ctx.newOwner = modelData
      }
    }
  }
  RowLayout {
    visible: !pane.isGroup && ctx.newMode === "github" && pane.ghOk
    Layout.fillWidth: true
    spacing: 6
    Chip { Layout.fillWidth: true; label: "Privé"; selected: ctx.newVisibility === "private"; onClicked: ctx.newVisibility = "private" }
    Chip { Layout.fillWidth: true; label: "Public"; selected: ctx.newVisibility === "public"; onClicked: ctx.newVisibility = "public" }
  }

  Text {
    Layout.fillWidth: true
    visible: ctx.createMessage !== ""
    wrapMode: Text.Wrap
    text: ctx.createMessage
    color: ctx.createOk || ctx.creating ? Color.muted : Color.urgent
    font.family: Style.font.family; font.pixelSize: 11
  }

  // ---- primary button ----
  Rectangle {
    id: createBtn
    readonly property bool ready: ctx.canCreate
    Layout.fillWidth: true
    Layout.topMargin: 4
    implicitHeight: 38
    radius: Math.max(6, Style.cornerRadius)
    color: ready ? (createMouse.containsMouse ? Qt.lighter(Color.accent, 1.15) : Color.accent)
                 : Qt.rgba(pane.fg.r, pane.fg.g, pane.fg.b, 0.08)
    Behavior on color { ColorAnimation { duration: 90 } }
    Text {
      anchors.centerIn: parent
      text: ctx.creating ? "Création…" : (pane.isGroup ? "Créer le groupe  ↵" : "Créer le projet  ↵")
      color: createBtn.ready ? Color.background : Color.muted
      font.family: Style.font.family; font.pixelSize: 13; font.bold: true
    }
    MouseArea {
      id: createMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: createBtn.ready ? Qt.PointingHandCursor : Qt.ArrowCursor
      onClicked: ctx.submitCreate()
    }
  }

  component Label: Text {
    color: Color.muted
    font.family: Style.font.family; font.pixelSize: 10; font.bold: true; font.letterSpacing: 1
    font.capitalization: Font.AllUppercase
    Layout.topMargin: 2
  }
}
