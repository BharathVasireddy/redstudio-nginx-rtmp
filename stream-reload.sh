#!/bin/bash
cd "$(dirname "$0")"
echo "Reloading Configuration..."
nginx -p "$PWD" -c conf/nginx.local.conf -s reload
echo ""
echo "Config Reloaded!"
