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
if [ ! -f data/public-config.json ] || [ ! -f data/public-hls.conf ]; then
  if ! command -v python3 >/dev/null 2>&1; then
    echo "python3 not found. Install python3 and retry." >&2
    exit 1
  fi
  python3 - <<'PY' data/restream.json data/public-config.json data/public-hls.conf
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
