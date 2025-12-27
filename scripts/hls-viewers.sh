#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG_FILE="${ROOT_DIR}/logs/hls_access.log"
OUT_FILE="${ROOT_DIR}/public/hls-viewers.json"
WINDOW_SEC="${WINDOW_SEC:-30}"

python3 - <<'PY' "${LOG_FILE}" "${OUT_FILE}" "${WINDOW_SEC}"
import json
import sys
from datetime import datetime, timedelta, timezone

log_file, out_file, window_sec = sys.argv[1], sys.argv[2], int(sys.argv[3])
now = datetime.now(timezone.utc)
cutoff = now - timedelta(seconds=window_sec)

viewer_ips = set()
requests = 0

try:
    with open(log_file, "r", encoding="utf-8") as fh:
        for line in fh:
            parts = line.strip().split()
            if len(parts) < 4:
                continue
            ts_str, remote_ip, cf_ip = parts[0], parts[1], parts[2]
            try:
                ts = datetime.fromisoformat(ts_str)
            except ValueError:
                continue
            if ts.tzinfo is None:
                ts = ts.replace(tzinfo=timezone.utc)
            if ts < cutoff:
                continue
            ip = cf_ip if cf_ip and cf_ip != "-" else remote_ip
            viewer_ips.add(ip)
            requests += 1
except FileNotFoundError:
    pass

data = {
    "window_seconds": window_sec,
    "viewer_ips": len(viewer_ips),
    "requests": requests,
    "updated_at": now.isoformat()
}

with open(out_file, "w", encoding="utf-8") as fh:
    json.dump(data, fh)
PY
