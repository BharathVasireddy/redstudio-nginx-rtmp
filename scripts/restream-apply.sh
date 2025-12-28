#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DATA_DIR="${ROOT_DIR}/data"
JSON_FILE="${DATA_DIR}/restream.json"
CONF_FILE="${DATA_DIR}/restream.conf"
NGINX_BIN="/usr/local/nginx/sbin/nginx"

if [ ! -f "${JSON_FILE}" ]; then
    cp "${ROOT_DIR}/config/restream.default.json" "${JSON_FILE}"
fi

python3 "${ROOT_DIR}/scripts/restream-generate.py" "${JSON_FILE}" "${CONF_FILE}"

if [ ! -x "${NGINX_BIN}" ]; then
    NGINX_BIN="$(command -v nginx || true)"
fi

if [ -x "${NGINX_BIN}" ]; then
    if [ "$(id -u)" -eq 0 ]; then
        "${NGINX_BIN}" -t
        "${NGINX_BIN}" -s reload
    elif command -v sudo >/dev/null 2>&1; then
        if sudo -n true 2>/dev/null; then
            sudo -n "${NGINX_BIN}" -t
            sudo -n "${NGINX_BIN}" -s reload
        else
            echo "sudo permissions missing for nginx reload. Run deploy to install sudoers." >&2
            exit 1
        fi
    else
        echo "nginx reload requires root or sudo." >&2
        exit 1
    fi
else
    echo "NGINX binary not found. Skipping reload."
fi
