@echo off
cd /d "%~dp0"
echo Stopping Streaming Server...
nginx.exe -s stop 2>nul
taskkill /F /IM nginx.exe /T 2>nul
echo.
echo Server Stopped!
pause
