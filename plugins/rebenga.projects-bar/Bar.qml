import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland
import QtQuick
import QtQuick.Layouts
import qs.Commons

// Projects bar (bottom of the desktop) + centre picker + confetti.
//  - The bar shows the most recently opened projects (bar, Claude Code, VS Code), live-updated
//    by `projects.py watch` (stat polling every 2 s, emits only on change).
//  - Click a project → actions, with a branch picker (other branches open in a git worktree).
//  - "Tous" / SUPER+ALT+P (`omarchy-shell projects picker`) opens the searchable centre modal.
//  - Creating a group or project ends in confetti.
// Outside clicks close menus via a transparent full-screen catcher on the Top layer.
Item {
  id: root

  readonly property string script: Qt.resolvedUrl("projects.py").toString().replace("file://", "")

  // ---- data ----
  property var groups: []
  property var recent: []

  // ---- UI state ----
  property string surface: "bar"        // where the pane is shown: "bar" popup or "picker" modal
  property string pane: ""              // "" | "actions" | "create"
  property var target: null             // { kind: "project"|"group", item }
  property real targetX: -1             // bar popup anchor (x inside the bar)
  property bool raised: false
  property bool pickerOpen: false
  property var branchInfo: null         // `projects.py branches` for target
  property var branchSel: ({ name: "", isNew: false })
  property string busyMessage: ""
  property bool busyError: false
  property bool confettiActive: false
  property var alert: null              // confirmation dialog, see askDelete()

  // ---- create form ----
  property string createKind: "project" // "project" | "group"
  property string newGroup: ""
  property string newGroupName: ""
  property string newName: ""
  property string newMode: "git"
  property string newOwner: ""
  property string newVisibility: "private"
  property var gh: null
  property bool ghLoading: false
  property bool creating: false
  property string createMessage: ""
  property bool createOk: false
  readonly property bool canCreate: !creating && (createKind === "group"
      ? newGroupName.trim() !== ""
      : newName.trim() !== "" && newGroup.trim() !== "" && (newMode !== "github" || (!!gh && gh.ok === true)))

  readonly property bool barInteractive: raised || (surface === "bar" && pane !== "")
  readonly property bool barHasKeyboard: barInteractive && !pickerOpen && !alert

  // ---- glyphs (JetBrainsMono Nerd Font) ----
  readonly property string gTerminal: "\u{F018D}"
  readonly property string gGithub: "\u{F02A4}"
  readonly property string gCopy: "\u{F018F}"
  readonly property string gFolder: "\u{F024B}"
  readonly property string gFolderOutline: "\u{F0770}"
  readonly property string gFolderPlus: "\u{F0257}"
  readonly property string gPlus: "\u{F0415}"
  readonly property string gBranch: "\u{F062C}"
  readonly property string gBranchPlus: "\u{F0BCC}"
  readonly property string gGit: "\u{F02A2}"
  readonly property string gClose: "\u{F0156}"
  readonly property string gCheck: "\u{F012C}"
  readonly property string gSearch: "\u{F0349}"
  readonly property string gGrid: "\u{F0570}"
  readonly property string gChevron: "\u{F0140}"
  readonly property string gCloud: "\u{F015F}"
  readonly property string gTrash: "\u{F0A7A}"
  readonly property string gAlert: "\u{F002A}"

  function tint(c, a) { return Qt.rgba(c.r, c.g, c.b, a) }
  function prettyPath(p) { return String(p || "").replace(Quickshell.env("HOME"), "~") }

  // ---------- targets & branches ----------

  function setTarget(kind, item) {
    if (target && target.kind === kind && target.item.path === item.path) return
    target = { kind: kind, item: item }
    branchSel = { name: "", isNew: false }
    branchInfo = null
    busyMessage = ""
    if (kind === "project" && item.git) {
      branchProc.running = false
      branchProc.command = ["python3", "-I", script, "branches", item.path]
      branchProc.running = true
    }
  }

  function selectBranch(name, isNew) {
    branchSel = { name: (branchInfo && name === branchInfo.current && !isNew) ? "" : name, isNew: !!isNew }
  }

  function showActions(kind, item, x) {
    surface = "bar"
    setTarget(kind, item)
    targetX = x
    pane = "actions"
  }

  // ---------- actions ----------

  function actionsFor(t) {
    if (!t) return []
    var it = t.item
    if (t.kind === "group") return [
      { label: "VS Code", hint: it.workspace ? "Workspace du groupe" : "Ouvrir le dossier", key: "v", image: "assets/vscode.png", args: ["code", it.workspace || it.path] },
      { label: "Terminal", hint: "Shell dans le groupe", key: "t", glyph: gTerminal, args: ["xdg-terminal-exec", "--dir=" + it.path] },
      { label: "Fichiers", hint: "Nautilus", key: "f", image: "assets/files.svg", args: ["nautilus", it.path] },
      { label: "Nouveau projet ici", hint: it.name, key: "n", glyph: gPlus, create: it.name },
      { label: "Mettre le groupe à la corbeille", hint: "Avec tous ses projets · restaurable", key: "d", glyph: gTrash, danger: true, del: true }
    ]
    var where = branchSel.name ? "branche " + branchSel.name : ""
    var list = [
      { label: "VS Code", hint: where || "Ouvrir le projet", key: "v", image: "assets/vscode.png", open: "code" },
      { label: "Claude", hint: where || "Session Claude Code", key: "c", image: "assets/claude.svg", open: "claude" },
      { label: "Terminal", hint: where || "Shell dans le dossier", key: "t", glyph: gTerminal, open: "terminal" },
      { label: "Fichiers", hint: where || "Nautilus", key: "f", image: "assets/files.svg", open: "files" }
    ]
    if (it.git && it.git.webUrl)
      list.push({ label: "GitHub", hint: it.git.webUrl.replace("https://github.com/", ""), key: "g", glyph: gGithub, args: ["xdg-open", it.git.webUrl] })
    list.push({ label: "Copier le chemin", hint: prettyPath(it.path), key: "y", glyph: gCopy, args: ["wl-copy", it.path] })
    list.push({ label: "Mettre à la corbeille", hint: "Restaurable depuis la notification", key: "d", glyph: gTrash, danger: true, del: true })
    return list
  }

  function run(a) {
    if (!a) return
    if (a.create !== undefined) { openCreate(a.create, "project"); return }
    if (a.del) { askDelete(target); return }
    if (a.open) { openIn(target.item, a.open); return }
    Quickshell.execDetached(a.args)
    closeAll()
  }

  // Resolve the directory (worktree for another branch) then launch.
  property string pendingOpen: ""
  function openIn(item, kind) {
    pendingOpen = kind
    busyError = false
    busyMessage = branchSel.name ? "Préparation de la branche " + branchSel.name + "…" : ""
    prepareProc.command = ["python3", "-I", script, "prepare", item.path, branchSel.name, branchSel.isNew ? "new" : ""]
    prepareProc.running = true
  }

  function launch(kind, dir) {
    var args = kind === "code" ? ["code", dir]
             : kind === "claude" ? ["xdg-terminal-exec", "--dir=" + dir, "claude"]
             : kind === "terminal" ? ["xdg-terminal-exec", "--dir=" + dir]
             : ["nautilus", dir]
    Quickshell.execDetached(args)
  }

  function handleKey(event) {
    if (event.key === Qt.Key_Escape) { closeAll(); event.accepted = true; return }
    if (pane !== "actions" || !target) return
    var k = event.key === Qt.Key_Delete ? "d" : String(event.text || "").toLowerCase()
    var acts = actionsFor(target)
    for (var i = 0; i < acts.length; i++)
      if (acts[i].key === k) { run(acts[i]); event.accepted = true; return }
  }

  // ---------- delete (to the trash) with a confirmation alert ----------

  function askDelete(t) {
    if (!t) return
    var group = t.kind === "group"
    alert = {
      path: t.item.path,
      title: "Mettre « " + t.item.name + " » à la corbeille ?",
      message: group ? "Le groupe et tous ses projets seront déplacés dans la corbeille. Vous pourrez les restaurer."
                     : "Le projet sera déplacé dans la corbeille. Vous pourrez le restaurer.",
      details: [], risks: [], error: "",
      confirmLabel: "Mettre à la corbeille",
      danger: true, loading: true, busy: false
    }
    inspectProc.command = ["python3", "-I", script, "inspect", t.item.path]
    inspectProc.running = true
  }

  function patchAlert(fields) {
    if (!alert) return
    var next = {}
    for (var k in alert) next[k] = alert[k]
    for (var f in fields) next[f] = fields[f]
    alert = next
  }

  function confirmAlert() {
    if (!alert || alert.loading || alert.busy) return
    patchAlert({ busy: true, error: "" })
    trashProc.command = ["python3", "-I", script, "trash", alert.path]
    trashProc.running = true
  }

  function cancelAlert() { alert = null }

  // Ask the watcher to rescan now instead of on its next 2 s tick.
  function nudge() { if (watchProc.running) watchProc.write("\n") }

  // Drop a trashed group/project from the UI immediately; the watcher confirms right after.
  function forget(path) {
    var prefix = path + "/"
    var next = []
    for (var i = 0; i < groups.length; i++) {
      var g = groups[i]
      if (g.path === path) continue
      var copy = {}
      for (var k in g) copy[k] = g[k]
      copy.projects = g.projects.filter(function(p) { return p.path !== path && p.path.indexOf(prefix) !== 0 })
      next.push(copy)
    }
    groups = next
    recent = recent.filter(function(p) { return p.path !== path && p.path.indexOf(prefix) !== 0 })
  }

  // Notification with a "Restaurer" button that undoes the trash.
  function notifyTrashed(name, path) {
    var sh = 'a=$(notify-send -a Projets -A undo=Restaurer "$1" "Mis à la corbeille"); '
           + '[ "$a" = undo ] && r=$(python3 -I "$3" restore "$2") && { omarchy-shell -q projects refresh; notify-send -a Projets "$1" "$(printf %s "$r" | jq -r .message)"; }'
    Quickshell.execDetached(["sh", "-c", sh, "projects-trash", name, path, script])
  }

  function closeAll() {
    alert = null
    pane = ""
    target = null
    raised = false
    pickerOpen = false
    busyMessage = ""
  }

  function openPicker() {
    pane = "actions"
    target = null
    surface = "picker"
    pickerOpen = true
  }

  // ---------- create ----------

  function openCreate(group, kind) {
    createKind = kind || "project"
    newGroup = group || (groups.length ? groups[0].name : "")
    newName = ""
    newGroupName = ""
    createMessage = ""
    createOk = false
    pane = "create"
    if (!gh && !ghLoading) { ghLoading = true; ghProc.running = true }
    pickOwner()
  }

  // Default GitHub owner: an org whose name contains the group name (acme → acme-studio), else the user.
  function pickOwner() {
    if (!gh || !gh.ok) return
    newOwner = gh.user
    var g = newGroup.toLowerCase()
    for (var i = 1; i < gh.owners.length && g.length > 2; i++)
      if (gh.owners[i].toLowerCase().indexOf(g) >= 0) { newOwner = gh.owners[i]; break }
  }

  function submitCreate() {
    if (!canCreate) return
    creating = true
    createMessage = "Création…"
    createProc.command = createKind === "group"
      ? ["python3", "-I", script, "create-group", newGroupName.trim()]
      : ["python3", "-I", script, "create", newGroup.trim(), newName.trim(), newMode,
         newMode === "github" ? newOwner : "", newVisibility]
    createProc.running = true
  }

  function celebrate() {
    confettiActive = false
    confettiActive = true
    confettiTimer.restart()
  }

  // ---------- processes ----------

  // Live data: emits one JSON line per change.
  Process {
    id: watchProc
    running: true
    stdinEnabled: true
    command: ["python3", "-I", root.script, "watch"]
    stdout: SplitParser {
      onRead: line => {
        try {
          var data = JSON.parse(line)
          var byPath = {}
          for (var i = 0; i < data.groups.length; i++)
            for (var j = 0; j < data.groups[i].projects.length; j++)
              byPath[data.groups[i].projects[j].path] = data.groups[i].projects[j]
          root.groups = data.groups
          root.recent = data.recent.map(function(p) { return byPath[p] }).filter(function(p) { return !!p })
        } catch (e) {}
      }
    }
    onExited: watchRestart.start()
  }
  Timer { id: watchRestart; interval: 5000; onTriggered: watchProc.running = true }

  Process {
    id: branchProc
    stdout: StdioCollector {
      onStreamFinished: {
        try {
          var info = JSON.parse(text)
          var path = branchProc.command[branchProc.command.length - 1]
          if (root.target && root.target.item.path === path) root.branchInfo = info
        } catch (e) {}
      }
    }
  }

  Process {
    id: prepareProc
    stdout: StdioCollector {
      onStreamFinished: {
        var r
        try { r = JSON.parse(text) } catch (e) { r = { ok: false, message: "Erreur inattendue" } }
        if (r.ok) {
          root.launch(root.pendingOpen, r.dir)
          root.closeAll()
        } else {
          root.busyError = true
          root.busyMessage = r.message || "Échec"
        }
      }
    }
  }

  Process {
    id: ghProc
    command: ["python3", "-I", root.script, "gh"]
    stdout: StdioCollector {
      onStreamFinished: {
        try { root.gh = JSON.parse(text) } catch (e) { root.gh = { ok: false, message: "gh indisponible" } }
        root.ghLoading = false
        root.pickOwner()
      }
    }
  }

  Process {
    id: createProc
    stdout: StdioCollector {
      onStreamFinished: {
        root.creating = false
        var r
        try { r = JSON.parse(text) } catch (e) { r = { ok: false, message: "Erreur inattendue" } }
        root.createOk = !!r.ok
        root.createMessage = r.message || ""
        if (!r.ok) return
        root.nudge()
        root.celebrate()
        if (root.createKind === "group") {
          root.newGroup = root.newGroupName.trim()
          root.createKind = "project"          // chain straight into "new project in this group"
          root.newName = ""
          root.createMessage = r.message
          return
        }
        root.pane = "actions"
        root.target = null
        root.setTarget("project", { name: root.newName.trim(), path: r.path, group: root.newGroup,
                                    git: root.newMode === "folder" ? null : { webUrl: r.webUrl || "", branch: "" } })
      }
    }
  }

  Process {
    id: inspectProc
    stdout: StdioCollector {
      onStreamFinished: {
        var r
        try { r = JSON.parse(text) } catch (e) { r = { ok: false, message: "Erreur inattendue" } }
        if (!root.alert || (r.path && r.path !== root.alert.path && r.ok)) return
        if (!r.ok) { root.patchAlert({ loading: false, busy: true, error: r.message }); return }
        root.patchAlert({ loading: false, risks: r.risks || [],
                          details: r.projects ? (r.projects.length ? r.projects : ["Groupe vide"]) : [] })
      }
    }
  }

  Process {
    id: trashProc
    stdout: StdioCollector {
      onStreamFinished: {
        var r
        try { r = JSON.parse(text) } catch (e) { r = { ok: false, message: "Erreur inattendue" } }
        if (!r.ok) { root.patchAlert({ busy: false, error: r.message }); return }
        root.forget(r.path)
        root.nudge()
        root.notifyTrashed(r.name, r.path)
        root.alert = null
        if (root.pickerOpen) { root.target = null; root.pane = "actions" }
        else root.closeAll()
      }
    }
  }

  Timer { id: confettiTimer; interval: 3600; onTriggered: root.confettiActive = false }

  IpcHandler {
    target: "projects"
    function toggle(): void { if (root.barInteractive) root.closeAll(); else root.raised = true }
    function picker(): void { if (root.pickerOpen) root.closeAll(); else root.openPicker() }
    function confetti(): void { root.celebrate() }
    // Open the delete confirmation for a project or group path (nothing is deleted without confirming).
    function trash(path: string): void {
      for (var i = 0; i < root.groups.length; i++) {
        var g = root.groups[i]
        if (g.path === path) { root.askDelete({ kind: "group", item: g }); return }
        for (var j = 0; j < g.projects.length; j++)
          if (g.projects[j].path === path) { root.askDelete({ kind: "project", item: g.projects[j] }); return }
      }
    }
    function cancel(): void { root.closeAll() }
    function refresh(): void { root.nudge() }
  }

  // ---------- windows ----------

  // Outside-click catcher for the bar popup: above normal windows, below the bar (Overlay).
  Variants {
    model: Quickshell.screens
    PanelWindow {
      required property var modelData
      screen: modelData
      visible: root.barInteractive && !root.pickerOpen && !root.alert
      anchors { top: true; bottom: true; left: true; right: true }
      color: "transparent"
      exclusionMode: ExclusionMode.Ignore
      WlrLayershell.namespace: "rebenga-projects-catcher"
      WlrLayershell.layer: WlrLayer.Top
      WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
      MouseArea { anchors.fill: parent; acceptedButtons: Qt.AllButtons; onPressed: root.closeAll() }
    }
  }

  // The bar + its popup.
  Variants {
    model: Quickshell.screens

    PanelWindow {
      id: win
      required property var modelData
      screen: modelData
      anchors { bottom: true; left: true; right: true }
      margins { bottom: 14 }
      implicitHeight: 640
      color: "transparent"
      exclusionMode: ExclusionMode.Ignore
      WlrLayershell.namespace: "rebenga-projects-bar"
      WlrLayershell.layer: root.barInteractive ? WlrLayer.Overlay : WlrLayer.Bottom
      WlrLayershell.keyboardFocus: root.barHasKeyboard ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

      // Only the bar and the open popup take input; the rest of the strip is click-through.
      mask: Region {
        item: barBg
        Region { item: popupHolder }
      }

      Item {
        anchors.fill: parent
        focus: true
        Keys.onPressed: event => root.handleKey(event)

        // ---------- popup ----------
        Item {
          id: popupHolder
          readonly property bool open: root.surface === "bar" && root.pane !== "" && !root.pickerOpen
                                       && (root.pane === "create" || !!root.target)
          width: open ? popup.width : 0
          height: open ? popup.height : 0
          x: {
            var want = root.pane === "create" ? barBg.x + barBg.width - popup.width
                     : (root.targetX >= 0 ? barBg.x + root.targetX - 6 : barBg.x + barBg.width / 2 - popup.width / 2)
            return Math.max(8, Math.min(parent.width - popup.width - 8, want))
          }
          y: barBg.y - popup.height - 10

          onOpenChanged: if (open) popIn.restart()
          Connections { target: root; function onTargetChanged() { if (popupHolder.open) popIn.restart() } }

          Rectangle {
            id: popup
            visible: popupHolder.open
            width: root.pane === "create" ? 410 : 320
            height: (root.pane === "create" ? createPane.implicitHeight : actionsPane.implicitHeight) + 28
            radius: Math.max(10, Style.cornerRadius + 2)
            color: root.tint(Color.background, 0.97)
            border.width: 1
            border.color: root.tint(Color.foreground, 0.14)
            transform: Translate { id: slide }

            ParallelAnimation {
              id: popIn
              NumberAnimation { target: popup; property: "opacity"; from: 0; to: 1; duration: 140; easing.type: Easing.OutCubic }
              NumberAnimation { target: slide; property: "y"; from: 10; to: 0; duration: 190; easing.type: Easing.OutCubic }
            }

            ActionsPane {
              id: actionsPane
              visible: root.pane === "actions"
              anchors { left: parent.left; right: parent.right; top: parent.top; margins: 14 }
              ctx: root
            }
            CreatePane {
              id: createPane
              visible: root.pane === "create"
              anchors { left: parent.left; right: parent.right; top: parent.top; margins: 14 }
              ctx: root
            }
          }
          Connections {
            target: root
            function onPaneChanged() { if (root.pane === "create" && popupHolder.open) Qt.callLater(createPane.focusName) }
          }
        }

        // ---------- bar ----------
        Rectangle {
          id: barBg
          anchors.bottom: parent.bottom
          anchors.horizontalCenter: parent.horizontalCenter
          width: Math.min(parent.width - 32, barRow.implicitWidth + 16)
          height: 46
          radius: Math.max(10, Style.cornerRadius + 2)
          color: root.tint(Color.background, root.barInteractive ? 0.97 : 0.85)
          border.width: 1
          border.color: root.tint(Color.foreground, root.barInteractive ? 0.22 : 0.12)
          Behavior on color { ColorAnimation { duration: 150 } }
          Behavior on width { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }

          Flickable {
            id: flick
            anchors { fill: parent; leftMargin: 8; rightMargin: 8 }
            contentWidth: barRow.implicitWidth
            contentHeight: height
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            flickableDirection: Flickable.HorizontalFlick
            WheelHandler {
              onWheel: event => flick.contentX = Math.max(0, Math.min(flick.contentWidth - flick.width,
                                                  flick.contentX - event.angleDelta.y - event.angleDelta.x))
            }

            Row {
              id: barRow
              height: parent.height
              spacing: 2

              Repeater {
                model: root.recent
                delegate: BarChip {
                  required property var modelData
                  text: modelData.name
                  sub: modelData.group
                  branch: modelData.git ? modelData.git.branch : ""
                  linked: !!(modelData.git && modelData.git.webUrl)
                  active: root.surface === "bar" && root.pane === "actions" && !!root.target && root.target.item.path === modelData.path
                  onClicked: chip => root.showActions("project", modelData, chip.mapToItem(barBg, 0, 0).x)
                }
              }

              Rectangle { width: 1; height: 22; anchors.verticalCenter: parent.verticalCenter; color: root.tint(Color.foreground, 0.12) }
              BarChip {
                glyph: root.gGrid
                text: "Tous"
                textColor: Color.muted
                onClicked: root.openPicker()
              }
            }
          }
        }
      }
    }
  }

  // Centre picker on the focused monitor.
  Variants {
    model: Quickshell.screens
    PanelWindow {
      id: pickerWin
      required property var modelData
      screen: modelData
      visible: root.pickerOpen && (!Hyprland.focusedMonitor || Hyprland.focusedMonitor.name === modelData.name)
      anchors { top: true; bottom: true; left: true; right: true }
      color: "transparent"
      exclusionMode: ExclusionMode.Ignore
      WlrLayershell.namespace: "rebenga-projects-picker"
      WlrLayershell.layer: WlrLayer.Overlay
      WlrLayershell.keyboardFocus: visible ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

      onVisibleChanged: if (visible) { Qt.callLater(picker.reset); pickerIn.restart() }

      Rectangle {
        id: dim
        anchors.fill: parent
        color: Qt.rgba(0, 0, 0, 0.45)
        opacity: 0
        MouseArea { anchors.fill: parent; onPressed: root.closeAll() }
      }

      Picker {
        id: picker
        ctx: root
        anchors.centerIn: parent
        opacity: 0
        scale: 0.97
      }

      // Alert on top of the picker (same surface, so keyboard focus stays here).
      Rectangle {
        anchors.fill: parent
        visible: !!root.alert
        color: Qt.rgba(0, 0, 0, 0.35)
        MouseArea { anchors.fill: parent; onPressed: root.cancelAlert() }
        onVisibleChanged: if (visible) pickerAlert.open(); else picker.focusSearch()
        AlertDialog { id: pickerAlert; ctx: root; anchors.centerIn: parent }
      }

      ParallelAnimation {
        id: pickerIn
        NumberAnimation { target: dim; property: "opacity"; from: 0; to: 1; duration: 160 }
        NumberAnimation { target: picker; property: "opacity"; from: 0; to: 1; duration: 160; easing.type: Easing.OutCubic }
        NumberAnimation { target: picker; property: "scale"; from: 0.96; to: 1; duration: 200; easing.type: Easing.OutCubic }
      }
    }
  }

  // Alert window used from the bar (the picker shows its own copy).
  Variants {
    model: Quickshell.screens
    PanelWindow {
      required property var modelData
      screen: modelData
      visible: !!root.alert && !root.pickerOpen && (!Hyprland.focusedMonitor || Hyprland.focusedMonitor.name === modelData.name)
      anchors { top: true; bottom: true; left: true; right: true }
      color: "transparent"
      exclusionMode: ExclusionMode.Ignore
      WlrLayershell.namespace: "rebenga-projects-alert"
      WlrLayershell.layer: WlrLayer.Overlay
      WlrLayershell.keyboardFocus: visible ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
      onVisibleChanged: if (visible) Qt.callLater(barAlert.open)
      Rectangle {
        anchors.fill: parent
        color: Qt.rgba(0, 0, 0, 0.45)
        MouseArea { anchors.fill: parent; onPressed: root.cancelAlert() }
      }
      AlertDialog { id: barAlert; ctx: root; anchors.centerIn: parent }
    }
  }

  // Confetti overlay: click-through, only mapped while it plays.
  Variants {
    model: Quickshell.screens
    PanelWindow {
      required property var modelData
      screen: modelData
      visible: root.confettiActive
      anchors { top: true; bottom: true; left: true; right: true }
      color: "transparent"
      exclusionMode: ExclusionMode.Ignore
      WlrLayershell.namespace: "rebenga-projects-confetti"
      WlrLayershell.layer: WlrLayer.Overlay
      WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
      mask: Region {}
      onVisibleChanged: if (visible) Qt.callLater(confetti.burst)
      Confetti { id: confetti; anchors.fill: parent }
    }
  }

  // ---------- bar chip ----------
  component BarChip: Rectangle {
    id: chip
    property string text
    property string glyph: ""
    property string sub: ""
    property string branch: ""
    property bool linked: false
    property bool active: false
    property color textColor: Color.foreground
    signal clicked(var chip)
    anchors.verticalCenter: parent ? parent.verticalCenter : undefined
    height: 34
    width: chipRow.implicitWidth + 22
    radius: Math.max(8, Style.cornerRadius)
    color: active ? root.tint(Color.accent, 0.22) : chipMouse.containsMouse ? root.tint(Color.foreground, 0.08) : "transparent"
    Behavior on color { ColorAnimation { duration: 90 } }
    Row {
      id: chipRow
      anchors.centerIn: parent
      spacing: 6
      Text {
        visible: chip.glyph !== ""
        text: chip.glyph
        color: chip.textColor
        font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 14
        anchors.verticalCenter: parent.verticalCenter
      }
      Rectangle {
        visible: chip.linked
        width: 6; height: 6; radius: 3
        anchors.verticalCenter: parent.verticalCenter
        color: Color.accent
      }
      Column {
        anchors.verticalCenter: parent.verticalCenter
        spacing: -1
        Text {
          text: chip.text
          color: chip.textColor
          font.family: Style.font.family; font.pixelSize: 12
        }
        Text {
          visible: chip.sub !== ""
          text: chip.sub + (chip.branch && chip.branch !== "main" && chip.branch !== "master" ? "  " + root.gBranch + " " + chip.branch : "")
          color: Color.muted
          font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 9
          width: Math.min(implicitWidth, 150)
          elide: Text.ElideRight
        }
      }
    }
    MouseArea {
      id: chipMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: chip.clicked(chip)
    }
  }
}
