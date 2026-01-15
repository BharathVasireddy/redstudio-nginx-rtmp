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
RESTREAM_OVERRIDE="${REPO_DIR}/config/restream.override.json"
STUNNEL_SNIPPET="${DATA_DIR}/stunnel-rtmps.conf"
STUNNEL_CONF="/etc/stunnel/stunnel.conf"
STUNNEL_MERGED="${DATA_DIR}/stunnel-rtmps.merged.conf"
RTMPS_MARKER="${DATA_DIR}/rtmps-enabled"
PUBLIC_CONFIG_FILE="${DATA_DIR}/public-config.json"
PUBLIC_HLS_CONF_FILE="${DATA_DIR}/public-hls.conf"
OVERLAY_BYPASS_CONF_FILE="${DATA_DIR}/overlay-bypass.conf"

echo "🚀 Deploying Red Studio updates..."

if [ ! -d "${REPO_DIR}" ]; then
    echo "❌ Repo not found at ${REPO_DIR}"
    exit 1
fi

cd "${REPO_DIR}"

# Sync latest changes (backup runtime data, then hard reset to origin).
echo "📥 Syncing with origin/${BRANCH}..."
git fetch origin "${BRANCH}"

BACKUP_ROOT="local-backup-$(date +%Y%m%d%H%M%S)"
RUNTIME_BACKUP_DIR="${BACKUP_ROOT}/runtime"
RUNTIME_PATHS=(
    "data/restream.json"
    "data/public-config.json"
    "data/public-hls.conf"
    "data/overlay-bypass.conf"
    "data/admin.htpasswd"
    "data/admin.credentials"
    "data/stunnel-rtmps.conf"
    "data/stunnel-rtmps.merged.conf"
    "data/rtmps-enabled"
    "data/stream-status.json"
    "data/overlays"
)

RUNTIME_BACKUP_COUNT=0
for path in "${RUNTIME_PATHS[@]}"; do
    if [ -e "${path}" ]; then
        mkdir -p "${RUNTIME_BACKUP_DIR}/$(dirname "${path}")"
        cp -a "${path}" "${RUNTIME_BACKUP_DIR}/${path}"
        RUNTIME_BACKUP_COUNT=$((RUNTIME_BACKUP_COUNT + 1))
    fi
done
if [ "${RUNTIME_BACKUP_COUNT}" -gt 0 ]; then
    echo "📦 Backed up runtime data to ${RUNTIME_BACKUP_DIR}"
fi

# Move untracked files that would be overwritten by incoming tracked files.
declare -A INCOMING_FILES=()
while read -r status path path2; do
    case "${status}" in
        A|M)
            INCOMING_FILES["${path}"]=1
            ;;
        R*|C*)
            INCOMING_FILES["${path2}"]=1
            ;;
    esac
done < <(git diff --name-status "HEAD" "origin/${BRANCH}" || true)

mapfile -t UNTRACKED_FILES < <(git ls-files --others --exclude-standard)
UNTRACKED_BACKUP_DIR="${BACKUP_ROOT}/untracked-conflicts"
CONFLICT_COUNT=0
if [ "${#UNTRACKED_FILES[@]}" -gt 0 ] && [ "${#INCOMING_FILES[@]}" -gt 0 ]; then
    for file in "${UNTRACKED_FILES[@]}"; do
        if [[ -n "${INCOMING_FILES["$file"]:-}" ]]; then
            mkdir -p "${UNTRACKED_BACKUP_DIR}/$(dirname "${file}")"
            mv "${file}" "${UNTRACKED_BACKUP_DIR}/${file}"
            CONFLICT_COUNT=$((CONFLICT_COUNT + 1))
        fi
    done
fi
if [ "${CONFLICT_COUNT}" -gt 0 ]; then
    echo "📦 Moved ${CONFLICT_COUNT} untracked file(s) to ${UNTRACKED_BACKUP_DIR}"
fi

if [ -f .git/MERGE_HEAD ]; then
    git merge --abort || true
fi
if [ -d .git/rebase-apply ] || [ -d .git/rebase-merge ]; then
    git rebase --abort || true
fi

echo "🧹 Resetting working tree to origin/${BRANCH}..."
git reset --hard "origin/${BRANCH}"

if [ -d "${RUNTIME_BACKUP_DIR}" ]; then
    for path in "${RUNTIME_PATHS[@]}"; do
        if [ -e "${RUNTIME_BACKUP_DIR}/${path}" ]; then
            mkdir -p "$(dirname "${path}")"
            cp -a "${RUNTIME_BACKUP_DIR}/${path}" "${path}"
        fi
    done
fi

# Always keep core scripts in sync with repo for reliable deploys.
FORCE_FILES=(
    "deploy.sh"
    "scripts/admin-api.py"
    "scripts/restream-apply.sh"
    "scripts/restream-generate.py"
    "setup-oracle.sh"
)
BACKUP_DIR=""
for file in "${FORCE_FILES[@]}"; do
    if git diff --name-only -- "${file}" | grep -q . || git diff --cached --name-only -- "${file}" | grep -q .; then
        if [ -z "${BACKUP_DIR}" ]; then
            BACKUP_DIR="local-backup-$(date +%Y%m%d%H%M%S)"
            mkdir -p "${BACKUP_DIR}"
        fi
        if [ -f "${file}" ]; then
            cp -a "${file}" "${BACKUP_DIR}/${file//\//_}"
        fi
    fi
done
if [ -n "${BACKUP_DIR}" ]; then
    echo "📦 Backed up local script overrides to ${BACKUP_DIR}"
fi
git checkout -- "${FORCE_FILES[@]}"

# Ensure scripts are executable (kept for optional use)
chmod +x "${REPO_DIR}/scripts/ffmpeg-abr.sh" \
  "${REPO_DIR}/scripts/ffmpeg-abr-lowcpu.sh" \
  "${REPO_DIR}/scripts/ffmpeg-overlay.sh" \
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
if [ -f "${RESTREAM_OVERRIDE}" ]; then
    python3 - <<'PY' "${RESTREAM_JSON}" "${RESTREAM_OVERRIDE}"
import json
import sys

target, override = sys.argv[1], sys.argv[2]
try:
    with open(target, "r", encoding="utf-8") as fh:
        data = json.load(fh)
except FileNotFoundError:
    data = {}
try:
    with open(override, "r", encoding="utf-8") as fh:
        overrides = json.load(fh)
except FileNotFoundError:
    overrides = {}
if isinstance(overrides, dict):
    data.update(overrides)
    with open(target, "w", encoding="utf-8") as fh:
        json.dump(data, fh, indent=2)
PY
fi
python3 "${REPO_DIR}/scripts/restream-generate.py" "${RESTREAM_JSON}" "${RESTREAM_CONF}" "${STUNNEL_SNIPPET}"
if [ -f "${STUNNEL_SNIPPET}" ] && grep -q '^[[]' "${STUNNEL_SNIPPET}"; then
    touch "${RTMPS_MARKER}"
else
    rm -f "${RTMPS_MARKER}"
fi
python3 - <<'PY' "${RESTREAM_JSON}" "${PUBLIC_CONFIG_FILE}" "${PUBLIC_HLS_CONF_FILE}" "${OVERLAY_BYPASS_CONF_FILE}"
import json
import re
import sys
import time
from datetime import datetime, timezone

json_file, public_config, public_hls_conf, overlay_bypass_conf = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]

try:
    with open(json_file, "r", encoding="utf-8") as fh:
        data = json.load(fh)
except FileNotFoundError:
    data = {}

def parse_bool(value, default):
    if isinstance(value, bool):
        return value
    if value is None:
        return default
    if isinstance(value, (int, float)):
        return value != 0
    if isinstance(value, str):
        text = value.strip().lower()
        if text in ("1", "true", "yes", "on"):
            return True
        if text in ("0", "false", "no", "off"):
            return False
    return default

public_live = bool(data.get("public_live", True))
public_hls = bool(data.get("public_hls", True))
force_transcode = parse_bool(data.get("force_transcode"), True)
overlay_active = False
raw_overlays = data.get("overlays")
if not isinstance(raw_overlays, list):
    raw_overlay = data.get("overlay")
    raw_overlays = [raw_overlay] if isinstance(raw_overlay, dict) else []
for item in raw_overlays:
    if not isinstance(item, dict):
        continue
    if not bool(item.get("enabled")):
        continue
    image_file = str(item.get("image_file", "") or "").strip()
    if image_file:
        overlay_active = True
        break
ticker = data.get("ticker") if isinstance(data, dict) else {}
if not isinstance(ticker, dict):
    ticker = {}
enabled = bool(ticker.get("enabled", False))
speed = ticker.get("speed", 32)
try:
    speed = int(float(speed))
except (TypeError, ValueError):
    speed = 32
speed = max(10, min(120, speed))
font_size = ticker.get("font_size", 14)
try:
    font_size = int(float(font_size))
except (TypeError, ValueError):
    font_size = 14
font_size = max(10, min(28, font_size))
height = ticker.get("height", 40)
try:
    height = int(float(height))
except (TypeError, ValueError):
    height = 40
height = max(28, min(80, height))
background = ticker.get("background", "")
if background is None:
    background = ""
background = str(background).strip()
if not re.match(r"^#(?:[0-9a-fA-F]{3}|[0-9a-fA-F]{6})$", background):
    background = ""
separator = ticker.get("separator", "")
if separator is None:
    separator = ""
separator = str(separator).replace("\r", " ").replace("\n", " ").strip()
if len(separator) > 6:
    separator = separator[:6].strip()
if not separator:
    separator = "•"

items_raw = ticker.get("items")
if not isinstance(items_raw, list):
    items_raw = []

items = []
for item in items_raw:
    if not isinstance(item, dict):
        continue
    text = item.get("text", "")
    if text is None:
        text = ""
    text = str(text).replace("\r", " ").replace("\n", " ").strip()
    html_value = item.get("html")
    if html_value is None:
        html_value = ""
    html_value = str(html_value).strip()
    if not text and html_value:
        text = re.sub(r"<[^>]+>", " ", html_value)
        text = re.sub(r"\s+", " ", text).strip()
    if not text and not html_value:
        continue
    entry = {"text": text, "bold": bool(item.get("bold", False))}
    if html_value:
        entry["html"] = html_value
    item_id = item.get("id")
    if isinstance(item_id, str) and item_id.strip():
        entry["id"] = item_id.strip()
    items.append(entry)

if not items:
    text = ticker.get("text", "")
    if text is None:
        text = ""
    text = str(text).replace("\r", " ").replace("\n", " ").strip()
    if text:
        items = [{"text": text, "bold": False}]

legacy_text = f" {separator} ".join([item.get("text", "") for item in items if item.get("text")])
if not legacy_text:
    legacy_text = ticker.get("text", "") or ""
legacy_text = str(legacy_text).replace("\r", " ").replace("\n", " ").strip()

now = int(time.time())
payload = {
    "public_live": public_live,
    "public_hls": public_hls,
    "ticker": {
        "enabled": enabled,
        "text": legacy_text,
        "speed": speed,
        "font_size": font_size,
        "height": height,
        "background": background,
        "separator": separator,
        "items": items,
    },
    "updated_at_epoch": now,
    "updated_at": datetime.fromtimestamp(now, tz=timezone.utc).isoformat(),
}

with open(public_config, "w", encoding="utf-8") as fh:
    json.dump(payload, fh)

with open(public_hls_conf, "w", encoding="utf-8") as fh:
    fh.write(f"set $public_hls {1 if public_hls else 0};\n")

with open(overlay_bypass_conf, "w", encoding="utf-8") as fh:
    if overlay_active or force_transcode:
        fh.write("# overlay pipeline active\n")
    else:
        fh.write("push rtmp://127.0.0.1/live/stream;\n")
PY

if [ ! -f "${STUNNEL_CONF}" ]; then
    if command -v stunnel4 >/dev/null 2>&1 || command -v stunnel >/dev/null 2>&1; then
        sudo mkdir -p /etc/stunnel
        if [ ! -f "${STUNNEL_CONF}" ]; then
            sudo tee "${STUNNEL_CONF}" >/dev/null <<'EOF'
pid = /run/stunnel4/stunnel.pid
foreground = no
EOF
        fi
    fi
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
