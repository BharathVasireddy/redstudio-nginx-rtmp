#!/bin/bash
cd "$(dirname "$0")"
echo "Reloading Configuration..."
nginx -s reload
echo ""
echo "Config Reloaded!"
