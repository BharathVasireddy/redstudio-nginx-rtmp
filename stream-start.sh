#!/bin/bash
cd "$(dirname "$0")"
echo "Starting Streaming Server..."
nginx
echo ""
echo "Server Started!"
echo "--------------------------------------------"
echo "Dashboard: http://localhost:8080/"
echo "Stream Key: live"
echo "URL: rtmp://localhost/multistream"
echo "--------------------------------------------"
