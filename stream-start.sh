#!/bin/bash
cd "$(dirname "$0")"
echo "Starting Streaming Server..."
mkdir -p data
if [ ! -f data/restream.json ]; then
  cp config/restream.default.json data/restream.json
fi
if [ ! -f data/restream.conf ]; then
  python3 scripts/restream-generate.py data/restream.json data/restream.conf
fi
nginx -p "$PWD" -c conf/nginx.local.conf
echo ""
echo "Server Started!"
echo "--------------------------------------------"
echo "Dashboard: http://localhost:8080/"
echo "Stream Key: stream"
echo "URL: rtmp://localhost/live"
echo "--------------------------------------------"
