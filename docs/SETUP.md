# Oracle Server + Local Usage Guide

This guide shows how to deploy the same repo on a new Oracle Cloud VM and how to run it locally on macOS/Linux and Windows.

## Oracle Cloud (First-Time Install)

### 1) Provision and open ports

- Open ports `1935`, `80`, `443`, `8080` in your Oracle Security List/NSG.

### 2) SSH into the VM

```bash
ssh -i /path/to/key ubuntu@<server-ip>
```

### 3) Install base dependencies

```bash
sudo apt-get update
sudo apt-get install -y git python3 curl unzip
```

### 4) Clone and install

```bash
cd /var/www
git clone https://github.com/BharathVasireddy/redstudio-nginx-rtmp.git
cd redstudio-nginx-rtmp
sudo ./setup-oracle.sh
sudo ./deploy.sh
```

`setup-oracle.sh` installs build dependencies, compiles nginx with RTMP, and configures the firewall.

### 5) Admin login and ingest key

- Admin UI: `https://live.<your-domain>/admin/`
- Credentials: `data/admin.credentials` on the server (or set `ADMIN_USER`/`ADMIN_PASSWORD` in GitHub Secrets).
- In **Ingest Settings**, generate a stream key and click **Save & Apply**.

### 6) OBS settings (production)

- Server: `rtmp://ingest.<your-domain>/ingest`
- Stream Key: the key shown in `/admin` → Ingest Settings

### 7) Player URLs

- Website: `https://live.<your-domain>/`
- HLS: `https://live.<your-domain>/hls/stream.m3u8`

### 8) GitHub Actions (optional)

If you want auto-deploy on every push to `main`, set these GitHub Secrets:

- `ORACLE_HOST` (server IP)
- `ORACLE_USER` (usually `ubuntu`)
- `ORACLE_SSH_KEY` (private key content)
- `ORACLE_SSH_KEY_PASSPHRASE` (optional)
- `ADMIN_USER`, `ADMIN_PASSWORD` (optional)

## Local Usage (macOS)

### 1) Clone the repository

```bash
git clone https://github.com/BharathVasireddy/redstudio-nginx-rtmp.git
cd redstudio-nginx-rtmp
```

If you don’t have Git, install it first or download the ZIP from GitHub and extract it.

### 2) Install dependencies

```bash
# Install Homebrew if you don't have it
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

# Install nginx and python
brew install nginx python
```

### 3) Start the server

```bash
chmod +x stream-start.sh
./stream-start.sh
```

### 4) Stream locally

- Dashboard: `http://localhost:8080/`
- Server: `rtmp://localhost/ingest`
- Stream key: any value (local does not enforce ingest keys by default)

### 5) Stop the server

```bash
./stream-stop.sh
```

## Local Usage (Linux)

### 1) Clone the repository

```bash
git clone https://github.com/BharathVasireddy/redstudio-nginx-rtmp.git
cd redstudio-nginx-rtmp
```

If you don’t have Git, install it first (e.g., `sudo apt-get install -y git`).

### 2) Install dependencies

```bash
sudo apt-get update
sudo apt-get install -y nginx python3
```

### 3) Start the server

```bash
chmod +x stream-start.sh
./stream-start.sh
```

### 4) Stream locally

- Dashboard: `http://localhost:8080/`
- Server: `rtmp://localhost/ingest`
- Stream key: any value (local does not enforce ingest keys by default)

### 5) Stop the server

```bash
./stream-stop.sh
```

## Local Usage (Windows)

### 1) Clone the repository

- Install Git for Windows (https://git-scm.com/download/win)
- In Command Prompt or PowerShell:

```
git clone https://github.com/BharathVasireddy/redstudio-nginx-rtmp.git
cd redstudio-nginx-rtmp
```

If you prefer, download the ZIP from GitHub and extract it.

### 2) Install dependencies

- No additional install required (nginx is bundled as `nginx.exe`).

### 3) Start the server

Double-click:

```
stream-start.bat
```

### 4) Stream locally

- Dashboard: `http://localhost:8080/`
- Server: `rtmp://localhost/ingest`
- Stream key: any value (local does not enforce ingest keys by default)

### 5) Stop the server

```
stream-stop.bat
```

## Notes

- Production ingest keys are enforced via `on_publish`.
- Local config is minimal and does not enforce ingest keys.
