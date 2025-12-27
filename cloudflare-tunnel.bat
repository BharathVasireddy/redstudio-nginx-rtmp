@echo off
REM Start Cloudflare Permanent Tunnel for Red Studio
REM URL: https://stream.cloud9digital.in

echo Starting Cloudflare Tunnel...
echo.
echo Your streaming server will be available at:
echo   https://stream.cloud9digital.in
echo.
echo Keep this window open to maintain the tunnel.
echo.

"C:\Program Files (x86)\cloudflared\cloudflared.exe" tunnel run redstudio
