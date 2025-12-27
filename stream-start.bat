@echo off
cd /d "%~dp0"
echo Starting Streaming Server...
start "" nginx.exe -p "%~dp0" -c conf\nginx.local.conf
echo.
echo Server Started!
echo --------------------------------------------
echo Dashboard: http://localhost:8080/
echo Stream Key: stream  
echo URL: rtmp://localhost/live
echo --------------------------------------------
pause
