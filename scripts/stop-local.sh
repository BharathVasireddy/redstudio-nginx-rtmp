#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "Stopping local services..."

NGINX_BIN=""
if [ -x "/usr/local/nginx/sbin/nginx" ]; then
  NGINX_BIN="/usr/local/nginx/sbin/nginx"
elif command -v nginx >/dev/null 2>&1; then
  NGINX_BIN="$(command -v nginx)"
fi

if [ -n "${NGINX_BIN}" ]; then
  "${NGINX_BIN}" -p "${ROOT_DIR}" -c conf/nginx.local.conf -s stop 2>/dev/null || true
fi

PID_FILE="${ROOT_DIR}/logs/admin-api.pid"
if [ -f "${PID_FILE}" ]; then
  ADMIN_PID="$(cat "${PID_FILE}" 2>/dev/null || true)"
  if [ -n "${ADMIN_PID}" ] && kill -0 "${ADMIN_PID}" >/dev/null 2>&1; then
    kill "${ADMIN_PID}" >/dev/null 2>&1 || true
  fi
  rm -f "${PID_FILE}"
fi

if command -v lsof >/dev/null 2>&1; then
  PIDS="$(lsof -nP -iTCP:9090 -sTCP:LISTEN 2>/dev/null | awk 'NR>1 {print $2}' | sort -u || true)"
  for PID in ${PIDS}; do
    CMD="$(ps -p "${PID}" -o command= 2>/dev/null || true)"
    if [[ "${CMD}" == *"admin-api.py"* || "${CMD}" == *"${ROOT_DIR}"* ]]; then
      kill "${PID}" >/dev/null 2>&1 || true
    fi
  done
  if [[ -z "${PIDS}" ]] && command -v sudo >/dev/null 2>&1; then
    PIDS="$(sudo lsof -nP -iTCP:9090 -sTCP:LISTEN 2>/dev/null | awk 'NR>1 {print $2}' | sort -u || true)"
    for PID in ${PIDS}; do
      kill "${PID}" >/dev/null 2>&1 || sudo kill "${PID}" >/dev/null 2>&1 || true
    done
  fi
fi

echo "Local services stopped."
