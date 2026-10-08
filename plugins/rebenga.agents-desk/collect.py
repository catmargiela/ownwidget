#!/usr/bin/env python3
"""Coding-agent watcher for the desktop widget.

  collect.py           long-running: prints one JSON line whenever the snapshot changes
  collect.py --once    print one snapshot and exit
  collect.py --jump    focus the next Claude/Codex terminal (needs-you first, then newest)

Read-only: never writes to disk. Transcripts are read incrementally (only new bytes),
and memory is bounded (per-session state is dropped as soon as the session ends).
"""
import collections
import glob
import json
import os
import subprocess
import sys
import time
from datetime import datetime

HOME = os.path.expanduser("~")
CLAUDE_DIR = os.environ.get("CLAUDE_CONFIG_DIR", os.path.join(HOME, ".claude"))
SESSIONS_DIR = os.path.join(CLAUDE_DIR, "sessions")
USAGE_DIR = os.path.join(HOME, ".local/state/omarchy/agents/usage")
TICK = 2              # seconds between scans
CODEX_SCAN_EVERY = 5  # ticks between /proc scans for codex
INITIAL_TAIL = 200_000
MAX_READ = 2_000_000  # never read more than this per tick from one transcript
PENDING_TOOL_GRACE = 8
ACTIVITY_KEEP = 6
STATE_ORDER = {"permission": 0, "reply": 1, "working": 2, "active": 3}


def iso_to_epoch(value):
    try:
        return datetime.fromisoformat(str(value).replace("Z", "+00:00")).timestamp()
    except ValueError:
        return 0


def read_text(path):
    try:
        with open(path, "rb") as f:
            return f.read().decode(errors="replace")
    except OSError:
        return ""


def ppid_of(pid):
    try:
        return int(read_text(f"/proc/{pid}/stat").rsplit(")", 1)[1].split()[1])
    except (ValueError, IndexError):
        return 0


def comm(pid):
    return read_text(f"/proc/{pid}/comm").strip()


def child_pids(pid):
    out = []
    for task in glob.glob(f"/proc/{pid}/task/*/children"):
        out += [int(p) for p in read_text(task).split()]
    return out


def running_shell_tool(pid):
    """True while the agent has a foreground shell command running (tool executing, not waiting)."""
    for child in child_pids(pid):
        cmd = read_text(f"/proc/{child}/cmdline").replace("\0", " ")
        if "shell-snapshots" in cmd or " -c " in cmd[:20]:
            return True
    return False


def hypr_json(*args):
    try:
        out = subprocess.run(["hyprctl", *args, "-j"], capture_output=True, text=True, timeout=2).stdout
        return json.loads(out)
    except (OSError, ValueError, subprocess.TimeoutExpired):
        return None


def window_for(pid, windows):
    for _ in range(12):
        if pid <= 1:
            return ""
        if pid in windows:
            return windows[pid]
        pid = ppid_of(pid)
    return ""


def short(text, n=70):
    text = " ".join(str(text).split())
    return text if len(text) <= n else text[: n - 1] + "…"


def describe_tool(name, inp):
    inp = inp if isinstance(inp, dict) else {}
    path = inp.get("file_path") or inp.get("notebook_path") or inp.get("path")
    if name in ("Edit", "Write", "NotebookEdit") and path:
        return f"édite {os.path.basename(path)}"
    if name == "Read" and path:
        return f"lit {os.path.basename(path)}"
    if name == "Bash":
        return "lance : " + short(inp.get("description") or inp.get("command", ""), 60)
    if name in ("Grep", "Glob"):
        return "cherche " + short(inp.get("pattern", ""), 50)
    if name == "Agent":
        return "délègue : " + short(inp.get("description", ""), 50)
    if name.startswith("mcp__"):
        parts = name.split("__")
        return f"{parts[1].replace('claude_ai_', '')} · {parts[-1]}"
    return name


def project_name(cwd):
    cwd = (cwd or "").rstrip("/")
    return "~" if cwd in ("", HOME) else os.path.basename(cwd)


class ClaudeSession:
    """Incrementally follows one Claude Code transcript."""

    def __init__(self, info):
        self.info = info
        self.pid = int(info.get("pid", 0))
        self.id = info.get("sessionId", "")
        self.project = project_name(info.get("cwd"))
        self.transcript = ""
        self.offset = 0
        self.partial = b""
        self.state, self.since, self.last_action = "working", 0, ""
        self.pending = {}
        self.activity = collections.deque(maxlen=ACTIVITY_KEEP)
        self.window = ""

    def find_transcript(self):
        hits = glob.glob(os.path.join(CLAUDE_DIR, "projects", "*", f"{self.id}.jsonl"))
        return max(hits, key=os.path.getmtime) if hits else ""

    def update(self):
        if not self.transcript or not os.path.exists(self.transcript):
            self.transcript, self.offset, self.partial = self.find_transcript(), 0, b""
            if not self.transcript:
                return
            size = os.path.getsize(self.transcript)
            self.offset = max(0, size - INITIAL_TAIL)
            self.skip_first_line = self.offset > 0
        else:
            self.skip_first_line = False
        try:
            size = os.path.getsize(self.transcript)
            if size < self.offset:  # rewritten/compacted: start over from the tail
                self.offset, self.partial = max(0, size - INITIAL_TAIL), b""
            if size == self.offset:
                return
            with open(self.transcript, "rb") as f:
                f.seek(self.offset)
                chunk = f.read(MAX_READ)
            self.offset += len(chunk)
        except OSError:
            return
        data = self.partial + chunk
        lines = data.split(b"\n")
        self.partial = lines.pop()  # incomplete last line, if any
        if len(self.partial) > MAX_READ:
            self.partial = b""
        if self.skip_first_line and lines:
            lines = lines[1:]
        for line in lines:
            try:
                self.feed(json.loads(line))
            except ValueError:
                pass

    def feed(self, e):
        ts = iso_to_epoch(e.get("timestamp", ""))
        kind = e.get("type")
        msg = e.get("message") if isinstance(e.get("message"), dict) else {}
        content = msg.get("content") if isinstance(msg.get("content"), list) else []
        if kind == "assistant":
            for block in content:
                if isinstance(block, dict) and block.get("type") == "tool_use":
                    text = describe_tool(block.get("name", ""), block.get("input"))
                    self.pending[block.get("id")] = ts
                    self.activity.append({"time": ts, "text": text})
                    self.state, self.since, self.last_action = "working", ts, text
            if msg.get("stop_reason") == "end_turn":
                self.state, self.since = "reply", ts
        elif kind == "user":
            for block in content:
                if isinstance(block, dict) and block.get("type") == "tool_result":
                    self.pending.pop(block.get("tool_use_id"), None)
            if not e.get("isMeta"):
                self.state, self.since = "working", ts
        elif kind == "system" and e.get("subtype") == "turn_duration":
            self.state, self.since = "reply", ts
            self.pending.clear()
            self.activity.append({"time": ts, "text": "a fini son tour"})
        if len(self.pending) > 50:
            self.pending.clear()

    def snapshot(self, now):
        state = self.state
        if self.pending and state == "working":
            oldest = min(self.pending.values())
            if now - oldest > PENDING_TOOL_GRACE and not running_shell_tool(self.pid):
                state = "permission"
        if self.info.get("status") == "waiting":
            state = "permission"
        return {
            "tool": "claude",
            "id": self.id,
            "pid": self.pid,
            "project": self.project,
            "startedAt": self.info.get("startedAt", 0) / 1000,
            "state": state,
            "since": self.since,
            "lastAction": self.last_action,
            "window": self.window,
        }


class Watcher:
    def __init__(self):
        self.claude = {}       # session file path -> ClaudeSession
        self.file_mtimes = {}
        self.codex = []
        self.usage = {}
        self.usage_mtimes = {}
        self.tick = 0

    def refresh_windows(self, sessions, codex_scanned):
        """Map agent pids to terminal windows; only asks Hyprland when something is unmapped."""
        if all(s.window for s in sessions) and not (self.codex and codex_scanned):
            return
        windows = {c["pid"]: c["address"] for c in (hypr_json("clients") or [])}
        for s in sessions:
            s.window = window_for(s.pid, windows)
        for c in self.codex:
            c["window"] = window_for(c["pid"], windows)

    def scan_claude(self):
        seen = set()
        try:
            names = os.listdir(SESSIONS_DIR)
        except OSError:
            names = []
        for name in names:
            if not name.endswith(".json") or name.count(".") != 1:
                continue
            path = os.path.join(SESSIONS_DIR, name)
            try:
                mtime = os.path.getmtime(path)
            except OSError:
                continue
            pid = int(name.split(".")[0]) if name.split(".")[0].isdigit() else 0
            if not pid or comm(pid) != "claude":
                continue
            seen.add(path)
            if self.file_mtimes.get(path) != mtime:
                self.file_mtimes[path] = mtime
                try:
                    info = json.loads(read_text(path))
                except ValueError:
                    continue
                current = self.claude.get(path)
                if current is None or current.id != info.get("sessionId"):
                    self.claude[path] = ClaudeSession(info)
                else:
                    current.info = info
        for path in list(self.claude):
            if path not in seen:
                del self.claude[path]
                self.file_mtimes.pop(path, None)
        for s in self.claude.values():
            s.update()

    def scan_codex(self):
        pids = []
        for entry in os.listdir("/proc"):
            if entry.isdigit() and comm(entry) == "codex":
                pids.append(int(entry))
        codex = []
        for pid in pids:
            if ppid_of(pid) in pids:
                continue
            try:
                cwd = os.readlink(f"/proc/{pid}/cwd")
                started = os.stat(f"/proc/{pid}").st_ctime
            except OSError:
                continue
            codex.append({"tool": "codex", "id": f"codex-{pid}", "pid": pid, "project": project_name(cwd),
                          "startedAt": started, "since": started, "lastAction": "", "window": "", "state": "active"})
        self.codex = codex

    def scan_usage(self, now):
        for agent in ("claude", "codex"):
            path = os.path.join(USAGE_DIR, f"{agent}.json")
            try:
                mtime = os.path.getmtime(path)
            except OSError:
                self.usage.pop(agent, None)
                continue
            if self.usage_mtimes.get(agent) == mtime and self.tick % 30:
                continue  # unchanged; projections refresh once a minute
            self.usage_mtimes[agent] = mtime
            try:
                data = json.loads(read_text(path))
            except ValueError:
                continue
            if not data.get("hasLocalStats") and not data.get("limits"):
                self.usage.pop(agent, None)
                continue
            limits = []
            for lim in data.get("limits", []):
                pct = float(lim.get("percent") or 0)
                resets = iso_to_epoch(lim.get("resetsAt", ""))
                label = lim.get("label", "")
                window = 5 * 3600 if "5-hour" in label else 7 * 86400
                elapsed = window - max(0, resets - now)
                projected = round(pct * window / elapsed, 2) if elapsed > 600 and pct > 0 else None
                limits.append({"label": label, "percent": pct, "resetsAt": resets, "projected": projected})
            self.usage[agent] = {
                "tier": data.get("tierLabel", ""),
                "limits": limits,
                "todayTokens": data.get("todayTotalTokens", 0),
                "todayPrompts": data.get("todayPrompts", 0),
                "todaySessions": data.get("todaySessions", 0),
                "activeDays": data.get("activeDays", 0),
                "days": [{"date": d.get("date"), "tokens": d.get("messageCount", 0)} for d in data.get("recentDays", [])],
            }

    def snapshot(self):
        now = time.time()
        self.scan_claude()
        if self.tick % CODEX_SCAN_EVERY == 0:
            self.scan_codex()  # windows are re-mapped below on the same tick
        self.scan_usage(now)
        sessions = list(self.claude.values())
        self.refresh_windows(sessions, codex_scanned=self.tick % CODEX_SCAN_EVERY == 0)
        for c in self.codex:
            c["state"] = "working" if running_shell_tool(c["pid"]) else "active"
        out = [s.snapshot(now) for s in sessions] + self.codex
        out.sort(key=lambda s: (STATE_ORDER.get(s["state"], 9), -s["startedAt"]))
        activity = []
        for s in sessions:
            activity += [dict(a, project=s.project) for a in s.activity]
        activity.sort(key=lambda a: -a["time"])
        self.tick += 1
        return {"sessions": out, "activity": activity[:ACTIVITY_KEEP], "usage": self.usage}


def run_forever():
    watcher = Watcher()
    parent = os.getppid()
    last = None
    while True:
        if os.getppid() != parent:  # widget/shell went away
            return
        try:
            line = json.dumps(watcher.snapshot(), separators=(",", ":"))
        except Exception:  # keep running; a bad transcript line must not kill the widget
            line = last
        if line and line != last:
            try:
                sys.stdout.write(line + "\n")
                sys.stdout.flush()
            except BrokenPipeError:
                return
            last = line
        time.sleep(TICK)


def jump():
    """Focus the next agent terminal: sessions needing you first, then newest; cycles on repeat."""
    snap = Watcher().snapshot()
    targets = []
    for s in snap["sessions"]:
        if s["window"] and s["window"] not in targets:
            targets.append(s["window"])
    if not targets:
        subprocess.run(["notify-send", "-a", "Agents", "Aucune session Claude/Codex ouverte"])
        return
    active = (hypr_json("activewindow") or {}).get("address", "")
    nxt = targets[(targets.index(active) + 1) % len(targets)] if active in targets else targets[0]
    subprocess.run(["hyprctl", "dispatch", f'hl.dsp.focus({{ window = "address:{nxt}" }})'],
                   capture_output=True)


if __name__ == "__main__":
    if "--jump" in sys.argv:
        jump()
    elif "--once" in sys.argv:
        print(json.dumps(Watcher().snapshot()))
    else:
        run_forever()
