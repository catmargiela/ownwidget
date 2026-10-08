# ownwidget

Desktop widgets for [Omarchy](https://omarchy.org) (Hyprland + the Quickshell-based shell), built for working with Claude Code and Codex.

- **Agents**: a desktop card that tracks your Claude Code / Codex sessions.
- **Projects**: a bar at the bottom of the screen to open, create and organise the projects in `~/Documents`.

Everything is written in QML (Omarchy shell plugins) with one small Python script per widget, no external dependencies. The interface itself is in French.

## Agents (`rebenga.agents-desk`)

A card that sits on the desktop, below your windows.

<p align="center"><img src="docs/agents-desk.png" alt="Agents card: active sessions, activity, limits and stats" width="380"></p>

- **Active sessions**: one card per Claude Code or Codex session (project, uptime, last action). Clicking it jumps to the session's terminal, even on another workspace.
- **Alert**: the frame pulses when an agent is waiting for a permission or for your reply, and a notification offers a "Y aller" (go there) button.
- **New session**: a "Y aller" notification for every new session.
- **Activity**: the agents' latest actions ("édite X" = edits X, "lance : …" = runs …).
- **Limits and stats**: gauges for the 5-hour session and the week, a projection at the current pace, today's tokens and a 7-day histogram (data from the `omarchy.agents` plugin).
- **Shortcut**: `collect.py --jump` cycles through agent terminals, the ones waiting on you first.

The collector runs continuously, reads Claude Code transcripts incrementally and never writes to disk.

## Projects (`rebenga.projects-bar`)

A horizontal bar at the bottom of the desktop, for projects laid out as `~/Documents/<group>/<project>`.

<p align="center"><img src="docs/projects-bar.png" alt="Centre search picker and the recent-projects bar" width="760"></p>

- **Recent projects**: the last 8 projects you opened (from the bar, Claude Code or VS Code), updated live.
- **Actions**: VS Code, Claude, Terminal, Files, GitHub, Copy path — with the mouse or the keyboard (`V` `C` `T` `F` `G` `Y`).
- **Branches**: pick a branch (local, remote or new); any branch other than the current one opens in a separate worktree (`project/.worktrees/<branch>`), so your working copy is never touched.
- **Centre picker**: search across every project and group (`omarchy-shell projects picker`).
- **Create**: a group, or a project as a plain folder, a local git repo or a GitHub repo (through `gh`, with owner and visibility selection). Confetti included.
- **Delete**: to the system trash only, after an alert that flags uncommitted or unpushed work; a "Restaurer" (restore) button in the notification undoes it.

## Installation

```bash
git clone https://github.com/catmargiela/ownwidget ~/Documents/perso/ownwidget
cd ~/Documents/perso/ownwidget
./install.sh
```

The script links the plugins into `~/.config/omarchy/plugins/`, copies the app icons from your system, enables the plugins and restarts the shell. It also prints the suggested keybindings:

| Shortcut | Action |
|---|---|
| `Super + Alt + A` | Next agent terminal |
| `Super + Alt + P` | Projects centre picker |

Uninstall: `./install.sh --uninstall`.

Requirements: Omarchy (Quickshell shell), Python 3, `git`, `gh` (GitHub creation), `gio` (trash), `notify-send`, a Nerd Font (JetBrainsMono Nerd Font).

## Notes

- **Disk**: the widgets only read. The single file written is an open-history capped at 200 entries in `~/.local/state/rebenga-projects/history.json`.
- **CPU**: both watchers check modification times every 2 s and only send data to the shell when something changed.
- **Development**: the shell's hot reload keeps the old QML cached; after editing, run `omarchy restart shell`.
- **Icons**: the VS Code, Claude and Files icons are not shipped in the repo (they are their owners' trademarks); `install.sh` copies them from your system.

## License

MIT
