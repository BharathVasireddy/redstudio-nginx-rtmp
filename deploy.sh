#!/bin/bash
# deploy.sh - Run this on your Oracle Cloud instance after git pull
# Usage: ./deploy.sh

set -euo pipefail

REPO_DIR="/var/www/nginx-rtmp-module"
BRANCH="${DEPLOY_BRANCH:-main}"
NGINX_CONF_PATH="/usr/local/nginx/conf/nginx.conf"
NGINX_BIN="/usr/local/nginx/sbin/nginx"
FORCE_NGINX_CONF="${FORCE_NGINX_CONF:-0}"
API_SERVICE_PATH="/etc/systemd/system/nginx-rtmp-api.service"
FORCE_API_SERVICE="${FORCE_API_SERVICE:-0}"
SAFE_DEPLOY="${SAFE_DEPLOY:-1}"
FORCE_DEPLOY="${FORCE_DEPLOY:-0}"

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

# Ensure FFmpeg scripts are executable
chmod +x "${REPO_DIR}/scripts/ffmpeg-abr.sh" "${REPO_DIR}/scripts/ffmpeg-abr-lowcpu.sh" 2>/dev/null || true

# Install/update API dependencies
if [ -f "${REPO_DIR}/api/package.json" ]; then
    echo "📦 Installing API dependencies..."
    cd "${REPO_DIR}/api"
    npm install --omit=dev
    cd "${REPO_DIR}"
fi

# Sync NGINX config into system path (Oracle build) if missing managed blocks
if [ "${FORCE_NGINX_CONF}" = "1" ]; then
    echo "📄 Forcing NGINX config update..."
    if [ -f "${NGINX_CONF_PATH}" ]; then
        sudo mv "${NGINX_CONF_PATH}" "${NGINX_CONF_PATH}.backup.$(date +%Y%m%d%H%M%S)"
    fi
    sudo cp "${REPO_DIR}/conf/nginx.conf" "${NGINX_CONF_PATH}"
elif [ -f "${NGINX_CONF_PATH}" ]; then
    if grep -q "Managed HLS Pipeline" "${NGINX_CONF_PATH}"; then
        echo "📄 NGINX config already includes managed blocks."
    else
        echo "📄 Updating NGINX config with managed blocks..."
        sudo mv "${NGINX_CONF_PATH}" "${NGINX_CONF_PATH}.backup.$(date +%Y%m%d%H%M%S)"
        sudo cp "${REPO_DIR}/conf/nginx.conf" "${NGINX_CONF_PATH}"
    fi
else
    echo "📄 Installing NGINX config..."
    sudo cp "${REPO_DIR}/conf/nginx.conf" "${NGINX_CONF_PATH}"
fi

# Install/update API systemd unit if already installed or forced
if [ -f "${API_SERVICE_PATH}" ] || [ "${FORCE_API_SERVICE}" = "1" ]; then
    echo "⚙️ Updating API service unit..."
    sudo cp "${REPO_DIR}/nginx-rtmp-api.service" "${API_SERVICE_PATH}"
    sudo systemctl daemon-reload
fi

# Safe deploy: avoid reload/restart if stream is live
SKIP_RELOAD=0
if [ "${SAFE_DEPLOY}" = "1" ] && [ "${FORCE_DEPLOY}" != "1" ]; then
    if command -v curl >/dev/null 2>&1; then
        STREAM_STATUS="$(curl -s --max-time 2 http://127.0.0.1:3000/api/stream/status 2>/dev/null || \
            curl -s --max-time 2 http://127.0.0.1:8080/api/stream/status 2>/dev/null || true)"
        if echo "${STREAM_STATUS}" | grep -q '"isLive"[[:space:]]*:[[:space:]]*true'; then
            echo "⚠️ Stream is live. Skipping NGINX reload and API restart (set FORCE_DEPLOY=1 to override)."
            SKIP_RELOAD=1
        fi
    fi
fi

# Reload NGINX
if [ ! -x "${NGINX_BIN}" ]; then
    NGINX_BIN="$(command -v nginx || true)"
fi

if [ -x "${NGINX_BIN}" ] && [ "${SKIP_RELOAD}" = "0" ]; then
    echo "🔄 Reloading NGINX..."
    sudo "${NGINX_BIN}" -t
    sudo "${NGINX_BIN}" -s reload
else
    if [ "${SKIP_RELOAD}" = "0" ]; then
        echo "⚠️ NGINX binary not found; skipping reload."
    fi
fi

# Restart Node.js API
if [ -f "${API_SERVICE_PATH}" ] && [ "${SKIP_RELOAD}" = "0" ]; then
    echo "🔄 Restarting API (systemd)..."
    sudo systemctl restart nginx-rtmp-api
elif [ "${SKIP_RELOAD}" = "0" ] && command -v pm2 &> /dev/null; then
    echo "🔄 Restarting API (PM2)..."
    pm2 restart redstudio-api 2>/dev/null || pm2 restart server 2>/dev/null || pm2 start api/server.js --name redstudio-api
fi

echo "✅ Deployment complete!"
echo ""
echo "Services status:"
echo "  - NGINX: $(systemctl is-active nginx-rtmp 2>/dev/null || echo 'running')"
if [ -f "${API_SERVICE_PATH}" ]; then
    echo "  - API:   $(systemctl is-active nginx-rtmp-api 2>/dev/null || echo 'unknown')"
elif command -v pm2 &> /dev/null; then
    pm2 status redstudio-api || true
fi
