import QtQuick
import QtQuick.Layouts
import qs.Commons

// Centre modal: search every project/group on the left, actions (or the create form) on the right.
// ↑/↓ move, Enter opens the highlighted project in VS Code, Esc closes.
Rectangle {
  id: picker
  property var ctx
  property string query: ""
  property int highlighted: 0
  readonly property color fg: Color.foreground

  width: 820
  height: 520
  radius: Math.max(10, Style.cornerRadius + 4)
  color: Qt.rgba(Color.background.r, Color.background.g, Color.background.b, 0.98)
  border.width: 1
  border.color: Qt.rgba(fg.r, fg.g, fg.b, 0.14)

  function focusSearch() { search.input.forceActiveFocus() }

  function reset() {
    query = ""
    highlighted = firstSelectable(0, 1)
    search.focusInput()
    syncTarget()
  }

  // Rows: group headers + projects (grouped) when idle; ranked flat matches while searching.
  readonly property var rows: {
    var out = []
    var q = query.trim().toLowerCase()
    var groups = ctx.groups || []
    if (!q) {
      for (var i = 0; i < groups.length; i++) {
        out.push({ kind: "group", item: groups[i] })
        for (var j = 0; j < groups[i].projects.length; j++) out.push({ kind: "project", item: groups[i].projects[j] })
      }
      return out
    }
    var scored = []
    for (var a = 0; a < groups.length; a++) {
      var gs = score(groups[a].name, q)
      if (gs > 0) scored.push({ s: gs - 1, row: { kind: "group", item: groups[a] } })
      for (var b = 0; b < groups[a].projects.length; b++) {
        var p = groups[a].projects[b]
        var ps = Math.max(score(p.name, q), score(groups[a].name + "/" + p.name, q) - 1)
        if (ps > 0) scored.push({ s: ps, row: { kind: "project", item: p } })
      }
    }
    scored.sort(function(x, y) { return y.s - x.s })
    for (var k = 0; k < scored.length; k++) out.push(scored[k].row)
    return out
  }

  // prefix > substring > in-order letters; 0 = no match
  function score(text, q) {
    var t = text.toLowerCase()
    if (t.indexOf(q) === 0) return 100 - t.length * 0.01
    var at = t.indexOf(q)
    if (at > 0) return 60 - at
    var ti = 0
    for (var qi = 0; qi < q.length; qi++) {
      ti = t.indexOf(q[qi], ti)
      if (ti < 0) return 0
      ti++
    }
    return 20
  }

  function firstSelectable(from, dir) {
    var r = rows
    if (!r.length) return -1
    for (var i = from; i >= 0 && i < r.length; i += dir) if (!(query === "" && r[i].kind === "group")) return i
    return Math.max(0, Math.min(from, r.length - 1))
  }

  function move(dir) {
    var r = rows
    if (!r.length) return
    var i = highlighted
    do { i = (i + dir + r.length) % r.length } while (query === "" && r[i].kind === "group" && i !== highlighted)
    highlighted = i
    list.positionViewAtIndex(i, ListView.Contain)
    syncTarget()
  }

  function syncTarget() {
    var r = rows[highlighted]
    if (r && ctx.pane !== "create") ctx.setTarget(r.kind, r.item)
  }

  onQueryChanged: { highlighted = firstSelectable(0, 1); syncTarget() }

  // Swallow clicks so the dim backdrop doesn't close the modal.
  MouseArea { anchors.fill: parent; onPressed: mouse => mouse.accepted = true }

  ColumnLayout {
    anchors { fill: parent; margins: 16 }
    spacing: 12

    // ---- search ----
    Field {
      id: search
      Layout.fillWidth: true
      implicitHeight: 42
      glyph: picker.ctx.gSearch
      placeholder: "Rechercher un projet ou un groupe…"
      value: picker.query
      onEdited: v => picker.query = v
      onEscaped: picker.ctx.closeAll()
      onAccepted: {
        var r = picker.rows[picker.highlighted]
        if (r && r.kind === "project") picker.ctx.run(picker.ctx.actionsFor({ kind: "project", item: r.item })[0])
      }
      onNavigate: dir => picker.move(dir)
    }

    RowLayout {
      Layout.fillWidth: true
      Layout.fillHeight: true
      spacing: 14

      // ---- list ----
      ListView {
        id: list
        Layout.preferredWidth: 330
        Layout.fillHeight: true
        clip: true
        model: picker.rows
        spacing: 2
        boundsBehavior: Flickable.StopAtBounds
        delegate: Rectangle {
          id: row
          required property var modelData
          required property int index
          readonly property bool isGroup: modelData.kind === "group"
          readonly property bool isHi: index === picker.highlighted
          width: list.width
          height: isGroup && picker.query === "" ? 30 : 40
          radius: Math.max(6, Style.cornerRadius)
          color: isHi ? Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.2)
               : rowMouse.containsMouse ? Qt.rgba(picker.fg.r, picker.fg.g, picker.fg.b, 0.06) : "transparent"
          Behavior on color { ColorAnimation { duration: 80 } }

          RowLayout {
            anchors { fill: parent; leftMargin: 10; rightMargin: 10 }
            spacing: 10
            Text {
              text: row.isGroup ? picker.ctx.gFolder : (row.modelData.item.git ? picker.ctx.gGit : picker.ctx.gFolderOutline)
              color: row.isGroup ? Color.muted : (row.isHi ? Color.accent : picker.fg)
              font.family: "JetBrainsMono Nerd Font"; font.pixelSize: row.isGroup ? 12 : 15
            }
            Text {
              Layout.fillWidth: true
              text: row.isGroup ? row.modelData.item.name.toUpperCase() : row.modelData.item.name
              color: row.isGroup ? Color.muted : picker.fg
              font.family: Style.font.family
              font.pixelSize: row.isGroup ? 10 : 13
              font.bold: row.isGroup
              font.letterSpacing: row.isGroup ? 1.2 : 0
              elide: Text.ElideRight
            }
            Text {
              visible: !row.isGroup && picker.query !== ""
              text: row.isGroup ? "" : row.modelData.item.group
              color: Color.muted; font.family: Style.font.family; font.pixelSize: 10
            }
            Text {
              visible: !row.isGroup && !!row.modelData.item.git && row.modelData.item.git.branch !== "main" && row.modelData.item.git.branch !== "master"
              text: row.isGroup || !row.modelData.item.git ? "" : picker.ctx.gBranch + " " + row.modelData.item.git.branch
              color: Color.muted; font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 10
              Layout.maximumWidth: 120
              elide: Text.ElideRight
            }
          }
          MouseArea {
            id: rowMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: {
              picker.highlighted = row.index
              picker.ctx.pane = "actions"
              picker.ctx.setTarget(row.modelData.kind, row.modelData.item)
            }
          }
        }

        Text {
          anchors.centerIn: parent
          visible: picker.rows.length === 0
          text: "Aucun résultat"
          color: Color.muted; font.family: Style.font.family; font.pixelSize: 12
        }
      }

      Rectangle { Layout.fillHeight: true; width: 1; color: Qt.rgba(picker.fg.r, picker.fg.g, picker.fg.b, 0.1) }

      // ---- right pane ----
      Flickable {
        Layout.fillWidth: true
        Layout.fillHeight: true
        contentHeight: rightCol.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        ColumnLayout {
          id: rightCol
          width: parent.width
          ActionsPane {
            visible: picker.ctx.pane !== "create" && !!picker.ctx.target
            Layout.fillWidth: true
            ctx: picker.ctx
            showKeys: false
          }
          CreatePane {
            visible: picker.ctx.pane === "create"
            Layout.fillWidth: true
            ctx: picker.ctx
            showClose: false
          }
        }
      }
    }

    // ---- footer ----
    RowLayout {
      Layout.fillWidth: true
      spacing: 8
      Chip { glyph: picker.ctx.gPlus; label: "Nouveau projet"; selected: picker.ctx.pane === "create" && picker.ctx.createKind === "project"; onClicked: picker.ctx.openCreate("", "project") }
      Chip { glyph: picker.ctx.gFolderPlus; label: "Nouveau groupe"; selected: picker.ctx.pane === "create" && picker.ctx.createKind === "group"; onClicked: picker.ctx.openCreate("", "group") }
      Item { Layout.fillWidth: true }
      Text {
        text: "↑↓ naviguer   ↵ VS Code   Échap fermer"
        color: Color.muted; font.family: Style.font.family; font.pixelSize: 10
      }
    }
  }
}
