# Red Studio - Simple NGINX RTMP + HLS

Minimal live streaming server built on the nginx-rtmp-module.

## Quick Start

- RTMP server: `rtmp://<server-ip>/ingest`
- Stream key: set in `/admin` (Ingest Settings)
- Watch URL: `http://<server-ip>/` (port 80) or `http://<server-ip>:8080/`
- HLS playlist: `http://<server-ip>/hls/stream.m3u8`

Setup docs by OS: `docs/SETUP.md`

## Quick Checklist (Before Going Live)

- In `/admin`, set a strong **Ingest Key** and click **Save & Apply**.
- OBS → Server: `rtmp://ingest.<your-domain>/ingest`
- OBS → Stream Key: the **Ingest Key** from `/admin`
- Cloudflare: `ingest.*` is **DNS only** (grey cloud)
- Oracle firewall: ports `1935`, `80`, `8080` are open
- Multistream toggles: use **Save & Apply** (restarts NGINX briefly)
- YouTube: confirm the correct stream event is selected and “Go Live” if auto-start is off

## OBS Settings

1) Service: `Custom`
2) Server: `rtmp://<server-ip>/ingest`
3) Stream key: from `/admin` → Ingest Settings

Recommended encoder settings (safe defaults):
- Rate control: CBR
- Bitrate: 3500–6000 kbps (start at 3500 on Oracle Free)
- Keyframe interval: 2 seconds
- Preset: veryfast (x264) / hardware if stable
- Audio: 128–192 kbps AAC

## Local (macOS / Linux)

```bash
chmod +x scripts/setup-local.sh
./scripts/setup-local.sh --force-stop
```

Or start manually:

```bash
./stream-start.sh
```

Watch at `http://localhost:8080/` and stream to:
`rtmp://localhost/ingest` with the stream key from `/admin` (or leave blank if you haven't set one yet).

Stop (macOS/Linux):

```bash
chmod +x scripts/stop-local.sh
./scripts/stop-local.sh
```

## Local (Windows)

Recommended:

```
scripts\setup-local.bat -ForceStop
```

If PowerShell blocks scripts:

```
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\setup-local.ps1 -ForceStop
```

If the admin UI does not load, the script will try to install Python via `winget`/`choco`. If those are missing, it will download the official installer via PowerShell. If it still fails, install Python 3 from https://www.python.org/downloads/ and disable the Windows Store "App execution aliases" for python.

If you enable YouTube (or other restreams) on Windows and apply fails, make sure Python is installed and `nginx.exe` is present in the repo root.

Or run `stream-start.bat`.

Watch at `http://localhost:8080/` and stream to:
`rtmp://localhost/ingest` with the stream key from `/admin` (or leave blank if you haven't set one yet).

Stop (Windows):

```
scripts\stop-local.bat
```

Diagnostics:

```bash
chmod +x scripts/doctor-local.sh
./scripts/doctor-local.sh
```

```
scripts\doctor-local.bat
```

## Deployment

Push to `main` to deploy via GitHub Actions, or run manually:

```bash
ssh -i key.pem ubuntu@<server-ip> "sudo /var/www/nginx-rtmp-module/deploy.sh"
```

## Multistream Admin

- Admin UI: `https://live.cloud9digital.in/admin/`
- Configure the ingest key in **Ingest Settings** (used by OBS).
- Configure destinations, then Save & Apply to restream.
- Credentials are stored on the server at `data/admin.credentials` (created on first deploy).
- Optional: set GitHub secrets `ADMIN_USER` and `ADMIN_PASSWORD` to override.
- UI login uses a session cookie (no browser popup).

## Embedding

Use `/admin` → **Embed Options** to generate the embed code or HLS URL.

Embed options:
- Full page: `https://<your-domain>/`
- Player-only: `https://<your-domain>/embed.html?controls=1&badge=1&stats=1&muted=1`
- Direct HLS: `https://<your-domain>/hls/stream.m3u8`

Responsive iframe example:

```html
<div style="position:relative;padding-top:56.25%;">
  <iframe
    src="https://live.example.com/embed.html?controls=1&badge=1&stats=1&muted=1"
    style="position:absolute;inset:0;width:100%;height:100%;border:0;"
    allow="autoplay; fullscreen; picture-in-picture"
    allowfullscreen
  ></iframe>
</div>
```

Fixed size example:

```html
<iframe
  src="https://live.example.com/embed.html?controls=1&badge=1&stats=0&muted=0"
  width="100%"
  height="560"
  style="border:0;"
  allow="autoplay; fullscreen; picture-in-picture"
  allowfullscreen
></iframe>
```

## Ingest Security (Simple + Secure)

- Only the **Ingest Key** can publish (enforced by `on_publish`).
- Change the key in `/admin` if it ever leaks.
- Only one encoder can publish at a time (by design).

## Domain (Cloudflare)

Recommended setup:

- `live.cloud9digital.in` (website + HLS): **Proxied** (orange cloud)
- `ingest.cloud9digital.in` (RTMP ingest): **DNS only** (grey cloud)

OBS settings:

- Server: `rtmp://ingest.cloud9digital.in/ingest`
- Stream key: from `/admin` → Ingest Settings

Player URL:

- `https://live.cloud9digital.in/`

Note: If you keep everything DNS only, the site will be HTTP unless you install SSL on the server.

## Oracle Setup (one-time)

```bash
sudo ./setup-oracle.sh
```

## Notes

- HLS is generated directly by NGINX (single bitrate = what you send from OBS).
- Open ports `1935`, `80`, and `8080` in Oracle Cloud.
- Multistream changes require a reconnect/restart to take effect (few seconds).
- `/stat` only shows publishers on the active worker (repo defaults to 1 worker).
- Oracle Free resources are limited; avoid heavy CPU encodes on the server.

## Streaming Flow (Which One Should I Use?)

Best (recommended):

```
OBS -> Oracle ingest -> (restream) YouTube/Facebook/Twitch
```

Why: one upload from your internet, most stable.

Alternative (local relay):

```
OBS -> localhost -> (restream) YouTube + Oracle ingest
```

Warning: uses one upload per destination from your home internet.

## Troubleshooting

- OBS can’t connect:
  - Make sure the server URL is `rtmp://ingest.<your-domain>/ingest` (not `/live`).
  - Ensure the stream key matches the **Ingest Settings** in `/admin`.
  - Confirm Cloudflare for `ingest.*` is **DNS only** (grey cloud).
  - Check Oracle firewall allows port `1935`.
- OBS shows "Already publishing":
  - Only one encoder can publish at a time. Stop the other encoder or wait 10–30s.
- Stream shows on site but not on YouTube:
  - Toggle YouTube on in `/admin`, then **Save & Apply** (restart is required).
  - Wait 30–60 seconds for YouTube to show “Receiving.”
- YouTube keeps receiving after toggle off:
  - Changes take effect on reconnect. Use **Save & Apply** with restart enabled.
- Stream is reconnecting/buffering:
  - Reduce bitrate (e.g., 6000 → 3500 kbps).
  - Use a stable encoder preset and CBR if possible.
  - Ensure server CPU is not saturated (Oracle Free is limited).
- Stream appears but is pixelated:
  - Increase bitrate or adjust encoder settings (keyframe interval 2s, CBR).
- Audio muted on refresh:
  - Mobile browsers require user interaction. Tap Play to unmute.
- Mobile autoplay not working:
  - Expected behavior on iOS/Android. Use the Play button.
- Admin login issues:
  - Use credentials from `data/admin.credentials`.
  - Hard refresh `/admin` after deploy.
- Apply shows HTTP 520/521:
  - The server is restarting. Wait a few seconds; the UI will recover.
- /stat shows 0 clients:
  - Ensure `worker_processes 1` (default in this repo).
- Stream shows on site but not on YouTube:
  - Toggle YouTube on in `/admin`, then **Save & Apply**.
  - Wait 30–60 seconds for YouTube to show “Receiving.”
- `/stat` shows 0 clients:
  - Make sure nginx is running with `worker_processes 1` (default in this repo).
