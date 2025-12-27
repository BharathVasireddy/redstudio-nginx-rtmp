#!/bin/bash
cd "$(dirname "$0")"
echo "Stopping Streaming Server..."
nginx -s stop 2>/dev/null
pkill -f nginx 2>/dev/null
echo ""
echo "Server Stopped!"
