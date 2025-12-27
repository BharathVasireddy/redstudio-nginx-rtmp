#!/bin/bash
# deploy.sh - Run this on your Oracle Cloud instance after git pull
# Usage: ./deploy.sh

set -euo pipefail

REPO_DIR="/var/www/nginx-rtmp-module"
BRANCH="${DEPLOY_BRANCH:-main}"
NGINX_CONF_PATH="/usr/local/nginx/conf/nginx.conf"
NGINX_BIN="/usr/local/nginx/sbin/nginx"
NGINX_PID="/usr/local/nginx/logs/nginx.pid"
FORCE_NGINX_CONF="${FORCE_NGINX_CONF:-0}"

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
  "${REPO_DIR}/scripts/hls-viewers.sh" 2>/dev/null || true

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

# Install/update HLS viewer counter timer (server only)
if command -v systemctl >/dev/null 2>&1; then
    sudo cp "${REPO_DIR}/scripts/hls-viewers.service" /etc/systemd/system/hls-viewers.service
    sudo cp "${REPO_DIR}/scripts/hls-viewers.timer" /etc/systemd/system/hls-viewers.timer
    sudo systemctl daemon-reload
    sudo systemctl enable --now hls-viewers.timer >/dev/null 2>&1 || true
fi

# Reload NGINX
if [ ! -x "${NGINX_BIN}" ]; then
    NGINX_BIN="$(command -v nginx || true)"
fi

if [ -x "${NGINX_BIN}" ]; then
    sudo "${NGINX_BIN}" -t
    PID=""
    if [ -s "${NGINX_PID}" ]; then
        PID="$(tr -d '[:space:]' < "${NGINX_PID}")"
    fi
    if [ -n "${PID}" ] && [ "${PID}" -eq "${PID}" ] 2>/dev/null && sudo kill -0 "${PID}" 2>/dev/null; then
        echo "🔄 Reloading NGINX..."
        sudo "${NGINX_BIN}" -s reload
    else
        MASTER_PID="$(pgrep -o -f 'nginx: master' || true)"
        if [ -n "${MASTER_PID}" ]; then
            echo "🔄 Reloading NGINX (signal)..."
            sudo kill -HUP "${MASTER_PID}"
        else
            echo "🚀 Starting NGINX..."
            sudo "${NGINX_BIN}"
        fi
    fi
else
    echo "⚠️ NGINX binary not found; skipping reload."
fi

echo "✅ Deployment complete!"
echo ""
echo "Services status:"
echo "  - NGINX: $(systemctl is-active nginx-rtmp 2>/dev/null || echo 'running')"
