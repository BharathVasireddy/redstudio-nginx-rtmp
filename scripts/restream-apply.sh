#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DATA_DIR="${ROOT_DIR}/data"
JSON_FILE="${DATA_DIR}/restream.json"
CONF_FILE="${DATA_DIR}/restream.conf"
NGINX_BIN="/usr/local/nginx/sbin/nginx"

run_cmd() {
    if [ "$(id -u)" -eq 0 ]; then
        "$@"
        return $?
    fi
    if command -v sudo >/dev/null 2>&1; then
        sudo -n "$@"
        return $?
    fi
    return 1
}

ensure_sudo() {
    if [ "$(id -u)" -eq 0 ]; then
        return 0
    fi
    if command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
        return 0
    fi
    return 1
}

if [ ! -f "${JSON_FILE}" ]; then
    cp "${ROOT_DIR}/config/restream.default.json" "${JSON_FILE}"
fi

python3 "${ROOT_DIR}/scripts/restream-generate.py" "${JSON_FILE}" "${CONF_FILE}"

if [ ! -x "${NGINX_BIN}" ]; then
    NGINX_BIN="$(command -v nginx || true)"
fi

if [ -x "${NGINX_BIN}" ]; then
    if ! ensure_sudo; then
        echo "sudo permissions missing for nginx reload. Run deploy to install sudoers." >&2
        exit 1
    fi

    run_cmd "${NGINX_BIN}" -t

    if ! run_cmd "${NGINX_BIN}" -s reload; then
        PGREP_BIN="$(command -v pgrep || true)"
        if [ -n "${PGREP_BIN}" ]; then
            MASTER_PID="$("${PGREP_BIN}" -o -f 'nginx: master' || true)"
        else
            MASTER_PID=""
        fi
        if [ -n "${MASTER_PID}" ]; then
            run_cmd /bin/kill -HUP "${MASTER_PID}"
        else
            echo "nginx master process not found; reload failed." >&2
            exit 1
        fi
    fi
else
    echo "NGINX binary not found. Skipping reload."
fi
