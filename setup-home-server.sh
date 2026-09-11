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
pkg install -y openssh nginx aria2 python git wget curl openssl-tool termux-api

echo "--> Installing Python tools (yt-dlp, flask, requests, glances)..."
pip install --upgrade pip
pip install yt-dlp flask requests "glances[web]"

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

import subprocess
import time
import requests
from flask import Flask, request, jsonify

app = Flask(__name__)

ARIA2_RPC_URL = "http://127.0.0.1:6800/jsonrpc"
ARIA2_SECRET = "__ARIA2_SECRET__"
DOWNLOAD_DIR = "__DOWNLOAD_DIR__"

SERVICES = {
    "nginx": {
        "stop": ["nginx", "-s", "stop"],
        "start": ["nginx"],
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
    },
    "glances": {
        "stop": ["pkill", "-f", "glances"],
        "start_bg": ["glances", "-w", "--bind", "0.0.0.0", "--port", "61208"],
    },
    "cloudflared": {
        "stop": ["pkill", "-f", "cloudflared"],
        "start_bg": ["cloudflared", "tunnel", "run", "__TUNNEL_NAME__"],
    },
}


@app.route("/health")
def health():
    return jsonify(status="ok")


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
