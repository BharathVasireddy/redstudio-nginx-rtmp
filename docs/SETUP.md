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

# Install build dependencies and python
brew install pcre2 zlib openssl@3 python
```

### 3) Run the automated setup (recommended)

```bash
chmod +x scripts/setup-local.sh
./scripts/setup-local.sh --force-stop
```

This installs dependencies, builds nginx with RTMP if needed, and starts the server.

### 4) Start the server (manual)

```bash
chmod +x stream-start.sh
chmod +x stream-stop.sh
./stream-start.sh
```

If you see the default “Welcome to nginx” page at `http://localhost:8080/`, another nginx is already using port 8080. Stop it first:

```bash
sudo lsof -nP -iTCP:8080 -sTCP:LISTEN
brew services stop nginx
sudo nginx -s stop
./stream-stop.sh
./stream-start.sh
```

If you see `unknown directive "rtmp"`, your nginx does not include the RTMP module. Build it from source:

```bash
RTMP_MODULE_DIR="$PWD/vendor/nginx-rtmp-module"
NGINX_VERSION="1.24.0"

cd /tmp
curl -LO "http://nginx.org/download/nginx-${NGINX_VERSION}.tar.gz"
tar -xzf "nginx-${NGINX_VERSION}.tar.gz"
cd "nginx-${NGINX_VERSION}"

export LDFLAGS="-L/opt/homebrew/opt/openssl@3/lib -L/opt/homebrew/opt/pcre2/lib -L/opt/homebrew/opt/zlib/lib"
export CPPFLAGS="-I/opt/homebrew/opt/openssl@3/include -I/opt/homebrew/opt/pcre2/include -I/opt/homebrew/opt/zlib/include"

./configure \
  --prefix=/usr/local/nginx \
  --with-http_ssl_module \
  --with-http_secure_link_module \
  --with-http_realip_module \
  --add-module="${RTMP_MODULE_DIR}"

make -j"$(sysctl -n hw.ncpu)"
sudo make install
sudo ln -sf /usr/local/nginx/sbin/nginx /usr/local/bin/nginx
```

Then run `./stream-start.sh` again.

### 5) Stream locally

- Dashboard: `http://localhost:8080/`
- Server: `rtmp://localhost/ingest`
- Stream key: any value (local does not enforce ingest keys by default)

### 6) Stop the server

```bash
./stream-stop.sh
```

Recommended stop (macOS/Linux):

```bash
chmod +x scripts/stop-local.sh
./scripts/stop-local.sh
```

Diagnostics (macOS/Linux):

```bash
chmod +x scripts/doctor-local.sh
./scripts/doctor-local.sh
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
sudo apt-get install -y python3 git build-essential libpcre3 libpcre3-dev \
  zlib1g zlib1g-dev libssl-dev libgd-dev libgeoip-dev curl unzip
```

### 3) Run the automated setup (recommended)

```bash
chmod +x scripts/setup-local.sh
./scripts/setup-local.sh --force-stop
```

This installs dependencies, builds nginx with RTMP if needed, and starts the server.

### 4) Start the server (manual)

```bash
chmod +x stream-start.sh
chmod +x stream-stop.sh
./stream-start.sh
```

If you see `unknown directive "rtmp"`, your nginx does not include the RTMP module. Build it using:

```bash
sudo ./setup-oracle.sh
```

Then run `./stream-start.sh` again.

If you see the default “Welcome to nginx” page at `http://localhost:8080/`, another nginx is already using port 8080. Stop it first:

```bash
sudo lsof -nP -iTCP:8080 -sTCP:LISTEN
sudo nginx -s stop
./stream-stop.sh
./stream-start.sh
```

### 5) Stream locally

- Dashboard: `http://localhost:8080/`
- Server: `rtmp://localhost/ingest`
- Stream key: any value (local does not enforce ingest keys by default)

### 6) Stop the server

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

Recommended (PowerShell):

```
scripts\setup-local.bat -ForceStop
```

If PowerShell blocks scripts, run:

```
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\setup-local.ps1 -ForceStop
```

If the admin UI does not load, the script will try to install Python via `winget`/`choco`. If those are missing, it will download the official installer via PowerShell. If it still fails, install Python 3 from https://www.python.org/downloads/ and disable the Windows Store "App execution aliases" for python.

Or double-click:

```
stream-start.bat
```

Admin credentials are stored at `data\admin.credentials`.

### 4) Stream locally

- Dashboard: `http://localhost:8080/`
- Server: `rtmp://localhost/ingest`
- Stream key: any value (local does not enforce ingest keys by default)

### 5) Stop the server

```
stream-stop.bat
```

Recommended stop (Windows):

```
scripts\stop-local.bat
```

Diagnostics (Windows):

```
scripts\doctor-local.bat
```

## Notes

- Production ingest keys are enforced via `on_publish`.
- Local config is minimal and does not enforce ingest keys.

## Streaming Flow (Pick One)

Recommended:

```
OBS -> Oracle ingest -> (restream) YouTube/Facebook/Twitch
```

Reason: one upload from your internet, most stable.

Local relay (optional):

```
OBS -> localhost -> (restream) YouTube + Oracle ingest
```

Warning: uses one upload per destination from your home internet.
