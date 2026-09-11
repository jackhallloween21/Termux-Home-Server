#!/data/data/com.termux/files/usr/bin/python
"""
Small local backend for the home server dashboard.
Binds to 127.0.0.1 only — nginx proxies /api/ to this and applies basic auth,
so this process should never be exposed directly.

Endpoints:
  GET  /health          -> {status: ok}
  GET  /api/stats  (via nginx: /api/stats) -> cpu/ram/disk/net/io/uptime/battery
  GET  /api/info   (via nginx: /api/info)  -> ssh/sftp cmds, ips, tunnel url
  POST /add-download    -> queue URL in aria2
  POST /restart/<svc>   -> restart nginx|aria2|glances|cloudflared|ttyd|api
"""

import json
import os
import re
import shutil
import socket
import subprocess
import time
import getpass
from pathlib import Path

import requests
from flask import Flask, request, jsonify

app = Flask(__name__)

# ---- config ----
ARIA2_RPC_URL = "http://127.0.0.1:6800/jsonrpc"
ARIA2_SECRET = "yourtoken"          # must match your aria2c --rpc-secret
DOWNLOAD_DIR = "/data/data/com.termux/files/home/downloads"
HOME = str(Path.home())
SSHD_PORT = 8022  # Termux default

SERVICES = {
    "nginx": {
        "stop": ["nginx", "-s", "stop"],
        "start": ["nginx"],
        "pattern": "nginx",
    },
    "aria2": {
        "stop": ["pkill", "-f", "aria2c"],
        "start": [
            "aria2c", "--enable-rpc", "--rpc-listen-all",
            "--rpc-listen-port=6800", f"--dir={DOWNLOAD_DIR}",
            "--daemon=true", f"--rpc-secret={ARIA2_SECRET}",
            "--log=/data/data/com.termux/files/home/aria2.log",
            "--log-level=warn",
        ],
        "pattern": "aria2c",
    },
    "glances": {
        "stop": ["pkill", "-f", "glances"],
        "start_bg": ["glances", "-w", "--bind", "0.0.0.0", "--port", "61208"],
        "pattern": "glances",
    },
    "cloudflared": {
        "stop": ["pkill", "-f", "cloudflared"],
        "start_bg": ["cloudflared", "tunnel", "run", "homeserver"],
        "pattern": "cloudflared",
    },
    "ttyd": {
        "stop": ["pkill", "-f", "ttyd"],
        "start_bg": ["ttyd", "-p", "7681", "-i", "127.0.0.1", "bash"],
        "pattern": "ttyd",
    },
}

# ---- cached counters for rates ----
_last_cpu = None
_last_cpu_t = 0.0
_last_net = None
_last_net_t = 0.0


def _read_proc_stat():
    try:
        with open("/proc/stat") as f:
            parts = f.readline().split()[1:]
        vals = list(map(int, parts))
        total = sum(vals)
        idle = vals[3] + (vals[4] if len(vals) > 4 else 0)
        return total, idle
    except Exception:
        return None


def cpu_percent():
    global _last_cpu, _last_cpu_t
    cur = _read_proc_stat()
    now = time.time()
    if cur is None:
        return 0.0
    if _last_cpu is None:
        _last_cpu, _last_cpu_t = cur, now
        return 0.0
    dt_total = cur[0] - _last_cpu[0]
    dt_idle = cur[1] - _last_cpu[1]
    _last_cpu, _last_cpu_t = cur, now
    if dt_total <= 0:
        return 0.0
    return round((1.0 - dt_idle / dt_total) * 100.0, 1)


def mem_info():
    try:
        info = {}
        with open("/proc/meminfo") as f:
            for line in f:
                k, v = line.split(":", 1)
                m = re.search(r"(\d+)", v)
                if m:
                    info[k.strip()] = int(m.group(1))  # kB
        total = info.get("MemTotal", 0)
        avail = info.get("MemAvailable", info.get("MemFree", 0))
        used = max(total - avail, 0)
        pct = round(used / total * 100, 1) if total else 0.0
        return {"total_mb": round(total / 1024, 1), "used_mb": round(used / 1024, 1),
                "avail_mb": round(avail / 1024, 1), "percent": pct}
    except Exception:
        return {"total_mb": 0, "used_mb": 0, "avail_mb": 0, "percent": 0.0}


def disk_info(path=DOWNLOAD_DIR):
    try:
        if not os.path.exists(path):
            path = HOME
        u = shutil.disk_usage(path)
        pct = round(u.used / u.total * 100, 1) if u.total else 0.0
        return {"path": path, "total_gb": round(u.total / 1e9, 2),
                "used_gb": round(u.used / 1e9, 2), "free_gb": round(u.free / 1e9, 2),
                "percent": pct}
    except Exception:
        return {"path": path, "total_gb": 0, "used_gb": 0, "free_gb": 0, "percent": 0.0}


def net_info():
    """Aggregate rx/tx bytes across non-loopback ifaces + per-second rates."""
    global _last_net, _last_net_t
    rx = tx = 0
    ifaces = {}
    try:
        with open("/proc/net/dev") as f:
            for line in f:
                if ":" not in line:
                    continue
                name, rest = line.split(":", 1)
                name = name.strip()
                fields = rest.split()
                if len(fields) < 9:
                    continue
                r, t = int(fields[0]), int(fields[8])
                ifaces[name] = {"rx": r, "tx": t}
                if name != "lo":
                    rx += r
                    tx += t
    except Exception:
        pass
    now = time.time()
    rx_s = tx_s = 0.0
    if _last_net is not None and now > _last_net_t:
        dt = now - _last_net_t
        rx_s = round(max(rx - _last_net[0], 0) / dt, 1)
        tx_s = round(max(tx - _last_net[1], 0) / dt, 1)
    _last_net, _last_net_t = (rx, tx), now
    return {"rx_bytes": rx, "tx_bytes": tx, "rx_per_s": rx_s, "tx_per_s": tx_s,
            "ifaces": ifaces}


def disk_io():
    """Summed read/write KB from /proc/diskstats (best-effort)."""
    rd_kb = wr_kb = 0
    try:
        with open("/proc/diskstats") as f:
            for line in f:
                p = line.split()
                if len(p) < 14:
                    continue
                # fields: 6=sectors read, 10=sectors written (512B each)
                rd_kb += int(p[5]) * 512 // 1024
                wr_kb += int(p[9]) * 512 // 1024
    except Exception:
        pass
    return {"read_kb": rd_kb, "written_kb": wr_kb}


def uptime_info():
    try:
        with open("/proc/uptime") as f:
            secs = float(f.read().split()[0])
        days, secs = divmod(int(secs), 86400)
        hrs, secs = divmod(secs, 3600)
        mins, secs = divmod(secs, 60)
        if days:
            human = f"{days}d {hrs}h {mins}m"
        elif hrs:
            human = f"{hrs}h {mins}m"
        else:
            human = f"{mins}m {secs}s"
        return {"seconds": int(open('/proc/uptime').read().split()[0].split('.')[0]),
                "human": human}
    except Exception:
        try:
            out = subprocess.run(["uptime", "-p"], capture_output=True, text=True, timeout=5)
            return {"seconds": 0, "human": out.stdout.strip() or "unknown"}
        except Exception:
            return {"seconds": 0, "human": "unknown"}


def load_avg():
    try:
        a, b, c = os.getloadavg()
        return [round(a, 2), round(b, 2), round(c, 2)]
    except Exception:
        return [0.0, 0.0, 0.0]


def local_ip():
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.settimeout(2)
        s.connect(("8.8.8.8", 80))
        ip = s.getsockname()[0]
        s.close()
        return ip
    except Exception:
        return "127.0.0.1"


def battery_info():
    for p in (os.path.join(HOME, "stats", "battery.json"), "/tmp/battery.json"):
        try:
            if os.path.exists(p):
                with open(p) as f:
                    return json.load(f)
        except Exception:
            pass
    try:
        out = subprocess.run(["termux-battery-status"], capture_output=True,
                             text=True, timeout=5)
        if out.returncode == 0 and out.stdout.strip():
            return json.loads(out.stdout)
    except Exception:
        pass
    return {}


def proc_running(pattern):
    try:
        out = subprocess.run(["pgrep", "-f", pattern], capture_output=True,
                             text=True, timeout=5)
        return bool(out.stdout.strip())
    except Exception:
        return False


def tunnel_info():
    host = ""
    cfg = os.path.join(HOME, ".cloudflared", "config.yml")
    try:
        if os.path.exists(cfg):
            with open(cfg) as f:
                m = re.search(r"hostname:\s*(\S+)", f.read())
                if m:
                    host = m.group(1).strip()
    except Exception:
        pass
    running = proc_running("cloudflared")
    url = f"https://{host}" if host else ""
    return {"hostname": host, "url": url, "running": running}


def username():
    try:
        return getpass.getuser()
    except Exception:
        return "user"


@app.route("/health")
def health():
    return jsonify(status="ok")


@app.route("/stats")
def stats():
    return jsonify({
        "cpu_percent": cpu_percent(),
        "cpu_count": os.cpu_count() or 1,
        "load": load_avg(),
        "mem": mem_info(),
        "disk": disk_info(),
        "net": net_info(),
        "io": disk_io(),
        "uptime": uptime_info(),
        "battery": battery_info(),
        "services": {name: proc_running(cfg["pattern"]) for name, cfg in SERVICES.items()},
        "tunnel": tunnel_info(),
        "local_ip": local_ip(),
        "time": int(time.time()),
    })


@app.route("/info")
def info():
    user = username()
    ip = local_ip()
    tun = tunnel_info()
    return jsonify({
        "user": user,
        "local_ip": ip,
        "sshd_port": SSHD_PORT,
        "ssh_cmd": f"ssh -p {SSHD_PORT} {user}@{ip}",
        "sftp_cmd": f"sftp -P {SSHD_PORT} {user}@{ip}",
        "tunnel": tun,
        "routes": {
            "files": "/files/",
            "downloads": "/downloads/",
            "stats": "/stats/",
            "cam": "/cam/",
            "terminal": "/terminal/",
            "battery": "/battery.json",
        },
    })


@app.route("/add-download", methods=["POST"])
def add_download():
    data = request.get_json(silent=True) or {}
    url = (data.get("url") or "").strip()

    if not url:
        return jsonify(error="No URL provided"), 400
    if not (url.startswith("http://") or url.startswith("https://") or url.startswith("magnet:")):
        return jsonify(error="URL must start with http://, https://, or magnet:"), 400

    payload = {
        "jsonrpc": "2.0",
        "id": "dashboard",
        "method": "aria2.addUri",
        "params": [f"token:{ARIA2_SECRET}", [url], {"dir": DOWNLOAD_DIR}],
    }

    try:
        resp = requests.post(ARIA2_RPC_URL, json=payload, timeout=10)
        resp.raise_for_status()
        result = resp.json()
    except requests.RequestException as e:
        return jsonify(error=f"Could not reach aria2: {e}"), 502

    if "error" in result:
        return jsonify(error=result["error"].get("message", "aria2 error")), 502

    return jsonify(status="queued", gid=result.get("result"))


@app.route("/restart/<service>", methods=["POST"])
def restart(service):
    cfg = SERVICES.get(service)
    if not cfg:
        return jsonify(error=f"Unknown service '{service}'"), 404

    try:
        subprocess.run(cfg["stop"], timeout=10)
    except Exception:
        pass  # stop failing (e.g. wasn't running) shouldn't block the restart

    time.sleep(1)

    try:
        if "start_bg" in cfg:
            subprocess.Popen(
                cfg["start_bg"],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                start_new_session=True,
            )
        else:
            subprocess.run(cfg["start"], timeout=10)
    except Exception as e:
        return jsonify(error=f"Restart failed: {e}"), 500

    return jsonify(status="restarted", service=service)


if __name__ == "__main__":
    # 127.0.0.1 only — do not bind 0.0.0.0, nginx handles external access + auth
    app.run(host="127.0.0.1", port=5000)
