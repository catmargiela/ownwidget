#!/usr/bin/env python3
"""Project finder/creator for the projects bar. Prints JSON.

  projects.py watch                       long-running: one JSON line whenever projects or recency change
  projects.py list                        one snapshot
  projects.py branches PATH               current branch, dirty flag, local/remote branches, worktrees
  projects.py prepare PATH [BRANCH] [new] directory to open for BRANCH (reuses/creates a git worktree)
  projects.py touch PATH                  record that PATH was opened from the bar
  projects.py gh                          GitHub auth status + accounts/orgs that can own a repo
  projects.py create GROUP NAME MODE [OWNER] [VISIBILITY]   MODE: folder | git | github
  projects.py create-group NAME
  projects.py inspect PATH                what deleting PATH would lose (uncommitted / unpushed work, contents)
  projects.py trash PATH                  move a project or group to the desktop trash (recoverable)
  projects.py restore PATH                put a trashed project or group back

Disk use is bounded: the only file written is a small open-history (≤ HISTORY_MAX entries).
"""
import glob
import json
import os
import re
import select
import subprocess
import sys
import time
from urllib.parse import unquote, urlparse

HOME = os.path.expanduser("~")
ROOT = os.environ.get("PROJECTS_ROOT") or os.path.join(HOME, "Documents")
STATE_DIR = os.path.join(os.environ.get("XDG_STATE_HOME") or os.path.join(HOME, ".local/state"), "rebenga-projects")
HISTORY = os.path.join(STATE_DIR, "history.json")
HISTORY_MAX = 200
CLAUDE_PROJECTS = os.path.join(os.environ.get("CLAUDE_CONFIG_DIR") or os.path.join(HOME, ".claude"), "projects")
VSCODE_WS = os.path.join(HOME, ".config/Code/User/workspaceStorage")
WORKTREES_DIR = ".worktrees"
RECENT_COUNT = 8
TICK = 2
MARKERS = {".git", "package.json", "pyproject.toml", "Cargo.toml", "go.mod", "Makefile",
           "composer.json", "requirements.txt", "deno.json", "pubspec.yaml"}
NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,99}$")
BRANCH_RE = re.compile(r"^(?!.*\.\.)(?!.*//)[A-Za-z0-9][A-Za-z0-9._/-]{0,199}(?<![./])$")


def out(obj):
    print(json.dumps(obj, ensure_ascii=False), flush=True)


def fail(message):
    out({"ok": False, "message": message})
    sys.exit(0)


def listdir(path):
    try:
        return sorted(e for e in os.listdir(path) if not e.startswith("."))
    except OSError:
        return []


def read(path):
    try:
        with open(path) as f:
            return f.read()
    except OSError:
        return ""


def mtime(path):
    try:
        return os.path.getmtime(path)
    except OSError:
        return 0


def run(args, cwd=None, timeout=60):
    try:
        p = subprocess.run(args, cwd=cwd, capture_output=True, text=True, timeout=timeout)
        return p.returncode, (p.stdout + p.stderr).strip()
    except (OSError, subprocess.TimeoutExpired) as e:
        return 1, str(e)


# ---------- recency sources ----------

def load_history():
    try:
        data = json.loads(read(HISTORY) or "{}")
        return data if isinstance(data, dict) else {}
    except ValueError:
        return {}


def record_open(path):
    hist = load_history()
    hist[path] = time.time()
    if len(hist) > HISTORY_MAX:
        hist = dict(sorted(hist.items(), key=lambda kv: -kv[1])[:HISTORY_MAX])
    os.makedirs(STATE_DIR, exist_ok=True)
    tmp = HISTORY + ".tmp"
    with open(tmp, "w") as f:
        json.dump(hist, f)
    os.replace(tmp, HISTORY)


def claude_key(path):
    return re.sub(r"[^A-Za-z0-9]", "-", path)


def claude_recency():
    """{escaped project dir name: newest transcript mtime}"""
    result = {}
    for d in listdir(CLAUDE_PROJECTS):
        newest = max((mtime(f) for f in glob.glob(os.path.join(CLAUDE_PROJECTS, d, "*.jsonl"))), default=0)
        if newest:
            result[d] = newest
    return result


def vscode_recency():
    """{folder path: last use} from VS Code's per-workspace storage."""
    result = {}
    for ws in glob.glob(os.path.join(VSCODE_WS, "*", "workspace.json")):
        try:
            data = json.loads(read(ws))
        except ValueError:
            continue
        uri = data.get("folder") or data.get("workspace") or ""
        if not uri.startswith("file://"):
            continue
        folder = unquote(urlparse(uri).path)
        if folder.endswith(".code-workspace"):
            folder = os.path.dirname(folder)
        base = os.path.dirname(ws)
        result[folder] = max(result.get(folder, 0), mtime(os.path.join(base, "state.vscdb")), mtime(base))
    return result


# ---------- git ----------

def git_dir(path):
    return os.path.join(path, ".git")


def git_info(path):
    git = git_dir(path)
    if not os.path.isdir(git):
        return None
    head = read(os.path.join(git, "HEAD")).strip()
    branch = head.split("refs/heads/", 1)[1] if "refs/heads/" in head else head[:7]
    remote = ""
    m = re.search(r'\[remote "origin"\][^\[]*?url\s*=\s*(\S+)', read(os.path.join(git, "config")))
    if m:
        remote = m.group(1)
    web = ""
    gm = re.match(r"(?:https://|git@)github\.com[:/](.+?)(?:\.git)?/?$", remote)
    if gm:
        web = "https://github.com/" + gm.group(1)
    return {"branch": branch, "remote": remote, "webUrl": web}


def worktrees(path):
    """{branch: worktree path} for every checked-out branch of the repo at PATH."""
    code, text = run(["git", "worktree", "list", "--porcelain"], cwd=path, timeout=10)
    result, current = {}, None
    for line in text.splitlines() if code == 0 else []:
        if line.startswith("worktree "):
            current = line[9:]
        elif line.startswith("branch refs/heads/") and current:
            result[line[18:]] = current
    return result


def cmd_branches(path):
    if not os.path.isdir(git_dir(path)):
        out({"ok": False, "git": False, "message": "Pas un dépôt git"})
        return
    info = git_info(path) or {}
    code, text = run(["git", "for-each-ref", "--sort=-committerdate", "--format=%(refname)", "refs/heads", "refs/remotes"],
                     cwd=path, timeout=10)
    local, remote = [], []
    for ref in text.splitlines() if code == 0 else []:
        if ref.startswith("refs/heads/"):
            local.append(ref[11:])
        elif ref.startswith("refs/remotes/") and not ref.endswith("/HEAD"):
            name = ref[13:]
            if "/" not in name:
                continue
            if name.split("/", 1)[1] not in local:
                remote.append(name)
    code, status = run(["git", "status", "--porcelain", "--untracked-files=no"], cwd=path, timeout=10)
    out({"ok": True, "git": True, "current": info.get("branch", ""), "dirty": bool(status.strip()),
         "local": local, "remote": remote, "worktrees": worktrees(path)})


def ensure_excluded(path):
    exclude = os.path.join(git_dir(path), "info", "exclude")
    if f"/{WORKTREES_DIR}/" not in read(exclude):
        os.makedirs(os.path.dirname(exclude), exist_ok=True)
        with open(exclude, "a") as f:
            f.write(f"\n/{WORKTREES_DIR}/\n")


def ref_exists(path, ref):
    return run(["git", "show-ref", "--verify", "--quiet", ref], cwd=path)[0] == 0


def cmd_prepare(path, branch="", new=""):
    """Return the directory to open for BRANCH, never touching the user's current checkout.

    The current branch opens the project itself; any other branch opens in (or creates) a
    worktree under PROJECT/.worktrees/, which is git-excluded locally.
    """
    if not os.path.isdir(path):
        fail("Projet introuvable")
    if not branch:
        record_open(path)
        out({"ok": True, "dir": path, "message": ""})
        return
    if not os.path.isdir(git_dir(path)):
        fail("Pas un dépôt git")
    if not BRANCH_RE.match(branch):
        fail("Nom de branche invalide")
    local_name, remote_ref = branch, ""
    is_local = ref_exists(path, f"refs/heads/{branch}")
    if not is_local and not new:
        if not ref_exists(path, f"refs/remotes/{branch}") or "/" not in branch:
            fail(f"Branche « {branch} » introuvable")
        remote_ref, local_name = branch, branch.split("/", 1)[1]  # origin/feat → feat tracking it
        is_local = ref_exists(path, f"refs/heads/{local_name}")
    if new and is_local:
        fail(f"La branche « {branch} » existe déjà")
    existing = worktrees(path).get(local_name)
    if existing:
        record_open(path)
        out({"ok": True, "dir": existing, "message": ""})
        return
    target = os.path.join(path, WORKTREES_DIR, local_name.replace("/", "-"))
    ensure_excluded(path)
    if is_local:
        args = ["git", "worktree", "add", target, local_name]
    elif remote_ref:
        args = ["git", "worktree", "add", "--track", "-b", local_name, target, remote_ref]
    else:
        args = ["git", "worktree", "add", "-b", local_name, target]
    code, text = run(args, cwd=path, timeout=120)
    if code != 0:
        fail("git worktree : " + (text.splitlines()[-1] if text else "échec"))
    record_open(path)
    out({"ok": True, "dir": target, "message": f"Worktree {local_name} créé"})


# ---------- listing ----------

def is_project(path):
    try:
        return bool(set(os.listdir(path)) & MARKERS)
    except OSError:
        return False


def activity(path):
    return max(mtime(path), mtime(os.path.join(path, ".git", "index")), mtime(os.path.join(path, ".git", "HEAD")))


def project(path, group, sources):
    hist, claude, vscode = sources
    prefix = path + "/" + WORKTREES_DIR + "/"
    opened = max([hist.get(path, 0), claude.get(claude_key(path), 0), vscode.get(path, 0)]
                 + [ts for p, ts in vscode.items() if p.startswith(prefix)]
                 + [ts for k, ts in claude.items() if k.startswith(claude_key(prefix))])
    return {"name": os.path.basename(path), "path": path, "group": group, "git": git_info(path),
            "mtime": activity(path), "opened": opened}


def snapshot():
    sources = (load_history(), claude_recency(), vscode_recency())
    groups, loose = [], []
    for entry in listdir(ROOT):
        path = os.path.join(ROOT, entry)
        if not os.path.isdir(path):
            continue
        if is_project(path):
            loose.append(project(path, "Documents", sources))
            continue
        projects = [project(os.path.join(path, p), entry, sources) for p in listdir(path)
                    if os.path.isdir(os.path.join(path, p))]
        projects.sort(key=lambda p: -max(p["opened"], p["mtime"]))
        workspace = next((os.path.join(path, f) for f in listdir(path) if f.endswith(".code-workspace")), "")
        groups.append({"name": entry, "path": path, "workspace": workspace, "projects": projects})
    if loose:
        groups.append({"name": "Documents", "path": ROOT, "workspace": "", "projects": loose})
    everything = [p for g in groups for p in g["projects"]]
    # Recent = opened (bar / Claude / VS Code) first, then most recently modified.
    recent = sorted(everything, key=lambda p: (-p["opened"], -p["mtime"]))[:RECENT_COUNT]
    groups.sort(key=lambda g: -max([max(p["opened"], p["mtime"]) for p in g["projects"]] or [0]))
    return {"root": ROOT, "groups": groups, "recent": [p["path"] for p in recent]}


def watch_signature():
    """Cheap stat-only fingerprint of everything the snapshot depends on."""
    sig = [mtime(ROOT), mtime(HISTORY), mtime(CLAUDE_PROJECTS), mtime(VSCODE_WS)]
    for entry in listdir(ROOT):
        path = os.path.join(ROOT, entry)
        sig.append((entry, mtime(path)))
        for p in listdir(path) if os.path.isdir(path) else []:
            pp = os.path.join(path, p)
            sig.append((p, mtime(os.path.join(pp, ".git", "HEAD")), mtime(os.path.join(pp, ".git", "config"))))
    for d in listdir(CLAUDE_PROJECTS):
        sig.append(mtime(os.path.join(CLAUDE_PROJECTS, d)))
    return sig


def wait_for_nudge(listen):
    """Sleep up to TICK; return early when the widget writes a line on stdin (instant refresh).
    Returns False once stdin is closed (then plain sleeping is used)."""
    if not listen:
        time.sleep(TICK)
        return False, False
    ready, _, _ = select.select([sys.stdin], [], [], TICK)
    if not ready:
        return True, False
    line = sys.stdin.readline()
    return (line != ""), (line != "")


def cmd_watch():
    parent = os.getppid()
    last_sig, last_line, idle = None, None, 0
    listen, nudged = True, False
    while os.getppid() == parent:  # exit with the shell
        sig = watch_signature()
        idle += 1
        # Rebuild on any change or nudge, and every 30 s to catch transcript appends (no dir mtime bump).
        if sig != last_sig or idle >= 15 or nudged:
            last_sig, idle = sig, 0
            try:
                line = json.dumps(snapshot(), ensure_ascii=False, separators=(",", ":"))
            except Exception:
                line = last_line
            if line and line != last_line:
                try:
                    print(line, flush=True)
                except BrokenPipeError:
                    return
                last_line = line
        listen, nudged = wait_for_nudge(listen)


# ---------- creation ----------

def gh_user():
    code, text = run(["gh", "api", "user", "--jq", ".login"], timeout=15)
    return text if code == 0 else ""


def cmd_gh():
    user = gh_user()
    if not user:
        code, text = run(["gh", "auth", "status"], timeout=15)
        out({"ok": False, "user": "", "owners": [], "message": text.splitlines()[0] if text else "gh non connecté"})
        return
    code, text = run(["gh", "org", "list"], timeout=15)
    orgs = [o.strip() for o in text.splitlines() if o.strip()] if code == 0 else []
    out({"ok": True, "user": user, "owners": [user] + orgs, "message": f"Connecté en tant que {user}"})


def cmd_create_group(name):
    if not NAME_RE.match(name):
        fail("Nom invalide : lettres, chiffres, . _ - uniquement")
    path = os.path.join(ROOT, name)
    if os.path.exists(path):
        fail(f"Le groupe {name} existe déjà")
    os.makedirs(path)
    out({"ok": True, "path": path, "message": f"Groupe {name} créé"})


def cmd_create(group, name, mode, owner="", visibility="private"):
    if not NAME_RE.match(name):
        fail("Nom invalide : lettres, chiffres, . _ - uniquement")
    if group and group != "Documents" and not NAME_RE.match(group):
        fail("Nom de groupe invalide")
    if mode not in ("folder", "git", "github"):
        fail("Mode inconnu")
    base = os.path.join(ROOT, group) if group and group != "Documents" else ROOT
    path = os.path.join(base, name)
    if os.path.exists(path):
        fail(f"{path} existe déjà")
    os.makedirs(path)
    with open(os.path.join(path, "README.md"), "w") as f:
        f.write(f"# {name}\n")
    result = {"ok": True, "path": path, "webUrl": "", "message": "Dossier créé"}
    if mode in ("git", "github"):
        for args in (["git", "init", "-q"], ["git", "add", "-A"], ["git", "commit", "-q", "-m", "Initial commit"]):
            code, text = run(args, cwd=path)
            if code != 0:
                fail(f"git : {text}")
        result["message"] = "Dépôt git local créé"
    if mode == "github":
        if not gh_user():
            result.update(ok=False, message="Dépôt local créé, mais gh n'est pas connecté (gh auth login)")
            out(result)
            return
        repo = f"{owner}/{name}" if owner else name
        flag = "--public" if visibility == "public" else "--private"
        code, text = run(["gh", "repo", "create", repo, flag, "--source", path, "--remote", "origin", "--push"],
                         cwd=path, timeout=120)
        if code != 0:
            result.update(ok=False, message=f"Dépôt local créé, GitHub a échoué : {text.splitlines()[-1] if text else ''}")
            out(result)
            return
        info = git_info(path) or {}
        result.update(webUrl=info.get("webUrl", ""), message=f"Publié sur GitHub ({'public' if flag == '--public' else 'privé'})")
    record_open(path)
    out(result)


# ---------- deletion (always via the trash) ----------

def safe_target(path):
    """Only a group (ROOT/x) or a project (ROOT/x/y) may be trashed — never ROOT or anything outside it."""
    root = os.path.realpath(ROOT)
    real = os.path.realpath(path)
    rel = os.path.relpath(real, root)
    if rel.startswith("..") or rel == "." or os.path.islink(path) or not os.path.isdir(real):
        fail("Chemin refusé")
    if rel.count(os.sep) > 1 or any(part.startswith(".") for part in rel.split(os.sep)):
        fail("Chemin refusé")
    return real


def git_risks(path):
    risks = []
    if not os.path.isdir(git_dir(path)):
        return risks
    code, status = run(["git", "status", "--porcelain"], cwd=path, timeout=10)
    changed = [l for l in status.splitlines() if l.strip()] if code == 0 else []
    if changed:
        risks.append(f"{len(changed)} fichier(s) modifié(s) ou non suivi(s) non commités")
    code, ahead = run(["git", "rev-list", "--count", "@{u}..HEAD"], cwd=path, timeout=10)
    if code == 0 and ahead.strip() not in ("", "0"):
        risks.append(f"{ahead.strip()} commit(s) non poussé(s)")
    elif code != 0:
        info = git_info(path) or {}
        risks.append("Branche sans upstream : rien n'est poussé" if info.get("remote") else "Aucun dépôt distant : l'historique git n'existe qu'ici")
    extra = [p for p in worktrees(path).values() if os.path.realpath(p) != os.path.realpath(path)]
    if extra:
        risks.append(f"{len(extra)} worktree(s) seront aussi supprimés")
    return risks


def cmd_inspect(path):
    real = safe_target(path)
    is_group = os.path.dirname(real) == os.path.realpath(ROOT) and not is_project(real)
    result = {"ok": True, "path": real, "name": os.path.basename(real), "kind": "group" if is_group else "project", "risks": []}
    if is_group:
        projects = [p for p in listdir(real) if os.path.isdir(os.path.join(real, p))]
        result["projects"] = projects
        for p in projects:
            for risk in git_risks(os.path.join(real, p)):
                result["risks"].append(f"{p} : {risk}")
    else:
        result["risks"] = git_risks(real)
    out(result)


def cmd_trash(path):
    real = safe_target(path)
    code, text = run(["gio", "trash", real], timeout=60)
    if code != 0:
        fail("Corbeille : " + (text.splitlines()[-1] if text else "échec"))
    out({"ok": True, "path": real, "name": os.path.basename(real), "message": f"{os.path.basename(real)} mis à la corbeille"})


def cmd_restore(path):
    code, text = run(["gio", "trash", "--list"], timeout=30)
    uri = ""
    for line in text.splitlines() if code == 0 else []:
        item, _, original = line.partition("\t")
        if original == path:
            uri = item  # last match = most recent
    if not uri:
        fail("Introuvable dans la corbeille")
    if os.path.exists(path):
        fail(f"{path} existe déjà")
    code, text = run(["gio", "trash", "--restore", uri], timeout=60)
    if code != 0:
        fail("Restauration : " + (text.splitlines()[-1] if text else "échec"))
    out({"ok": True, "path": path, "message": f"{os.path.basename(path)} restauré"})


if __name__ == "__main__":
    args = sys.argv[1:]
    cmd = args[0] if args else "list"
    if cmd == "watch":
        cmd_watch()
    elif cmd == "list":
        out(snapshot())
    elif cmd == "branches" and len(args) >= 2:
        cmd_branches(args[1])
    elif cmd == "prepare" and len(args) >= 2:
        cmd_prepare(*args[1:4])
    elif cmd == "touch" and len(args) >= 2:
        record_open(args[1])
        out({"ok": True})
    elif cmd == "gh":
        cmd_gh()
    elif cmd == "create" and len(args) >= 4:
        cmd_create(*args[1:6])
    elif cmd == "create-group" and len(args) >= 2:
        cmd_create_group(args[1])
    elif cmd == "inspect" and len(args) >= 2:
        cmd_inspect(args[1])
    elif cmd == "trash" and len(args) >= 2:
        cmd_trash(args[1])
    elif cmd == "restore" and len(args) >= 2:
        cmd_restore(args[1])
    else:
        fail("usage: see projects.py header")
