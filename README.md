# Termux Home Server

Turn an old Android phone into a home server: SSH/SFTP access, a downloader
(aria2 + yt-dlp), a live camera/mic feed, system stats, and a web dashboard —
all reachable from outside your home network via a Cloudflare Tunnel.

---

## Contents

- [What you get](#what-you-get)
- [Requirements](#requirements)
- [Quick start](#quick-start)
- [Manual setup steps](#manual-setup-steps-required-after-the-script)
  1. [SSH password](#1-ssh-password)
  2. [Dashboard homepage](#2-dashboard-homepage)
  3. [Termux:Boot](#3-termuxboot)
  4. [Battery optimization](#4-battery-optimization)
  5. [Camera / mic app](#5-camera--mic-app)
  6. [Cloudflare Tunnel](#6-cloudflare-tunnel)
  7. [AriaNg RPC settings](#7-ariang-rpc-settings)
- [Services and ports](#services-and-ports)
- [Routes](#routes)
- [File structure](#file-structure)
- [Using it day to day](#using-it-day-to-day)
- [Starting, stopping, restarting](#starting-stopping-restarting)
- [Security notes](#security-notes)
- [Troubleshooting](#troubleshooting)

---

## What you get

| Feature | Tool | Access |
|---|---|---|
| Remote shell | OpenSSH (`sshd`) | `ssh -p 8022 user@phone-ip` |
| File transfer | SFTP (built into sshd) | `sftp -P 8022 user@phone-ip` |
| Downloads | aria2 + AriaNg web UI | `https://your-domain/downloads/` |
| Video/audio downloader | yt-dlp | via SSH, or wired into aria2 |
| Camera / mic as webcam | IP Webcam (Android app) | `https://your-domain/cam/` |
| System stats | Glances | `https://your-domain/stats/` |
| Battery / thermal | Termux:API | `https://your-domain/battery.json` |
| File browser | nginx autoindex | `https://your-domain/files/` |
| Dashboard + quick actions | Static HTML + Flask API | `https://your-domain/` |
| External access | Cloudflare Tunnel | no port forwarding, no open ports |

---

## Requirements

- An Android phone (older hardware is fine — this is a light footprint)
- [Termux](https://f-droid.org/packages/com.termux/) from **F-Droid**
  (not the Play Store build — it's outdated and broken)
- [Termux:Boot](https://f-droid.org/packages/com.termux.boot/) from F-Droid
- [Termux:API](https://f-droid.org/packages/com.termux.api/) from F-Droid
- An **IP Webcam** app (Play Store) for the camera/mic feed
- A domain name + free [Cloudflare](https://dash.cloudflare.com/) account
  (for the tunnel)
- The phone kept charging, on Wi-Fi, with battery optimization disabled for Termux

---

## Quick start

1. Install Termux, Termux:Boot, and Termux:API from F-Droid, then open each once.
2. Download `setup-home-server.sh` onto the phone (e.g. via `curl`/`wget`, or
   transfer with `termux-setup-storage` + a file manager into `~/downloads/`,
   then `cd` there).
3. Run it:
   ```bash
   bash setup-home-server.sh
   ```
4. It will:
   - Install all packages (`openssh`, `nginx`, `aria2`, `python`, `git`,
     `termux-api`, `yt-dlp`, `flask`, `requests`, `glances`)
   - Ask for storage permission
   - Ask you to set a **basic auth username/password** (protects most routes)
   - Ask for a **Cloudflare tunnel name** (default `homeserver`)
   - Generate a random **aria2 RPC secret**
   - Clone **AriaNg** (the aria2 web UI)
   - Write `nginx.conf`, the Flask API backend, the battery logger, and the
     boot script — all pre-wired with the values above
   - Download the right **cloudflared** binary for your phone's CPU
   - Save a summary to `~/server-info.txt`
5. Finish the **manual steps** below — the script can't do these safely or
   they require interactive browser logins.

---

## Manual setup steps (required after the script)

### 1. SSH password

The script doesn't set this for you. Run:

```bash
passwd
```

and choose a strong password. This is what you'll use to `ssh`/`sftp` into
the phone. (Optionally switch to key-based auth later by adding a public key
to `~/.ssh/authorized_keys` and disabling password auth in
`$PREFIX/etc/ssh/sshd_config`.)

### 2. Dashboard homepage

Copy the dashboard `index.html` into nginx's web root:

```bash
cp index.html $PREFIX/share/nginx/html/index.html
nginx -s reload
```

This is the landing page at `/` with links and live status dots for every
service, plus the quick-actions panel (paste a URL to send to aria2, restart
individual services).

### 3. Termux:Boot

Open the **Termux:Boot** app once — just launching it grants it permission to
run scripts in `~/.termux/boot/` when the phone reboots. The setup script
already placed `start-server.sh` there.

### 4. Battery optimization

In Android Settings → Apps → Termux (and Termux:Boot) → Battery, set to
**Unrestricted** / disable optimization. On MIUI, Samsung, and similar
skins, also check for a separate "auto-start" or "protected apps" list and
whitelist Termux there — stock battery settings alone often aren't enough.

Keep the phone plugged in; this is meant to run as an always-on device, not
a daily-driver phone.

### 5. Camera / mic app

Install **IP Webcam** from the Play Store, open it, and tap "Start server."
By default it serves on port `8080` locally, which is what the nginx `/cam/`
route proxies to. Check the app's own settings for resolution, audio, and
whether it needs to stay foregrounded (usually yes — keep it running).

### 6. Cloudflare Tunnel

These steps need a browser login, so they're manual:

```bash
cloudflared tunnel login
cloudflared tunnel create homeserver        # match the name you gave setup.sh
cloudflared tunnel route dns homeserver home.yourdomain.com
```

Then create `~/.cloudflared/config.yml`:

```yaml
tunnel: <tunnel-id-from-the-create-step>
credentials-file: /data/data/com.termux/files/home/.cloudflared/<tunnel-id>.json
ingress:
  - hostname: home.yourdomain.com
    service: http://localhost:8080
  - service: http_status:404
```

Test it: `cloudflared tunnel run homeserver`, then visit
`https://home.yourdomain.com` from any device.

Once confirmed working, it's already wired into your boot script to start
automatically.

### 7. AriaNg RPC settings

Open `https://home.yourdomain.com/downloads/` in a browser, go to AriaNg's
**Settings → RPC**, and set:

- **Protocol:** `https`
- **Host:** `home.yourdomain.com`
- **Port:** `443`
- **RPC path:** `/rpc/jsonrpc`
- **Secret:** the value printed at the end of `setup-home-server.sh`, also
  saved in `~/server-info.txt`

This only needs to be set once per browser (AriaNg stores it locally).

---

## Services and ports

| Service | Local port | Bound to |
|---|---|---|
| sshd | 8022 | all interfaces |
| aria2 RPC | 6800 | localhost (proxied by nginx) |
| Glances web | 61208 | all interfaces (behind nginx auth) |
| IP Webcam | 8080 | all interfaces (behind nginx auth) |
| Flask API backend | 5000 | **localhost only** |
| nginx | 8080 | all interfaces — the single front door |

Only nginx (8080) and sshd (8022) should ever need to be reachable outside
the phone; the Cloudflare Tunnel only forwards to nginx's port 8080.

## Routes

All routes below are served through nginx at `https://home.yourdomain.com/…`:

| Route | What it is | Auth |
|---|---|---|
| `/` | Dashboard homepage | none |
| `/stats/` | Glances system stats | basic auth |
| `/downloads/` | AriaNg download manager UI | basic auth |
| `/rpc/` | aria2 JSON-RPC endpoint (used by AriaNg's JS) | basic auth |
| `/cam/` | Camera/mic live feed (IP Webcam) | basic auth |
| `/files/` | Raw file browser of `~/downloads/` | basic auth |
| `/battery.json` | Battery/thermal status | basic auth |
| `/api/` | Dashboard quick-actions backend | basic auth |

---

## File structure

```
~/downloads/              # aria2's download directory, also served at /files/
~/AriaNg/                 # AriaNg static web UI (cloned by setup script)
~/api/app.py              # Flask backend for quick-actions panel
~/stats/battery.sh        # background loop writing battery.json every 30s
~/stats/battery.json      # current battery/thermal snapshot
~/.termux/boot/start-server.sh   # runs on every device reboot (Termux:Boot)
~/server-info.txt         # generated secrets/usernames summary
~/boot-log.txt            # log of each boot script run
~/aria2.log
~/glances.log
~/api.log
~/cloudflared.log

$PREFIX/etc/nginx/nginx.conf
$PREFIX/etc/nginx/auth/.htpasswd
$PREFIX/share/nginx/html/index.html   # the dashboard
```

---

## Using it day to day

- **Queue a download:** open the dashboard, paste a URL or magnet link into
  the quick-actions box, click "Send to aria2." Or use AriaNg directly at
  `/downloads/` for more control (pause, prioritize, see speed/ETA).
- **Grab a video with yt-dlp:** simplest path is over SSH —
  `yt-dlp -P ~/downloads "URL"`. It's not wired into the web UI by default
  since that would mean exposing an arbitrary command runner to the internet.
- **Check on the server:** `/stats/` for CPU/RAM/disk/network,
  `/battery.json` for charge level and temperature.
- **Watch the camera:** `/cam/` — also works as a basic audio monitor since
  IP Webcam can stream the mic too, check its in-app settings.
- **Restart something that's acting up:** dashboard quick-actions panel has
  a button per service (nginx, aria2, glances, cloudflared).

## Starting, stopping, restarting

**Start everything without rebooting:**
```bash
bash ~/.termux/boot/start-server.sh
```

**Stop an individual service:**
```bash
pkill -f aria2c
pkill -f glances
pkill -f cloudflared
nginx -s stop
```

**Restart nginx after a config change:**
```bash
nginx -s reload
```

**Check what's running:**
```bash
pgrep -fl 'sshd|aria2c|glances|nginx|cloudflared|app.py'
```

---

## Security notes

- The Flask API backend binds `127.0.0.1` only — it's never reachable except
  through nginx, and nginx puts it behind the same basic auth as everything
  else. Don't change that binding to `0.0.0.0`.
- The aria2 RPC secret and all restart commands live server-side in
  `app.py`, never exposed to the browser beyond what's needed to make the
  request.
- Basic auth protects most routes, but the **dashboard homepage itself
  (`/`) is intentionally public** so the status dots and layout are visible
  before logging in — no sensitive data lives there. If you'd rather lock
  down the whole site, add the same `auth_basic` lines to the `/` location
  block too.
- For stronger protection than a static password, put
  [Cloudflare Access](https://developers.cloudflare.com/cloudflare-one/policies/access/)
  in front of the tunnel — it adds a login page (email OTP, Google, etc.)
  before traffic even reaches the phone.
- Restarting `nginx` from the dashboard briefly drops the very connection
  serving that click — expect a short hang before the page responds again.
- Keep `~/server-info.txt` private; it contains the aria2 RPC secret.

---

## Troubleshooting

**Nothing starts after a reboot**
Check `~/boot-log.txt`. If it's empty or missing, Termux:Boot likely hasn't
been granted permission — open the Termux:Boot app once, confirm any Android
permission prompts, and reboot again.

**Services die after a while / phone seems to "sleep"**
Battery optimization is probably still killing background processes — revisit
[step 4](#4-battery-optimization), including any OEM-specific auto-start or
app-freezing lists (common on Xiaomi/MIUI, Samsung, Huawei).

**Can't reach the dashboard from outside the house**
1. Confirm `cloudflared tunnel run <name>` is actually running:
   `pgrep -fl cloudflared`
2. Check `~/cloudflared.log` for connection errors.
3. Re-verify the DNS route: `cloudflared tunnel route dns <name> <domain>`
4. Confirm nginx is up and listening on 8080: `curl http://127.0.0.1:8080`

**AriaNg shows "Failed to connect to aria2"**
Double check the RPC settings in AriaNg (step 7) — especially the secret and
the `/rpc/jsonrpc` path — and confirm aria2 itself is running:
`pgrep -fl aria2c`.

**Camera feed won't load**
Make sure the IP Webcam app is open and its in-app server is started —
Android may have suspended it in the background even with battery
optimization disabled, since it's a separate app from Termux.

**Basic auth password forgotten**
Regenerate it:
```bash
printf "yourusername:$(openssl passwd -apr1 'newpassword')\n" \
  > $PREFIX/etc/nginx/auth/.htpasswd
nginx -s reload
```

**"Address already in use" when starting a service**
Something's already running on that port. Find and stop it:
```bash
pkill -f <process-name>
```
then restart via the dashboard or manually.
