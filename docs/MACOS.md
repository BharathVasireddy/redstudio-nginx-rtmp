# macOS (Local)

## 1) Clone the repository

```bash
git clone https://github.com/BharathVasireddy/redstudio-nginx-rtmp.git
cd redstudio-nginx-rtmp
```

If you don't have Git, install it first or download the ZIP from GitHub and extract it.

## 2) Install dependencies

```bash
# Install Homebrew if you don't have it
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

# Install build dependencies and python
brew install pcre2 zlib openssl@3 python
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

If you see the default "Welcome to nginx" page at `http://localhost:8080/`, another nginx is already using port 8080. Stop it first:

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
