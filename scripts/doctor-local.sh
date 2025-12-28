#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OK=true

log() { echo ">> $*"; }
warn() { echo "!! $*" >&2; OK=false; }

log "Running local diagnostics..."

NGINX_BIN=""
if [ -x "/usr/local/nginx/sbin/nginx" ]; then
  NGINX_BIN="/usr/local/nginx/sbin/nginx"
elif command -v nginx >/dev/null 2>&1; then
  NGINX_BIN="$(command -v nginx)"
fi

if [ -z "${NGINX_BIN}" ]; then
  warn "nginx not found."
else
  if ! "${NGINX_BIN}" -V 2>&1 | grep -q "nginx-rtmp-module"; then
    warn "nginx found but RTMP module missing."
  fi
fi

if [ ! -f "${ROOT_DIR}/data/restream.json" ]; then
  warn "Missing data/restream.json"
fi
if [ ! -f "${ROOT_DIR}/data/restream.conf" ]; then
  warn "Missing data/restream.conf"
fi

if command -v lsof >/dev/null 2>&1; then
  lsof -nP -iTCP:8080 -sTCP:LISTEN >/dev/null 2>&1 || warn "Port 8080 is not listening."
  lsof -nP -iTCP:1935 -sTCP:LISTEN >/dev/null 2>&1 || warn "Port 1935 is not listening."
  lsof -nP -iTCP:9090 -sTCP:LISTEN >/dev/null 2>&1 || warn "Port 9090 is not listening."
fi

if command -v curl >/dev/null 2>&1; then
  curl -fsS "http://localhost:8080/" >/dev/null 2>&1 || warn "HTTP check failed: /"
  curl -fsS "http://localhost:8080/admin/login.html" >/dev/null 2>&1 || warn "HTTP check failed: /admin/login.html"
  admin_code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:9090/api/session" || true)"
  if [[ "${admin_code}" != "200" && "${admin_code}" != "401" ]]; then
    warn "Admin API check failed (HTTP ${admin_code:-0})"
  fi
fi

if [[ "${OK}" == "true" ]]; then
  log "All checks passed."
  exit 0
fi

warn "Some checks failed. Review the warnings above."
exit 1
