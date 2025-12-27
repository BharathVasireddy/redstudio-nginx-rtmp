@echo off
cd /d "%~dp0"
echo Starting Streaming Server...
start "" nginx.exe
echo.
echo Server Started!
echo --------------------------------------------
echo Dashboard: http://localhost:8080/
echo Stream Key: live  
echo URL: rtmp://localhost/multistream
echo --------------------------------------------
pause
