#!/data/data/com.termux/files/usr/bin/python
"""
Small local backend for the home server dashboard's quick-actions panel.
Binds to 127.0.0.1 only — nginx proxies /api/ to this and applies basic auth,
so this process should never be exposed directly.
"""

import subprocess
import time
import requests
from flask import Flask, request, jsonify

app = Flask(__name__)

# ---- config ----
ARIA2_RPC_URL = "http://127.0.0.1:6800/jsonrpc"
ARIA2_SECRET = "yourtoken"          # must match your aria2c --rpc-secret
DOWNLOAD_DIR = "/data/data/com.termux/files/home/downloads"

# Commands to stop/start each managed service.
# Using pkill by process name/pattern, then relaunching the same command
# your boot script uses. Keep these in sync with start-server.sh.
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
            "--log=/data/data/com.termux/files/home/aria2.log",
            "--log-level=warn",
        ],
    },
    "glances": {
        "stop": ["pkill", "-f", "glances"],
        "start_bg": ["glances", "-w", "--bind", "0.0.0.0", "--port", "61208"],
    },
    "cloudflared": {
        "stop": ["pkill", "-f", "cloudflared"],
        "start_bg": ["cloudflared", "tunnel", "run", "homeserver"],
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
