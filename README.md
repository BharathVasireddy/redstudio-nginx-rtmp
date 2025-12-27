# Red Studio - Simple NGINX RTMP + HLS

Minimal live streaming server built on the nginx-rtmp-module.

## Quick Start

- RTMP server: `rtmp://<server-ip>/live`
- Stream key: `stream`
- Watch URL: `http://<server-ip>/` (port 80) or `http://<server-ip>:8080/`
- HLS playlist: `http://<server-ip>/hls/stream.m3u8`

## OBS Settings

1) Service: `Custom`
2) Server: `rtmp://<server-ip>/live`
3) Stream key: `stream`

## Local (macOS / Linux)

```bash
./stream-start.sh
```

Watch at `http://localhost:8080/` and stream to:
`rtmp://localhost/live` with stream key `stream`.

## Local (Windows)

Run `stream-start.bat`.

Watch at `http://localhost:8080/` and stream to:
`rtmp://localhost/live` with stream key `stream`.

## Deployment

Push to `main` to deploy via GitHub Actions, or run manually:

```bash
ssh -i key.pem ubuntu@<server-ip> "sudo /var/www/nginx-rtmp-module/deploy.sh"
```

## Oracle Setup (one-time)

```bash
sudo ./setup-oracle.sh
```

## Notes

- HLS is generated directly by NGINX (single bitrate = what you send from OBS).
- Open ports `1935`, `80`, and `8080` in Oracle Cloud.
