# Oracle Server + Local Usage Guide

This guide shows how to deploy the same repo on a new Oracle Cloud VM and how to run it locally on macOS/Linux and Windows.

## Oracle Cloud (New Server)

### 1) Provision and open ports

- Open ports `1935`, `80`, `443`, `8080` in your Oracle Security List/NSG.

### 2) Clone and install

```bash
ssh -i /path/to/key ubuntu@<server-ip>

cd /var/www
sudo apt-get update
sudo apt-get install -y git python3
git clone https://github.com/BharathVasireddy/redstudio-nginx-rtmp.git
cd redstudio-nginx-rtmp
sudo ./setup-oracle.sh
sudo ./deploy.sh
```

### 3) Admin login and ingest key

- Admin UI: `https://live.<your-domain>/admin/`
- Credentials: `data/admin.credentials` on the server (or set `ADMIN_USER`/`ADMIN_PASSWORD` in GitHub Secrets).
- In **Ingest Settings**, generate a stream key and click **Save & Apply**.

### 4) OBS settings (production)

- Server: `rtmp://ingest.<your-domain>/ingest`
- Stream Key: the key shown in `/admin` → Ingest Settings

### 5) Player URLs

- Website: `https://live.<your-domain>/`
- HLS: `https://live.<your-domain>/hls/stream.m3u8`

### 6) GitHub Actions (optional)

If you want auto-deploy on every push to `main`, set these GitHub Secrets:

- `ORACLE_HOST` (server IP)
- `ORACLE_USER` (usually `ubuntu`)
- `ORACLE_SSH_KEY` (private key content)
- `ORACLE_SSH_KEY_PASSPHRASE` (optional)
- `ADMIN_USER`, `ADMIN_PASSWORD` (optional)

## Local Usage (macOS / Linux)

### 1) Prerequisites

- `nginx` installed and available in your PATH.
- `python3` installed.

### 2) Start the server

```bash
./stream-start.sh
```

### 3) Stream locally

- Dashboard: `http://localhost:8080/`
- Server: `rtmp://localhost/ingest`
- Stream key: any value (local does not enforce ingest keys by default)

### 4) Stop the server

```bash
./stream-stop.sh
```

## Local Usage (Windows)

### 1) Start the server

Double-click:

```
stream-start.bat
```

### 2) Stream locally

- Dashboard: `http://localhost:8080/`
- Server: `rtmp://localhost/ingest`
- Stream key: any value (local does not enforce ingest keys by default)

### 3) Stop the server

```
stream-stop.bat
```

## Notes

- Production ingest keys are enforced via `on_publish`.
- Local config is minimal and does not enforce ingest keys.
