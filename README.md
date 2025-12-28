# Red Studio - Simple NGINX RTMP + HLS

Minimal live streaming server built on the nginx-rtmp-module.

## Quick Start

- RTMP server: `rtmp://<server-ip>/ingest`
- Stream key: set in `/admin` (Ingest Settings)
- Watch URL: `http://<server-ip>/` (port 80) or `http://<server-ip>:8080/`
- HLS playlist: `http://<server-ip>/hls/stream.m3u8`

## OBS Settings

1) Service: `Custom`
2) Server: `rtmp://<server-ip>/ingest`
3) Stream key: from `/admin` → Ingest Settings

## Local (macOS / Linux)

```bash
./stream-start.sh
```

Watch at `http://localhost:8080/` and stream to:
`rtmp://localhost/ingest` with the stream key from `/admin` (or leave blank if you haven't set one yet).

## Local (Windows)

Run `stream-start.bat`.

Watch at `http://localhost:8080/` and stream to:
`rtmp://localhost/ingest` with the stream key from `/admin` (or leave blank if you haven't set one yet).

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

## Troubleshooting

- OBS can’t connect:
  - Make sure the server URL is `rtmp://ingest.<your-domain>/ingest` (not `/live`).
  - Ensure the stream key matches the **Ingest Settings** in `/admin`.
  - Confirm Cloudflare for `ingest.*` is **DNS only** (grey cloud).
  - Check Oracle firewall allows port `1935`.
- Stream shows on site but not on YouTube:
  - Toggle YouTube on in `/admin`, then **Save & Apply**.
  - Wait 30–60 seconds for YouTube to show “Receiving.”
- `/stat` shows 0 clients:
  - Make sure nginx is running with `worker_processes 1` (default in this repo).
