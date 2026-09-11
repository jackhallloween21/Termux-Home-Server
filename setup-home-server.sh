#!/data/data/com.termux/files/usr/bin/bash
#
# setup-home-server.sh
# One-shot installer for a Termux-based home server:
# SSH/SFTP, aria2 + AriaNg, yt-dlp, Glances stats, nginx reverse proxy,
# a quick-actions dashboard, and a cloudflared binary (tunnel setup is manual).
#
# Run with: bash setup-home-server.sh
#
set -e

HOME_DIR="$HOME"
PREFIX_DIR="$PREFIX"
NGINX_HTML="$PREFIX_DIR/share/nginx/html"
NGINX_CONF="$PREFIX_DIR/etc/nginx/nginx.conf"
NGINX_AUTH_DIR="$PREFIX_DIR/etc/nginx/auth"
BOOT_DIR="$HOME_DIR/.termux/boot"

echo "=============================================="
echo "  Termux Home Server — setup"
echo "=============================================="
echo

# ---------------------------------------------------------------
# 1. Packages
# ---------------------------------------------------------------
echo "--> Updating package lists..."
pkg update -y && pkg upgrade -y

echo "--> Installing core packages..."
pkg install -y openssh nginx aria2 python python-pip git wget curl openssl-tool termux-api clang libffi ttyd procps iproute2

echo "--> Installing Python tools (yt-dlp, flask, requests)..."
# NOTE: Do NOT run `pip install --upgrade pip` on Termux — Termux manages
# pip via the `python-pip` pkg, and trying to upgrade it aborts with:
#   "ERROR: Installing pip is forbidden, this will break the python-pip package"
# Just install the tools with the system pip.
python -m pip install --no-cache-dir -U yt-dlp flask requests

echo "--> Installing Glances (via pkg, NOT pip)..."
# `pip install "glances[web]"` fails on Termux / Python 3.14 because
# fastapi -> pydantic-core needs a Rust (maturin) build for target
# aarch64-unknown-linux-android, which rustup does not support:
#   "Target triple not supported by rustup: aarch64-unknown-linux-android"
# The Termux repo ships a prebuilt glances, so prefer that and never let
# a glances failure kill the whole setup (set -e is on).
if ! pkg install -y glances; then
  echo "    pkg glances failed, trying pip without the [web] extra (avoids fastapi/pydantic-core)..."
  python -m pip install --no-cache-dir -U glances || echo "    WARNING: glances install failed — continuing without it."
fi

# ---------------------------------------------------------------
# 2. Storage + wake lock
# ---------------------------------------------------------------
echo
echo "--> Requesting storage access (accept the Android permission prompt)..."
termux-setup-storage
sleep 2

echo "--> Acquiring wake lock (prevents Android from killing background jobs)..."
termux-wake-lock

# ---------------------------------------------------------------
# 3. Directories
# ---------------------------------------------------------------
echo
echo "--> Creating directories..."
mkdir -p "$HOME_DIR/downloads"
mkdir -p "$HOME_DIR/stats"
mkdir -p "$HOME_DIR/api"
mkdir -p "$BOOT_DIR"
mkdir -p "$NGINX_AUTH_DIR"
mkdir -p "$NGINX_HTML"

# ---------------------------------------------------------------
# 4. Secrets / credentials
# ---------------------------------------------------------------
echo
echo "--> Generating aria2 RPC secret..."
ARIA2_SECRET="$(openssl rand -hex 16)"

echo
echo "--> Set up basic auth for protected routes (/cam/, /stats/, /downloads/, /files/, /api/)"
read -rp "    Username [admin]: " AUTH_USER
AUTH_USER="${AUTH_USER:-admin}"
while true; do
  read -rsp "    Password: " AUTH_PASS
  echo
  read -rsp "    Confirm password: " AUTH_PASS_CONFIRM
  echo
  if [ "$AUTH_PASS" = "$AUTH_PASS_CONFIRM" ] && [ -n "$AUTH_PASS" ]; then
    break
  fi
  echo "    Passwords didn't match or were empty — try again."
done

printf "%s:%s\n" "$AUTH_USER" "$(openssl passwd -apr1 "$AUTH_PASS")" > "$NGINX_AUTH_DIR/.htpasswd"
echo "    Wrote $NGINX_AUTH_DIR/.htpasswd"

echo
read -rp "--> Cloudflare tunnel name [homeserver]: " TUNNEL_NAME
TUNNEL_NAME="${TUNNEL_NAME:-homeserver}"

# ---------------------------------------------------------------
# 5. AriaNg (web UI for aria2)
# ---------------------------------------------------------------
echo
if [ ! -d "$HOME_DIR/AriaNg" ]; then
  echo "--> Cloning AriaNg..."
  git clone --depth 1 https://github.com/mayswind/AriaNg.git "$HOME_DIR/AriaNg"
else
  echo "--> AriaNg already present, skipping clone."
fi

# ---------------------------------------------------------------
# 6. API backend (app.py)
# ---------------------------------------------------------------
echo
echo "--> Writing API backend (~/api/app.py)..."
cat > "$HOME_DIR/api/app.py" <<'PYEOF'
#!/data/data/com.termux/files/usr/bin/python
"""
Small local backend for the home server dashboard's quick-actions panel.
Binds to 127.0.0.1 only -- nginx proxies /api/ to this and applies basic auth.
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

ARIA2_RPC_URL = "http://127.0.0.1:6800/jsonrpc"
ARIA2_SECRET = "__ARIA2_SECRET__"
DOWNLOAD_DIR = "__DOWNLOAD_DIR__"
HOME = "__HOME__"
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
            "--log=__HOME__/aria2.log",
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
        "start_bg": ["cloudflared", "tunnel", "run", "__TUNNEL_NAME__"],
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
        with open("/proc/uptime") as f2:
            total = int(float(f2.read().split()[0]))
        return {"seconds": total, "human": human}
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
        pass

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
    app.run(host="127.0.0.1", port=5000)
PYEOF

# Substitute real values into app.py
sed -i "s|__ARIA2_SECRET__|$ARIA2_SECRET|g" "$HOME_DIR/api/app.py"
sed -i "s|__DOWNLOAD_DIR__|$HOME_DIR/downloads|g" "$HOME_DIR/api/app.py"
sed -i "s|__HOME__|$HOME_DIR|g" "$HOME_DIR/api/app.py"
sed -i "s|__TUNNEL_NAME__|$TUNNEL_NAME|g" "$HOME_DIR/api/app.py"

# ---------------------------------------------------------------
# 7. Battery/thermal logger
# ---------------------------------------------------------------
echo "--> Writing battery logger (~/stats/battery.sh)..."
cat > "$HOME_DIR/stats/battery.sh" <<'BATEOF'
#!/data/data/com.termux/files/usr/bin/bash
while true; do
  termux-battery-status > "$HOME/stats/battery.json" 2>/dev/null
  sleep 30
done
BATEOF
chmod +x "$HOME_DIR/stats/battery.sh"

# ---------------------------------------------------------------
# 8. nginx config
# ---------------------------------------------------------------
echo "--> Writing nginx config..."
cat > "$NGINX_CONF" <<'NGINXEOF'
worker_processes 1;
pid __PREFIX__/var/run/nginx.pid;

events {
    worker_connections 64;
}

http {
    include       __PREFIX__/etc/nginx/mime.types;
    default_type  application/octet-stream;
    sendfile      on;

    server {
        listen 8080;

        # Dashboard homepage
        location / {
            root __NGINX_HTML__;
            index index.html;
        }

        # System stats (Glances)
        location /stats/ {
            auth_basic "Restricted";
            auth_basic_user_file __AUTH_FILE__;
            proxy_pass http://127.0.0.1:61208/;
        }

        # AriaNg static UI
        location /downloads/ {
            auth_basic "Restricted";
            auth_basic_user_file __AUTH_FILE__;
            alias __HOME__/AriaNg/;
            index index.html;
        }

        # aria2 RPC endpoint (used by AriaNg's JS, configure secret in its UI)
        location /rpc/ {
            auth_basic "Restricted";
            auth_basic_user_file __AUTH_FILE__;
            proxy_pass http://127.0.0.1:6800/;
        }

        # Camera / mic (IP Webcam app)
        location /cam/ {
            auth_basic "Restricted";
            auth_basic_user_file __AUTH_FILE__;
            proxy_pass http://127.0.0.1:8080/;
        }

        # Raw file browser
        location /files/ {
            auth_basic "Restricted";
            auth_basic_user_file __AUTH_FILE__;
            alias __HOME__/downloads/;
            autoindex on;
        }

        # Battery/thermal JSON
        location /battery.json {
            auth_basic "Restricted";
            auth_basic_user_file __AUTH_FILE__;
            alias __HOME__/stats/battery.json;
        }

        # Dashboard quick-actions API
        location /api/ {
            auth_basic "Restricted";
            auth_basic_user_file __AUTH_FILE__;
            proxy_pass http://127.0.0.1:5000/;
        }

        # Web terminal (ttyd, behind same auth)
        location /terminal/ {
            auth_basic "Restricted";
            auth_basic_user_file __AUTH_FILE__;
            proxy_pass http://127.0.0.1:7681/;
            proxy_http_version 1.1;
            proxy_set_header Upgrade $http_upgrade;
            proxy_set_header Connection "upgrade";
        }
    }
}
NGINXEOF

sed -i "s|__PREFIX__|$PREFIX_DIR|g" "$NGINX_CONF"
sed -i "s|__NGINX_HTML__|$NGINX_HTML|g" "$NGINX_CONF"
sed -i "s|__AUTH_FILE__|$NGINX_AUTH_DIR/.htpasswd|g" "$NGINX_CONF"
sed -i "s|__HOME__|$HOME_DIR|g" "$NGINX_CONF"

# ---------------------------------------------------------------
# 9. cloudflared binary
# ---------------------------------------------------------------
echo
echo "--> Installing cloudflared binary..."
ARCH="$(uname -m)"
case "$ARCH" in
  aarch64) CF_ARCH="arm64" ;;
  armv7l|armv8l) CF_ARCH="arm" ;;
  x86_64) CF_ARCH="amd64" ;;
  *) echo "    Unrecognized architecture '$ARCH' — skipping cloudflared install. Download it manually."; CF_ARCH="" ;;
esac

if [ -n "$CF_ARCH" ]; then
  wget -q -O "$PREFIX_DIR/bin/cloudflared" \
    "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-$CF_ARCH"
  chmod +x "$PREFIX_DIR/bin/cloudflared"
  echo "    Installed cloudflared ($CF_ARCH)."
fi

# ---------------------------------------------------------------
# 10. Boot script
# ---------------------------------------------------------------
echo
echo "--> Writing boot script (~/.termux/boot/start-server.sh)..."
cat > "$BOOT_DIR/start-server.sh" <<'BOOTEOF'
#!/data/data/com.termux/files/usr/bin/bash

termux-wake-lock

LOG="$HOME/boot-log.txt"
echo "=== Boot start: $(date) ===" >> "$LOG"

sleep 10

sshd
echo "sshd started" >> "$LOG"

aria2c --enable-rpc --rpc-listen-all --rpc-listen-port=6800 \
  --dir="__HOME__/downloads" --daemon=true --rpc-secret="__ARIA2_SECRET__" \
  --log="__HOME__/aria2.log" --log-level=warn
echo "aria2 started" >> "$LOG"

glances -w --bind 0.0.0.0 --port 61208 >> "__HOME__/glances.log" 2>&1 &
echo "glances started" >> "$LOG"

"__HOME__/stats/battery.sh" >> "__HOME__/stats/battery.log" 2>&1 &
echo "battery logger started" >> "$LOG"

python "__HOME__/api/app.py" >> "__HOME__/api.log" 2>&1 &
echo "api backend started" >> "$LOG"

ttyd -p 7681 -i 127.0.0.1 bash >> "__HOME__/ttyd.log" 2>&1 &
echo "ttyd started" >> "$LOG"

nginx
echo "nginx started" >> "$LOG"

cloudflared tunnel run "__TUNNEL_NAME__" >> "__HOME__/cloudflared.log" 2>&1 &
echo "cloudflared started" >> "$LOG"

echo "=== Boot finished: $(date) ===" >> "$LOG"
BOOTEOF

sed -i "s|__HOME__|$HOME_DIR|g" "$BOOT_DIR/start-server.sh"
sed -i "s|__ARIA2_SECRET__|$ARIA2_SECRET|g" "$BOOT_DIR/start-server.sh"
sed -i "s|__TUNNEL_NAME__|$TUNNEL_NAME|g" "$BOOT_DIR/start-server.sh"
chmod +x "$BOOT_DIR/start-server.sh"

# ---------------------------------------------------------------
# 11. Save a reference file with generated values (no plaintext password)
# ---------------------------------------------------------------
cat > "$HOME_DIR/server-info.txt" <<INFOEOF
Home server setup complete: $(date)

Basic auth username : $AUTH_USER
Basic auth password : (not stored — you entered it during setup)
aria2 RPC secret     : $ARIA2_SECRET
Cloudflare tunnel    : $TUNNEL_NAME
Dashboard root       : $NGINX_HTML/index.html
AriaNg location      : $HOME_DIR/AriaNg
Downloads folder     : $HOME_DIR/downloads
Boot script          : $BOOT_DIR/start-server.sh
INFOEOF

# ---------------------------------------------------------------
# Done
# ---------------------------------------------------------------
echo
echo "=============================================="
echo "  Setup complete"
echo "=============================================="
echo
echo "Still to do manually:"
echo "  1. Set your SSH login password:  passwd"
echo "  2. Copy your dashboard index.html into: $NGINX_HTML/index.html"
echo "     (the one from our earlier conversation, or your own)"
echo "  3. Install Termux:Boot from F-Droid and open it once"
echo "     so it's allowed to run at device boot."
echo "  4. Disable battery optimization for Termux in Android settings."
echo "  5. Authenticate cloudflared and create the tunnel:"
echo "       cloudflared tunnel login"
echo "       cloudflared tunnel create $TUNNEL_NAME"
echo "       cloudflared tunnel route dns $TUNNEL_NAME your-domain.example.com"
echo "     Then create ~/.cloudflared/config.yml pointing 'service: http://localhost:8080'"
echo "     at the tunnel (see earlier instructions for the exact YAML)."
echo "  6. In AriaNg (open /downloads/ in a browser), set RPC host to your"
echo "     domain, path /rpc/jsonrpc, and secret: $ARIA2_SECRET"
echo
echo "Generated values were saved to: $HOME_DIR/server-info.txt"
echo
echo "To start everything right now without rebooting:"
echo "  bash $BOOT_DIR/start-server.sh"
echo
