@echo off
cd /d "%~dp0"
echo Starting Streaming Server...
if not exist data mkdir data
if not exist data\restream.json copy config\restream.default.json data\restream.json >nul
if not exist data\restream.conf (
  echo # Auto-generated > data\restream.conf
)
start "" nginx.exe -p "%~dp0" -c conf\nginx.local.conf
echo.
echo Server Started!
echo --------------------------------------------
echo Dashboard: http://localhost:8080/
echo Stream Key: stream  
echo URL: rtmp://localhost/live
echo --------------------------------------------
pause
