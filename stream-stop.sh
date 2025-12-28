#!/bin/bash
cd "$(dirname "$0")"
echo "Stopping Streaming Server..."
NGINX_BIN=""
if [ -x "/usr/local/nginx/sbin/nginx" ]; then
  NGINX_BIN="/usr/local/nginx/sbin/nginx"
elif command -v nginx >/dev/null 2>&1; then
  NGINX_BIN="$(command -v nginx)"
fi

if [ -n "${NGINX_BIN}" ]; then
  "${NGINX_BIN}" -p "$PWD" -c conf/nginx.local.conf -s stop 2>/dev/null
fi
echo ""
echo "Server Stopped!"
