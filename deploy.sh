#!/bin/bash
# deploy.sh - Run this on your Oracle Cloud instance after git pull
# Usage: ./deploy.sh

set -euo pipefail

REPO_DIR="/var/www/nginx-rtmp-module"
BRANCH="${DEPLOY_BRANCH:-main}"
NGINX_CONF_PATH="/usr/local/nginx/conf/nginx.conf"
NGINX_BIN="/usr/local/nginx/sbin/nginx"
FORCE_NGINX_CONF="${FORCE_NGINX_CONF:-0}"
SSL_CONF_DIR="/usr/local/nginx/conf/ssl.d"
SSL_CONF_FILE="${SSL_CONF_DIR}/letsencrypt.conf"
SSL_CERT_PATH="${SSL_CERT_PATH:-}"
SSL_KEY_PATH="${SSL_KEY_PATH:-}"
DATA_DIR="${REPO_DIR}/data"
ADMIN_USER="${ADMIN_USER:-admin}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-}"
ADMIN_HTPASSWD="${DATA_DIR}/admin.htpasswd"
ADMIN_CREDS="${DATA_DIR}/admin.credentials"
RESTREAM_JSON="${DATA_DIR}/restream.json"
RESTREAM_CONF="${DATA_DIR}/restream.conf"

echo "🚀 Deploying Red Studio updates..."

if [ ! -d "${REPO_DIR}" ]; then
    echo "❌ Repo not found at ${REPO_DIR}"
    exit 1
fi

cd "${REPO_DIR}"

# Pull latest changes
echo "📥 Pulling latest changes from Git..."
git fetch origin "${BRANCH}"

STASH_CREATED=0
if ! git diff --quiet || ! git diff --cached --quiet || [ -n "$(git ls-files --others --exclude-standard)" ]; then
    echo "📦 Stashing local changes..."
    git stash push -u -m "auto-deploy-$(date +%Y%m%d%H%M%S)" >/dev/null
    STASH_CREATED=1
fi

git pull --ff-only origin "${BRANCH}"

if [ "${STASH_CREATED}" = "1" ]; then
    echo "📦 Restoring local changes..."
    if ! git stash pop; then
        echo "⚠️ Stash apply failed. Resolve manually with: git stash list"
        exit 1
    fi
fi

# Ensure scripts are executable (kept for optional use)
chmod +x "${REPO_DIR}/scripts/ffmpeg-abr.sh" \
  "${REPO_DIR}/scripts/ffmpeg-abr-lowcpu.sh" \
  "${REPO_DIR}/scripts/restream-apply.sh" \
  "${REPO_DIR}/scripts/restream-generate.py" \
  "${REPO_DIR}/scripts/admin-api.py" \
  "${REPO_DIR}/scripts/hls-viewers.sh" 2>/dev/null || true

# Ensure data directory exists and defaults are present
sudo mkdir -p "${DATA_DIR}"
sudo chown -R "$(id -un)":"$(id -gn)" "${DATA_DIR}"
if [ ! -f "${RESTREAM_JSON}" ]; then
    cp "${REPO_DIR}/config/restream.default.json" "${RESTREAM_JSON}"
fi
if [ ! -f "${RESTREAM_CONF}" ]; then
    python3 "${REPO_DIR}/scripts/restream-generate.py" "${RESTREAM_JSON}" "${RESTREAM_CONF}"
fi

# Create admin credentials if missing or secrets provided
if [ -n "${ADMIN_PASSWORD}" ] || [ ! -f "${ADMIN_HTPASSWD}" ]; then
    if [ -z "${ADMIN_PASSWORD}" ]; then
        ADMIN_PASSWORD="$(openssl rand -hex 8)"
        printf "user=%s\npassword=%s\n" "${ADMIN_USER}" "${ADMIN_PASSWORD}" > "${ADMIN_CREDS}"
    fi
    HASH="$(openssl passwd -apr1 "${ADMIN_PASSWORD}")"
    printf "%s:%s\n" "${ADMIN_USER}" "${HASH}" | sudo tee "${ADMIN_HTPASSWD}" >/dev/null
    sudo chmod 644 "${ADMIN_HTPASSWD}"
fi

# Ensure runtime directories are writable by NGINX
sudo mkdir -p "${REPO_DIR}/temp/hls" "${REPO_DIR}/logs"
sudo chmod -R 777 "${REPO_DIR}/temp" "${REPO_DIR}/logs" 2>/dev/null || true

# Sync NGINX config into system path (Oracle build) if missing managed blocks
if [ "${FORCE_NGINX_CONF}" = "1" ]; then
    echo "📄 Forcing NGINX config update..."
    if [ -f "${NGINX_CONF_PATH}" ]; then
        sudo mv "${NGINX_CONF_PATH}" "${NGINX_CONF_PATH}.backup.$(date +%Y%m%d%H%M%S)"
    fi
    sudo cp "${REPO_DIR}/conf/nginx.conf" "${NGINX_CONF_PATH}"
elif [ -f "${NGINX_CONF_PATH}" ]; then
    echo "📄 Updating NGINX config..."
    sudo mv "${NGINX_CONF_PATH}" "${NGINX_CONF_PATH}.backup.$(date +%Y%m%d%H%M%S)"
    sudo cp "${REPO_DIR}/conf/nginx.conf" "${NGINX_CONF_PATH}"
else
    echo "📄 Installing NGINX config..."
    sudo cp "${REPO_DIR}/conf/nginx.conf" "${NGINX_CONF_PATH}"
fi

# Create SSL include config if a Let's Encrypt cert is present.
if [ -z "${SSL_CERT_PATH}" ] || [ -z "${SSL_KEY_PATH}" ]; then
    if [ -d /etc/letsencrypt/live ]; then
        LE_DIRS=()
        for dir in /etc/letsencrypt/live/*; do
            if [ -d "${dir}" ]; then
                LE_DIRS+=("${dir}")
            fi
        done
        if [ ${#LE_DIRS[@]} -eq 1 ]; then
            SSL_CERT_PATH="${LE_DIRS[0]}/fullchain.pem"
            SSL_KEY_PATH="${LE_DIRS[0]}/privkey.pem"
        fi
    fi
fi

if [ -n "${SSL_CERT_PATH}" ] && [ -n "${SSL_KEY_PATH}" ] && [ -f "${SSL_CERT_PATH}" ] && [ -f "${SSL_KEY_PATH}" ]; then
    sudo mkdir -p "${SSL_CONF_DIR}"
    if [ ! -f "${SSL_CONF_FILE}" ]; then
        sudo tee "${SSL_CONF_FILE}" >/dev/null <<EOF
listen 443 ssl;
ssl_certificate ${SSL_CERT_PATH};
ssl_certificate_key ${SSL_KEY_PATH};
ssl_protocols TLSv1.2 TLSv1.3;
ssl_session_cache shared:SSL:10m;
ssl_session_timeout 1d;
EOF
    fi
fi

# Install/update HLS viewer counter timer (server only)
if command -v systemctl >/dev/null 2>&1; then
    sudo cp "${REPO_DIR}/scripts/hls-viewers.service" /etc/systemd/system/hls-viewers.service
    sudo cp "${REPO_DIR}/scripts/hls-viewers.timer" /etc/systemd/system/hls-viewers.timer
    sudo cp "${REPO_DIR}/scripts/redstudio-admin.service" /etc/systemd/system/redstudio-admin.service
    sudo systemctl daemon-reload
    sudo systemctl enable --now hls-viewers.timer >/dev/null 2>&1 || true
    sudo systemctl enable --now redstudio-admin.service >/dev/null 2>&1 || true
    sudo systemctl restart redstudio-admin.service >/dev/null 2>&1 || true
fi

# Allow admin API to reload NGINX without prompting for sudo.
SUDOERS_FILE="/etc/sudoers.d/redstudio-nginx"
NGINX_SUDO_BIN="${NGINX_BIN}"
if [ ! -x "${NGINX_SUDO_BIN}" ]; then
    NGINX_SUDO_BIN="$(command -v nginx || true)"
fi
if [ -n "${NGINX_SUDO_BIN}" ] && command -v sudo >/dev/null 2>&1; then
    echo "$(id -un) ALL=(root) NOPASSWD: ${NGINX_SUDO_BIN}" | sudo tee "${SUDOERS_FILE}" >/dev/null
    sudo chmod 440 "${SUDOERS_FILE}"
fi

# Reload NGINX
if [ ! -x "${NGINX_BIN}" ]; then
    NGINX_BIN="$(command -v nginx || true)"
fi

if [ -x "${NGINX_BIN}" ]; then
    sudo "${NGINX_BIN}" -t
    PGREP_BIN="$(command -v pgrep || true)"
    if [ -n "${PGREP_BIN}" ]; then
        MASTER_PID="$("${PGREP_BIN}" -o -f 'nginx: master' || true)"
    else
        MASTER_PID=""
    fi
    if [ -n "${MASTER_PID}" ]; then
        echo "🔄 Reloading NGINX (signal)..."
        sudo kill -HUP "${MASTER_PID}"
    else
        echo "🚀 Starting NGINX..."
        sudo "${NGINX_BIN}"
    fi
else
    echo "⚠️ NGINX binary not found; skipping reload."
fi

echo "✅ Deployment complete!"
echo ""
echo "Services status:"
echo "  - NGINX: $(systemctl is-active nginx-rtmp 2>/dev/null || echo 'running')"
