#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DATA_DIR="${ROOT_DIR}/data"
JSON_FILE="${DATA_DIR}/restream.json"
CONF_FILE="${DATA_DIR}/restream.conf"
STUNNEL_SNIPPET="${DATA_DIR}/stunnel-rtmps.conf"
STUNNEL_CONF="/etc/stunnel/stunnel.conf"
STUNNEL_MERGED="${DATA_DIR}/stunnel-rtmps.merged.conf"
RTMPS_MARKER="${DATA_DIR}/rtmps-enabled"
PUBLIC_CONFIG_FILE="${DATA_DIR}/public-config.json"
PUBLIC_HLS_CONF_FILE="${DATA_DIR}/public-hls.conf"
OVERLAY_BYPASS_CONF_FILE="${DATA_DIR}/overlay-bypass.conf"
NGINX_BIN="/usr/local/nginx/sbin/nginx"
LOCAL_CONF="${ROOT_DIR}/conf/nginx.local.conf"

CONF_BEFORE=""
if [ -f "${CONF_FILE}" ]; then
    CONF_BEFORE="$(cat "${CONF_FILE}")"
fi
PUBLIC_HLS_BEFORE=""
if [ -f "${PUBLIC_HLS_CONF_FILE}" ]; then
    PUBLIC_HLS_BEFORE="$(cat "${PUBLIC_HLS_CONF_FILE}")"
fi
OVERLAY_BYPASS_BEFORE=""
if [ -f "${OVERLAY_BYPASS_CONF_FILE}" ]; then
    OVERLAY_BYPASS_BEFORE="$(cat "${OVERLAY_BYPASS_CONF_FILE}")"
fi

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
if [ -f "${STUNNEL_SNIPPET}" ] && grep -q '^[[]' "${STUNNEL_SNIPPET}"; then
    touch "${RTMPS_MARKER}"
else
    rm -f "${RTMPS_MARKER}"
fi
python3 - <<'PY' "${JSON_FILE}" "${PUBLIC_CONFIG_FILE}" "${PUBLIC_HLS_CONF_FILE}" "${OVERLAY_BYPASS_CONF_FILE}"
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

public_live = bool(data.get("public_live", True))
public_hls = bool(data.get("public_hls", True))
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
    if overlay_active:
        fh.write("# overlay pipeline active\n")
    else:
        fh.write("push rtmp://127.0.0.1/live/$name;\n")
PY

CONF_AFTER=""
if [ -f "${CONF_FILE}" ]; then
    CONF_AFTER="$(cat "${CONF_FILE}")"
fi
PUBLIC_HLS_AFTER=""
if [ -f "${PUBLIC_HLS_CONF_FILE}" ]; then
    PUBLIC_HLS_AFTER="$(cat "${PUBLIC_HLS_CONF_FILE}")"
fi
OVERLAY_BYPASS_AFTER=""
if [ -f "${OVERLAY_BYPASS_CONF_FILE}" ]; then
    OVERLAY_BYPASS_AFTER="$(cat "${OVERLAY_BYPASS_CONF_FILE}")"
fi

CONF_CHANGED=0
PUBLIC_HLS_CHANGED=0
OVERLAY_BYPASS_CHANGED=0
if [ "${CONF_BEFORE}" != "${CONF_AFTER}" ]; then
    CONF_CHANGED=1
fi
if [ "${PUBLIC_HLS_BEFORE}" != "${PUBLIC_HLS_AFTER}" ]; then
    PUBLIC_HLS_CHANGED=1
fi
if [ "${OVERLAY_BYPASS_BEFORE}" != "${OVERLAY_BYPASS_AFTER}" ]; then
    OVERLAY_BYPASS_CHANGED=1
fi

NEED_RELOAD=0
if [ "${CONF_CHANGED}" = "1" ] || [ "${PUBLIC_HLS_CHANGED}" = "1" ] || [ "${OVERLAY_BYPASS_CHANGED}" = "1" ]; then
    NEED_RELOAD=1
fi

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

        if [ "${RESTART_NGINX:-0}" = "1" ] || [ "${NEED_RELOAD}" = "1" ]; then
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
        fi
    else
        if detect_local_nginx; then
            if [ "${RESTART_NGINX:-0}" = "1" ] || [ "${NEED_RELOAD}" = "1" ]; then
                "${NGINX_BIN}" -t -p "${ROOT_DIR}" -c conf/nginx.local.conf
                if [ "${RESTART_NGINX:-0}" = "1" ]; then
                    restart_local_nginx
                else
                    reload_local_nginx
                fi
            fi
        else
            echo "sudo permissions missing for nginx reload. Run deploy to install sudoers." >&2
            exit 1
        fi
    fi
else
    echo "NGINX binary not found. Skipping reload."
fi
