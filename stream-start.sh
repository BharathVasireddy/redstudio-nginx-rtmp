#!/bin/bash
cd "$(dirname "$0")"
echo "Starting Streaming Server..."
nginx -p "$PWD" -c conf/nginx.local.conf
echo ""
echo "Server Started!"
echo "--------------------------------------------"
echo "Dashboard: http://localhost:8080/"
echo "Stream Key: stream"
echo "URL: rtmp://localhost/live"
echo "--------------------------------------------"
