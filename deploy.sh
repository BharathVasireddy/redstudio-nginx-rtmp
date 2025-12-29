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
STUNNEL_SNIPPET="${DATA_DIR}/stunnel-rtmps.conf"
STUNNEL_CONF="/etc/stunnel/stunnel.conf"
STUNNEL_MERGED="${DATA_DIR}/stunnel-rtmps.merged.conf"
PUBLIC_CONFIG_FILE="${DATA_DIR}/public-config.json"
PUBLIC_HLS_CONF_FILE="${DATA_DIR}/public-hls.conf"

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
python3 "${REPO_DIR}/scripts/restream-generate.py" "${RESTREAM_JSON}" "${RESTREAM_CONF}" "${STUNNEL_SNIPPET}"
if [ ! -f "${PUBLIC_CONFIG_FILE}" ] || [ ! -f "${PUBLIC_HLS_CONF_FILE}" ]; then
    python3 - <<'PY' "${RESTREAM_JSON}" "${PUBLIC_CONFIG_FILE}" "${PUBLIC_HLS_CONF_FILE}"
import json
import sys
import time
from datetime import datetime, timezone

json_file, public_config, public_hls_conf = sys.argv[1], sys.argv[2], sys.argv[3]

try:
    with open(json_file, "r", encoding="utf-8") as fh:
        data = json.load(fh)
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

with open(public_config, "w", encoding="utf-8") as fh:
    json.dump(payload, fh)

with open(public_hls_conf, "w", encoding="utf-8") as fh:
    fh.write(f"set $public_hls {1 if public_hls else 0};\n")
PY
fi

if [ -f "${STUNNEL_CONF}" ] && [ -f "${STUNNEL_SNIPPET}" ]; then
    STUNNEL_CHANGED="$(
        python3 - <<'PY' "${STUNNEL_CONF}" "${STUNNEL_SNIPPET}" "${STUNNEL_MERGED}"
import sys
from pathlib import Path

conf_path = Path(sys.argv[1])
snippet_path = Path(sys.argv[2])
out_path = Path(sys.argv[3])
marker_begin = "# BEGIN REDSTUDIO RTMPS CLIENTS"
marker_end = "# END REDSTUDIO RTMPS CLIENTS"

conf_text = conf_path.read_text(encoding="utf-8") if conf_path.exists() else ""
snippet = snippet_path.read_text(encoding="utf-8").strip()
has_sections = any(line.startswith("[") for line in snippet.splitlines())

block = ""
if has_sections:
    block_lines = [marker_begin, snippet, marker_end]
    block = "\n".join(block_lines)

if marker_begin in conf_text and marker_end in conf_text:
    before, rest = conf_text.split(marker_begin, 1)
    _, after = rest.split(marker_end, 1)
    new_conf = before.rstrip() + ("\n" + block + "\n" if block else "\n") + after.lstrip()
else:
    if conf_text and not conf_text.endswith("\n"):
        conf_text += "\n"
    new_conf = conf_text + (block + "\n" if block else "")

out_path.write_text(new_conf, encoding="utf-8")
print("1" if new_conf != conf_text else "0")
PY
    )"
    if [ "${STUNNEL_CHANGED}" = "1" ] && command -v systemctl >/dev/null 2>&1; then
        sudo cp "${STUNNEL_MERGED}" "${STUNNEL_CONF}"
        sudo systemctl restart stunnel4 || true
    fi
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
