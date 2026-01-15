#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"
echo "Starting Streaming Server..."
mkdir -p data
if [ ! -f data/restream.json ]; then
  cp config/restream.default.json data/restream.json
fi
if [ ! -f data/restream.conf ]; then
  if ! command -v python3 >/dev/null 2>&1; then
    echo "python3 not found. Install python3 and retry." >&2
    exit 1
  fi
  python3 scripts/restream-generate.py data/restream.json data/restream.conf
fi
if [ ! -f data/public-config.json ] || [ ! -f data/public-hls.conf ] || [ ! -f data/overlay-bypass.conf ]; then
  if ! command -v python3 >/dev/null 2>&1; then
    echo "python3 not found. Install python3 and retry." >&2
    exit 1
  fi
  python3 - <<'PY' data/restream.json data/public-config.json data/public-hls.conf data/overlay-bypass.conf
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
fi
mkdir -p conf/data
ln -sf "$PWD/data/restream.conf" "$PWD/conf/data/restream.conf"

NGINX_BIN=""
if [ -x "/usr/local/nginx/sbin/nginx" ]; then
  NGINX_BIN="/usr/local/nginx/sbin/nginx"
elif command -v nginx >/dev/null 2>&1; then
  NGINX_BIN="$(command -v nginx)"
fi

if [ -z "${NGINX_BIN}" ]; then
  echo "nginx not found. Install or build nginx with RTMP support." >&2
  exit 1
fi

"${NGINX_BIN}" -t -p "$PWD" -c conf/nginx.local.conf
"${NGINX_BIN}" -p "$PWD" -c conf/nginx.local.conf
echo ""
echo "Server Started!"
echo "--------------------------------------------"
echo "Dashboard: http://localhost:8080/"
echo "Admin: http://localhost:8080/admin/"
echo "Stream Key: any (local only)"
echo "URL: rtmp://localhost/ingest"
echo "--------------------------------------------"
