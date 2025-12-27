#!/bin/bash
cd "$(dirname "$0")"
echo "Stopping Streaming Server..."
nginx -p "$PWD" -c conf/nginx.local.conf -s stop 2>/dev/null
echo ""
echo "Server Stopped!"
