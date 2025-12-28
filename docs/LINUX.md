# Linux (Local)

## 1) Clone the repository

```bash
git clone https://github.com/BharathVasireddy/redstudio-nginx-rtmp.git
cd redstudio-nginx-rtmp
```

If you don't have Git, install it first (e.g., `sudo apt-get install -y git`).

## 2) Install dependencies

```bash
sudo apt-get update
sudo apt-get install -y python3 git build-essential libpcre3 libpcre3-dev \
  zlib1g zlib1g-dev libssl-dev libgd-dev libgeoip-dev curl unzip
```

## 3) Run the automated setup (recommended)

```bash
chmod +x scripts/setup-local.sh
./scripts/setup-local.sh --force-stop
```

This installs dependencies, builds nginx with RTMP if needed, and starts the server.

## 4) Start the server (manual)

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

If you see the default "Welcome to nginx" page at `http://localhost:8080/`, another nginx is already using port 8080. Stop it first:

```bash
sudo lsof -nP -iTCP:8080 -sTCP:LISTEN
sudo nginx -s stop
./stream-stop.sh
./stream-start.sh
```

## 5) Stream locally

- Dashboard: `http://localhost:8080/`
- Server: `rtmp://localhost/ingest`
- Stream key: any value (local does not enforce ingest keys by default)

## 6) Stop the server

```bash
./stream-stop.sh
```

Recommended stop:

```bash
chmod +x scripts/stop-local.sh
./scripts/stop-local.sh
```

Diagnostics:

```bash
chmod +x scripts/doctor-local.sh
./scripts/doctor-local.sh
```
