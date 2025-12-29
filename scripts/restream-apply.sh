#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DATA_DIR="${ROOT_DIR}/data"
JSON_FILE="${DATA_DIR}/restream.json"
CONF_FILE="${DATA_DIR}/restream.conf"
STUNNEL_SNIPPET="${DATA_DIR}/stunnel-rtmps.conf"
STUNNEL_CONF="/etc/stunnel/stunnel.conf"
STUNNEL_MERGED="${DATA_DIR}/stunnel-rtmps.merged.conf"
PUBLIC_CONFIG_FILE="${DATA_DIR}/public-config.json"
PUBLIC_HLS_CONF_FILE="${DATA_DIR}/public-hls.conf"
NGINX_BIN="/usr/local/nginx/sbin/nginx"
LOCAL_CONF="${ROOT_DIR}/conf/nginx.local.conf"

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

restart_nginx() {
    PGREP_BIN="$(command -v pgrep || true)"
    MASTER_PID=""
    if [ -n "${PGREP_BIN}" ]; then
        MASTER_PID="$("${PGREP_BIN}" -o -f 'nginx: master' || true)"
    fi
    if [ -n "${MASTER_PID}" ]; then
        run_cmd /bin/kill -TERM "${MASTER_PID}" || true
        for _ in $(seq 1 10); do
            sleep 0.5
            if ! "${PGREP_BIN}" -f 'nginx: master' >/dev/null 2>&1; then
                break
            fi
        done
    fi
    run_cmd "${NGINX_BIN}"
}

restart_local_nginx() {
    PGREP_BIN="$(command -v pgrep || true)"
    MASTER_PID=""
    if [ -n "${PGREP_BIN}" ]; then
        MASTER_PID="$("${PGREP_BIN}" -o -f 'nginx: master' || true)"
    fi
    if [ -n "${MASTER_PID}" ]; then
        /bin/kill -TERM "${MASTER_PID}" || true
        for _ in $(seq 1 10); do
            sleep 0.5
            if ! "${PGREP_BIN}" -f 'nginx: master' >/dev/null 2>&1; then
                break
            fi
        done
    fi
    "${NGINX_BIN}" -p "${ROOT_DIR}" -c conf/nginx.local.conf
}

reload_local_nginx() {
    if ! "${NGINX_BIN}" -p "${ROOT_DIR}" -c conf/nginx.local.conf -s reload; then
        PGREP_BIN="$(command -v pgrep || true)"
        if [ -n "${PGREP_BIN}" ]; then
            MASTER_PID="$("${PGREP_BIN}" -o -f 'nginx: master' || true)"
        else
            MASTER_PID=""
        fi
        if [ -n "${MASTER_PID}" ]; then
            /bin/kill -HUP "${MASTER_PID}"
        else
            echo "nginx master process not found; reload failed." >&2
            exit 1
        fi
    fi
}

detect_local_nginx() {
    if [ "${LOCAL_MODE:-0}" = "1" ]; then
        return 0
    fi
    PGREP_BIN="$(command -v pgrep || true)"
    if [ -z "${PGREP_BIN}" ]; then
        return 1
    fi
    MASTER_PID="$("${PGREP_BIN}" -o -f 'nginx: master' || true)"
    if [ -z "${MASTER_PID}" ]; then
        return 1
    fi
    MASTER_CMD="$(ps -p "${MASTER_PID}" -o command= 2>/dev/null || true)"
    if echo "${MASTER_CMD}" | grep -q "nginx.local.conf"; then
        return 0
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

python3 "${ROOT_DIR}/scripts/restream-generate.py" "${JSON_FILE}" "${CONF_FILE}" "${STUNNEL_SNIPPET}"
python3 - <<'PY' "${JSON_FILE}" "${PUBLIC_CONFIG_FILE}" "${PUBLIC_HLS_CONF_FILE}"
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

if [ ! -x "${NGINX_BIN}" ]; then
    NGINX_BIN="$(command -v nginx || true)"
fi

if [ -x "${NGINX_BIN}" ]; then
    if ensure_sudo; then
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
            if [ "${STUNNEL_CHANGED}" = "1" ]; then
                run_cmd /bin/cp "${STUNNEL_MERGED}" "${STUNNEL_CONF}"
                if command -v systemctl >/dev/null 2>&1; then
                    run_cmd systemctl restart stunnel4 || true
                fi
            fi
        fi

        run_cmd "${NGINX_BIN}" -t

        if [ "${RESTART_NGINX:-0}" = "1" ]; then
            restart_nginx
        else
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
        fi
    else
        if detect_local_nginx; then
            "${NGINX_BIN}" -t -p "${ROOT_DIR}" -c conf/nginx.local.conf
            if [ "${RESTART_NGINX:-0}" = "1" ]; then
                restart_local_nginx
            else
                reload_local_nginx
            fi
        else
            echo "sudo permissions missing for nginx reload. Run deploy to install sudoers." >&2
            exit 1
        fi
    fi
else
    echo "NGINX binary not found. Skipping reload."
fi
