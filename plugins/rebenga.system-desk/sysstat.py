#!/usr/bin/env python3
"""System stats for the desktop widget.

  sysstat.py watch         long-running: one JSON line every TICK seconds
                           (write "scan" on stdin to re-measure big folders now)
  sysstat.py clean KIND PATH
      KIND: trash | cache | node_modules | npm   — deletes regenerable data only

Cheap by design: /proc and /sys reads every tick; the NVIDIA GPU is never woken up
(nvidia-smi only runs while the GPU is already awake); folder sizes are measured
with `nice`/`ionice` every SCAN_EVERY seconds in a background thread.
"""
import glob
import json
import os
import select
import shutil
import subprocess
import sys
import threading
import time

HOME = os.path.expanduser("~")
DOCUMENTS = os.path.join(HOME, "Documents")
TICK = 2
GPU_EVERY = 5            # ticks between nvidia-smi / process scans while the GPU is awake
SCAN_EVERY = 30 * 60     # seconds between big-folder scans
HISTORY = 60             # samples kept for sparklines
CACHE_KEEP = {"omarchy", "quickshell", "fontconfig"}   # never offered for cleaning


def read(path, default=""):
    try:
        with open(path) as f:
            return f.read().strip()
    except OSError:
        return default


def read_int(path, default=0):
    try:
        return int(read(path))
    except ValueError:
        return default


def run(args, timeout=10):
    try:
        p = subprocess.run(args, capture_output=True, text=True, timeout=timeout)
        return p.returncode, p.stdout.strip()
    except (OSError, subprocess.TimeoutExpired):
        return 1, ""


# ---------- sensors ----------

def hwmon(name):
    for h in glob.glob("/sys/class/hwmon/hwmon*"):
        if read(h + "/name") == name:
            return h
    return ""


class Sensors:
    def __init__(self):
        self.core = hwmon("coretemp") or hwmon("k10temp") or hwmon("zenpower")
        self.nvme = hwmon("nvme")
        self.fans = hwmon("asus")
        self.bat = next(iter(glob.glob("/sys/class/power_supply/BAT*")), "")
        self.adp = next((p for p in glob.glob("/sys/class/power_supply/*")
                         if read(p + "/type") == "Mains"), "")
        self.gpu_pci = self.find_nvidia()

    @staticmethod
    def find_nvidia():
        for dev in glob.glob("/sys/bus/pci/devices/*"):
            if read(dev + "/vendor") == "0x10de" and read(dev + "/class").startswith("0x03"):
                return dev
        return ""

    def cpu_temp(self):
        if not self.core:
            return None
        for label in glob.glob(self.core + "/temp*_label"):
            if read(label).startswith(("Package", "Tctl", "Tdie")):
                return read_int(label.replace("_label", "_input")) / 1000
        return read_int(self.core + "/temp1_input") / 1000 or None

    def nvme_temp(self):
        return read_int(self.nvme + "/temp1_input") / 1000 if self.nvme else None

    def fan_speeds(self):
        out = []
        for f in sorted(glob.glob(self.fans + "/fan*_input")) if self.fans else []:
            label = read(f.replace("_input", "_label"), os.path.basename(f))
            out.append({"label": label.replace("_fan", "").upper(), "rpm": read_int(f)})
        return out

    def battery(self):
        if not self.bat:
            return None
        power = read_int(self.bat + "/power_now") / 1e6
        if not power:
            power = read_int(self.bat + "/current_now") * read_int(self.bat + "/voltage_now") / 1e12
        energy, full = read_int(self.bat + "/energy_now"), read_int(self.bat + "/energy_full")
        status = read(self.bat + "/status")
        remaining = None
        if power > 0.5 and status == "Discharging" and energy:
            remaining = energy / 1e6 / power * 3600
        elif power > 0.5 and status == "Charging" and full:
            remaining = (full - energy) / 1e6 / power * 3600
        return {"percent": read_int(self.bat + "/capacity"), "status": status,
                "plugged": read(self.adp + "/online") == "1" if self.adp else None,
                "watts": round(power, 1), "remaining": remaining}


# ---------- CPU / memory / network / processes ----------

class Counters:
    def __init__(self):
        self.cpu_prev = None
        self.net_prev = None
        self.proc_prev = {}
        self.clk = os.sysconf("SC_CLK_TCK")
        self.ncpu = os.cpu_count() or 1
        self.cpu_hist, self.down_hist, self.up_hist = [], [], []

    def cpu(self):
        fields = [int(x) for x in read("/proc/stat").splitlines()[0].split()[1:]]
        idle, total = fields[3] + fields[4], sum(fields[:8])
        pct = 0.0
        if self.cpu_prev:
            dt = total - self.cpu_prev[1]
            pct = 100 * (1 - (idle - self.cpu_prev[0]) / dt) if dt else 0
        self.cpu_prev = (idle, total)
        self.cpu_hist = (self.cpu_hist + [round(pct, 1)])[-HISTORY:]
        return round(pct, 1)

    @staticmethod
    def memory():
        info = {}
        for line in read("/proc/meminfo").splitlines():
            k, v = line.split(":", 1)
            info[k] = int(v.split()[0]) * 1024
        total, avail = info.get("MemTotal", 0), info.get("MemAvailable", 0)
        swap_used = info.get("SwapTotal", 0) - info.get("SwapFree", 0)
        return {"used": total - avail, "total": total, "swapUsed": swap_used, "swapTotal": info.get("SwapTotal", 0)}

    def network(self, now):
        rx = tx = 0
        for line in read("/proc/net/dev").splitlines()[2:]:
            name, data = line.split(":", 1)
            if name.strip() == "lo":
                continue
            cols = data.split()
            rx, tx = rx + int(cols[0]), tx + int(cols[8])
        down = up = 0
        if self.net_prev:
            dt = max(0.1, now - self.net_prev[2])
            down, up = (rx - self.net_prev[0]) / dt, (tx - self.net_prev[1]) / dt
        self.net_prev = (rx, tx, now)
        self.down_hist = (self.down_hist + [round(down)])[-HISTORY:]
        self.up_hist = (self.up_hist + [round(up)])[-HISTORY:]
        return {"down": round(down), "up": round(up)}

    def top_processes(self, dt):
        """Top CPU consumers since the previous tick, grouped by program name."""
        current, usage = {}, {}
        for pid in os.listdir("/proc"):
            if not pid.isdigit():
                continue
            stat = read(f"/proc/{pid}/stat")
            if not stat:
                continue
            try:
                name = stat[stat.index("(") + 1:stat.rindex(")")]
                rest = stat[stat.rindex(")") + 2:].split()
                ticks = int(rest[11]) + int(rest[12])
                rss = int(rest[21]) * 4096
            except (ValueError, IndexError):
                continue
            current[pid] = ticks
            prev = self.proc_prev.get(pid)
            entry = usage.setdefault(name, {"name": name, "cpu": 0.0, "mem": 0})
            entry["mem"] += rss
            if prev is not None and dt > 0:
                entry["cpu"] += (ticks - prev) / self.clk / dt * 100 / self.ncpu
        self.proc_prev = current
        procs = list(usage.values())
        top_cpu = sorted(procs, key=lambda p: -p["cpu"])[:4]
        top_mem = sorted(procs, key=lambda p: -p["mem"])[:4]
        for p in top_cpu + top_mem:
            p["cpu"] = round(p["cpu"], 1)
        return top_cpu, top_mem


# ---------- NVIDIA ----------

class Gpu:
    def __init__(self, pci):
        self.pci = pci
        self.details = {}

    def state(self):
        if not self.pci:
            return None
        return read(self.pci + "/power/runtime_status") or "unknown"

    def refresh(self):
        """Only called while the GPU is already awake, so nothing here wakes it up."""
        code, text = run(["nvidia-smi", "--query-gpu=temperature.gpu,power.draw,utilization.gpu,memory.used,memory.total",
                          "--format=csv,noheader,nounits"])
        if code == 0 and text:
            try:
                t, p, u, mu, mt = [x.strip() for x in text.split(",")]
                self.details = {"temp": float(t), "watts": float(p), "util": float(u),
                                "memUsed": float(mu), "memTotal": float(mt)}
            except ValueError:
                self.details = {}
        self.details["users"] = self.users()

    @staticmethod
    def users():
        """Programs (of this user) holding /dev/nvidia* open — what keeps the GPU awake."""
        names = set()
        for pid in os.listdir("/proc"):
            if not pid.isdigit():
                continue
            try:
                for fd in os.listdir(f"/proc/{pid}/fd"):
                    if os.readlink(f"/proc/{pid}/fd/{fd}").startswith("/dev/nvidia"):
                        names.add(read(f"/proc/{pid}/comm"))
                        break
            except OSError:
                continue
        return sorted(n for n in names if n)


# ---------- disk ----------

def disk_usage():
    out = []
    seen = set()
    for mount in ("/", HOME):
        try:
            st = os.statvfs(mount)
        except OSError:
            continue
        key = (st.f_blocks, st.f_bfree)
        if key in seen:
            continue
        seen.add(key)
        total = st.f_blocks * st.f_frsize
        free = st.f_bavail * st.f_frsize
        out.append({"mount": mount.replace(HOME, "~"), "total": total, "used": total - free, "free": free})
    return out


def du(paths):
    if not paths:
        return {}
    code, text = run(["nice", "-n", "19", "ionice", "-c", "3", "du", "-sb", "--", *paths], timeout=600)
    sizes = {}
    for line in text.splitlines():
        size, _, path = line.partition("\t")
        if size.isdigit():
            sizes[path] = int(size)
    return sizes


def node_modules_dirs():
    found = []
    for root, dirs, _ in os.walk(DOCUMENTS):
        depth = root[len(DOCUMENTS):].count(os.sep)
        if "node_modules" in dirs:
            found.append(os.path.join(root, "node_modules"))
        dirs[:] = [d for d in dirs if d != "node_modules" and not d.startswith(".") and depth < 4]
    return found


def scan_big_folders():
    """Biggest regenerable / notable folders, largest first."""
    candidates = {}
    trash = os.path.join(HOME, ".local/share/Trash")
    candidates[trash] = ("trash", "Corbeille")
    for d in glob.glob(os.path.join(HOME, ".cache", "*")):
        name = os.path.basename(d)
        if os.path.isdir(d) and not os.path.islink(d):
            candidates[d] = ("cache" if name not in CACHE_KEEP else "", "Cache " + name)
    npm = os.path.join(HOME, ".npm", "_cacache")
    if os.path.isdir(npm):
        candidates[npm] = ("npm", "Cache npm")
    for nm in node_modules_dirs():
        candidates[nm] = ("node_modules", "node_modules · " + os.path.relpath(os.path.dirname(nm), DOCUMENTS))
    for extra, label in ((os.path.join(HOME, "Downloads"), "Téléchargements"),
                         ("/var/cache/pacman/pkg", "Cache pacman"),
                         (os.path.join(HOME, ".local/share/mise/installs"), "Outils mise")):
        if os.path.isdir(extra):
            candidates[extra] = ("pacman" if "pacman" in extra else "", label)
    sizes = du(list(candidates))
    rows = []
    for path, size in sizes.items():
        kind, label = candidates.get(path, ("", path))
        rows.append({"path": path, "label": label, "size": size, "kind": kind})
    rows.sort(key=lambda r: -r["size"])
    return rows[:8]


# ---------- cleaning ----------

def fail(message):
    print(json.dumps({"ok": False, "message": message}, ensure_ascii=False))
    sys.exit(0)


def dir_size(path):
    return du([path]).get(path, 0)


def cmd_clean(kind, path=""):
    if kind == "trash":
        before = dir_size(os.path.join(HOME, ".local/share/Trash"))
        code, _ = run(["gio", "trash", "--empty"], timeout=300)
        if code != 0:
            fail("Impossible de vider la corbeille")
        print(json.dumps({"ok": True, "freed": before, "message": "Corbeille vidée"}, ensure_ascii=False))
        return
    real = os.path.realpath(path)
    if os.path.islink(path) or not os.path.isdir(real):
        fail("Chemin refusé")
    if kind == "cache":
        ok = os.path.dirname(real) == os.path.realpath(os.path.join(HOME, ".cache")) and os.path.basename(real) not in CACHE_KEEP
    elif kind == "node_modules":
        ok = os.path.basename(real) == "node_modules" and real.startswith(os.path.realpath(DOCUMENTS) + os.sep)
    elif kind == "npm":
        ok = real == os.path.realpath(os.path.join(HOME, ".npm", "_cacache"))
    else:
        ok = False
    if not ok:
        fail("Chemin refusé")
    before = dir_size(real)
    shutil.rmtree(real, ignore_errors=True)
    left = dir_size(real) if os.path.exists(real) else 0
    print(json.dumps({"ok": True, "freed": before - left,
                      "message": "Nettoyé" if not left else "Nettoyé en partie (fichiers en cours d'utilisation)"},
                     ensure_ascii=False))


# ---------- main loop ----------

def cmd_watch():
    sensors, counters, gpu = Sensors(), Counters(), Gpu(Sensors.find_nvidia())
    big = {"rows": [], "scannedAt": 0, "scanning": False}
    lock = threading.Lock()

    def scan():
        with lock:
            if big["scanning"]:
                return
            big["scanning"] = True
        rows = scan_big_folders()
        with lock:
            big.update(rows=rows, scannedAt=time.time(), scanning=False)

    parent = os.getppid()
    listen, tick, last = True, 0, time.time()
    threading.Thread(target=scan, daemon=True).start()
    counters.cpu()
    counters.top_processes(0)
    while os.getppid() == parent:
        now = time.time()
        dt, last = now - last, now
        state = gpu.state()
        if state == "active" and tick % GPU_EVERY == 0:
            gpu.refresh()
        elif state != "active":
            gpu.details = {}
        if now - big["scannedAt"] > SCAN_EVERY and not big["scanning"]:
            threading.Thread(target=scan, daemon=True).start()
        top_cpu, top_mem = counters.top_processes(dt)
        with lock:
            big_rows, scanned_at, scanning = list(big["rows"]), big["scannedAt"], big["scanning"]
        snap = {
            "cpu": {"percent": counters.cpu(), "history": counters.cpu_hist, "temp": sensors.cpu_temp(),
                    "load": os.getloadavg()[0], "cores": counters.ncpu},
            "memory": counters.memory(),
            "network": dict(counters.network(now), downHistory=counters.down_hist, upHistory=counters.up_hist),
            "battery": sensors.battery(),
            "fans": sensors.fan_speeds(),
            "nvmeTemp": sensors.nvme_temp(),
            "gpu": {"present": bool(gpu.pci), "state": state, **gpu.details},
            "topCpu": top_cpu, "topMem": top_mem,
            "disks": disk_usage(),
            "big": big_rows, "scannedAt": scanned_at, "scanning": scanning,
            "uptime": float(read("/proc/uptime", "0").split()[0]),
        }
        try:
            print(json.dumps(snap, ensure_ascii=False, separators=(",", ":")), flush=True)
        except BrokenPipeError:
            return
        tick += 1
        # Sleep until next tick; a "scan" line on stdin triggers an immediate folder scan.
        if listen:
            ready, _, _ = select.select([sys.stdin], [], [], TICK)
            if ready:
                line = sys.stdin.readline()
                if not line:
                    listen = False
                elif line.strip() == "scan":
                    threading.Thread(target=scan, daemon=True).start()
        else:
            time.sleep(TICK)


if __name__ == "__main__":
    args = sys.argv[1:]
    if not args or args[0] == "watch":
        cmd_watch()
    elif args[0] == "clean" and len(args) >= 2:
        cmd_clean(args[1], args[2] if len(args) > 2 else "")
    else:
        fail("usage: sysstat.py watch | clean KIND [PATH]")
