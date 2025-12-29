#!/bin/bash
# setup-oracle.sh - One-time setup script for Oracle Cloud instance
# Run this on a fresh Ubuntu instance on Oracle Cloud
# Usage: sudo ./setup-oracle.sh

set -e

echo "🚀 Red Studio - Oracle Cloud Setup"
echo "===================================="

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo "❌ Please run as root: sudo ./setup-oracle.sh"
    exit 1
fi

# System update
echo ""
echo "📦 Updating system packages..."
apt update && apt upgrade -y

# Install build dependencies
echo ""
echo "📦 Installing build dependencies..."
apt install -y build-essential libpcre3 libpcre3-dev zlib1g zlib1g-dev \
    libssl-dev libgd-dev libgeoip-dev git curl unzip python3

# Create web directory
echo ""
echo "📁 Creating web directory..."
mkdir -p /var/www
cd /var/www

# Clone repository (or skip if exists)
if [ ! -d "/var/www/nginx-rtmp-module" ]; then
    echo ""
    echo "📥 Cloning repository..."
    git clone https://github.com/BharathVasireddy/redstudio-nginx-rtmp.git nginx-rtmp-module
else
    echo ""
    echo "📥 Repository exists, pulling latest..."
    cd nginx-rtmp-module
    git pull origin main
    cd /var/www
fi

# Download and build NGINX with RTMP module
echo ""
echo "🔨 Building NGINX with RTMP module..."
cd /tmp

# Download NGINX
NGINX_VERSION="1.24.0"
wget -q http://nginx.org/download/nginx-${NGINX_VERSION}.tar.gz
tar -xzf nginx-${NGINX_VERSION}.tar.gz

# Use vendored RTMP module (no external dependency)
RTMP_MODULE_DIR="/var/www/nginx-rtmp-module/vendor/nginx-rtmp-module"
if [ ! -d "${RTMP_MODULE_DIR}" ]; then
    echo "❌ Vendored nginx-rtmp-module not found at ${RTMP_MODULE_DIR}"
    exit 1
fi

# Compile NGINX
cd nginx-${NGINX_VERSION}
./configure \
    --prefix=/usr/local/nginx \
    --with-http_ssl_module \
    --with-http_secure_link_module \
    --with-http_realip_module \
    --add-module="${RTMP_MODULE_DIR}"

make -j$(nproc)
make install

# Create symlink
ln -sf /usr/local/nginx/sbin/nginx /usr/bin/nginx

# Create required directories
echo ""
echo "📁 Creating directories..."
mkdir -p /var/www/nginx-rtmp-module/temp/hls
mkdir -p /var/www/nginx-rtmp-module/logs
mkdir -p /var/www/nginx-rtmp-module/data
if [ ! -f /var/www/nginx-rtmp-module/data/restream.json ]; then
    cp /var/www/nginx-rtmp-module/config/restream.default.json /var/www/nginx-rtmp-module/data/restream.json
fi
python3 /var/www/nginx-rtmp-module/scripts/restream-generate.py \
    /var/www/nginx-rtmp-module/data/restream.json \
    /var/www/nginx-rtmp-module/data/restream.conf
python3 - <<'PY'
import json
import time
from datetime import datetime, timezone
from pathlib import Path

root = Path("/var/www/nginx-rtmp-module")
data_dir = root / "data"
config_file = data_dir / "restream.json"
public_config = data_dir / "public-config.json"
public_hls_conf = data_dir / "public-hls.conf"

try:
    data = json.loads(config_file.read_text(encoding="utf-8"))
except FileNotFoundError:
    data = {}

public_live = bool(data.get("public_live", True))
public_hls = bool(data.get("public_hls", True))

now = int(time.time())
payload = {
    "public_live": public_live,
    "public_hls": public_hls,
    "updated_at_epoch": now,
    "updated_at": datetime.fromtimestamp(now, tz=timezone.utc).isoformat(),
}
public_config.write_text(json.dumps(payload), encoding="utf-8")
public_hls_conf.write_text(f"set $public_hls {1 if public_hls else 0};\n", encoding="utf-8")
PY
chown -R www-data:www-data /var/www/nginx-rtmp-module
chmod -R 777 /var/www/nginx-rtmp-module/temp /var/www/nginx-rtmp-module/logs

# Copy nginx config
echo ""
echo "⚙️ Configuring NGINX..."
if [ -e /usr/local/nginx/conf/nginx.conf ]; then
    mv /usr/local/nginx/conf/nginx.conf /usr/local/nginx/conf/nginx.conf.backup.$(date +%Y%m%d%H%M%S)
fi
cp /var/www/nginx-rtmp-module/conf/nginx.conf /usr/local/nginx/conf/nginx.conf

# Install systemd service
echo ""
echo "⚙️ Installing systemd service..."
cp /var/www/nginx-rtmp-module/nginx-rtmp.service /etc/systemd/system/nginx-rtmp.service
systemctl daemon-reload
systemctl enable nginx-rtmp

# Configure firewall
echo ""
echo "🔥 Configuring firewall..."
# Oracle Cloud uses iptables
iptables -I INPUT -p tcp --dport 80 -j ACCEPT
iptables -I INPUT -p tcp --dport 443 -j ACCEPT
iptables -I INPUT -p tcp --dport 8080 -j ACCEPT
iptables -I INPUT -p tcp --dport 1935 -j ACCEPT

# Save iptables rules
apt install -y iptables-persistent
netfilter-persistent save

# Start services
echo ""
echo "🚀 Starting services..."
systemctl start nginx-rtmp

# Cleanup
echo ""
echo "🧹 Cleaning up..."
rm -rf /tmp/nginx-${NGINX_VERSION}*

# Final status
echo ""
echo "===================================="
echo "✅ Setup Complete!"
echo "===================================="
echo ""
echo "Services Status:"
echo "  NGINX: $(systemctl is-active nginx-rtmp)"
echo ""
echo "Access your server at:"
echo "  http://$(curl -s ifconfig.me):8080"
echo ""
echo "⚠️  Don't forget to:"
echo "  1. Update Oracle Cloud Security List to allow ports 80, 443, 1935, 8080"
echo "  2. Add GitHub secrets for automated deployment"
echo ""
