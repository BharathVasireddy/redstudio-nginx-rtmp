# 🚀 Red Studio - Enterprise Streaming Server

A production-ready **NGINX RTMP** streaming server with **HLS** playback, **Token Security**, **Real Viewer Counts**, and **Analytics**.

Currently deployed on **Oracle Cloud**.

---

## 📋 Quick Reference

| Service | Production (Oracle Cloud) | Local Development (Windows) |
|:---|:---|:---|
| **RTMP Server** | `rtmp://129.153.235.60/live` | `rtmp://localhost/live` |
| **Stream Key** | `stream?user=streamadmin&pass=YOUR_KEY` | Same |
| **Watch URL** | `http://129.153.235.60:8080/` | `http://localhost:8080/` |
| **Auth API** | `http://129.153.235.60:8080/api` | `http://localhost:3000/api` |

---

## 🎬 How to Stream (OBS / vMix)

1.  Open **OBS Studio**.
2.  Go to **Settings > Stream**.
3.  Set **Service** to `Custom`.
4.  **Server**: `rtmp://129.153.235.60/live`
5.  **Stream Key**: `stream?user=streamadmin&pass=YOUR_KEY`
6.  Start Streaming.

> **Note:** The stream key must include `?user=...&pass=...` for authentication.

---

## ✨ Enterprise Features

| Feature | Description |
|:---|:---|
| **Real Viewer Count** | Live count from NGINX `/stat` endpoint |
| **Session Persistence** | Stream duration survives server restarts |
| **Server-Side Tokens** | HLS tokens generated securely on backend |
| **Peak Viewer Tracking** | Tracks max concurrent viewers per stream |
| **Analytics Logging** | Stream events logged to JSON |
| **Video.js Player** | Enterprise-grade live streaming player |

---

## 🔧 API Endpoints

| Endpoint | Description |
|:---|:---|
| `GET /api/stream/status` | Stream status, viewers, uptime |
| `GET /api/token/hls` | Get secure HLS playback URL |
| `GET /api/health` | Server health check |
| `GET /api/analytics` | Stream analytics data |

---

## 🛠️ Deployment

### Zero-Downtime Deployment
Push to `main` branch → GitHub Actions deploys automatically.

GitHub Actions secrets required:
- `ORACLE_HOST`
- `ORACLE_USER`
- `ORACLE_SSH_KEY` (private key)
- `ORACLE_SSH_KEY_PASSPHRASE` (optional)

### Automated Setup (Local Machine)
1) Install the Oracle public key on the server:
   ```bash
   bash scripts/install-ssh-key.sh /Users/bharat/Downloads/ssh-key-2025-12-26.key.pub oracle_user oracle_host
   ```
2) Set GitHub Actions secrets with GitHub CLI:
   ```bash
   GITHUB_REPO=owner/repo \
   ORACLE_HOST=1.2.3.4 \
   ORACLE_USER=ubuntu \
   ORACLE_SSH_KEY_FILE=/Users/bharat/Downloads/ssh-key-2025-12-26.key \
   bash scripts/setup-github-actions.sh
   ```
3) Push to `main` and GitHub Actions will run `deploy.sh` on Oracle.

### Manual Server Control (SSH)
```bash
ssh -i key.key ubuntu@129.153.235.60

# Reload NGINX (Safe)
sudo /usr/local/nginx/sbin/nginx -s reload

# View Logs
tail -f /var/www/nginx-rtmp-module/logs/error.log
```

---

## 💻 Local Development

```powershell
# Start
.\stream-start.bat

# Stop
.\stream-stop.bat
```

Then open `http://localhost:8080/`

---

## 📂 File Structure

```
├── api/                  # Node.js Auth & Stats API
│   ├── server.js         # Enterprise API server
│   ├── session.json      # Persistent stream state
│   └── analytics.json    # Stream analytics
├── conf/nginx.conf       # NGINX Configuration
├── public/               # Frontend Files
│   └── index.html        # Player + Landing Page
└── temp/hls/             # HLS Video Chunks
```

---

## ❓ Troubleshooting

| Issue | Solution |
|:---|:---|
| **Stream "Offline"** | Check OBS connection. Wait 2-3s for HLS. |
| **OBS "Disconnected"** | Check credentials in Stream Key. |
| **Black Screen** | Token expired? Refresh page. |

---

*Last Updated: Dec 2025*

---

## ABR (Multi-Bitrate) HLS Setup

This repo uses FFmpeg to generate multi-bitrate HLS output and a `master.m3u8` playlist.

0. Choose an HLS profile (recommended on Oracle Free Tier):
   - `lowcpu` (default): 1080p + 720p via `scripts/ffmpeg-abr-lowcpu.sh`
   - `high`: 1080p + 720p + 480p via `scripts/ffmpeg-abr.sh`
   Update `api/config.json` (`hls.profile`) and apply the config.
1. Install FFmpeg on Ubuntu:
   ```bash
   sudo apt-get update
   sudo apt-get install -y ffmpeg
   ```
2. Make the ABR script executable:
   ```bash
   chmod +x scripts/ffmpeg-abr.sh
   ```
3. Update the `exec_publish` path in `conf/nginx.conf` to match your repo path:
   ```
   exec_publish /bin/bash /var/www/nginx-rtmp-module/scripts/ffmpeg-abr.sh $name;
   ```
4. Reload NGINX:
   ```bash
   sudo /usr/local/nginx/sbin/nginx -s reload
   ```

The player requests `/hls/master.m3u8` via the token endpoint and will auto-select the best bitrate.
