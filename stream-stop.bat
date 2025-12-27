@echo off
cd /d "%~dp0"
echo Stopping Streaming Server...
nginx.exe -p "%~dp0" -c conf\nginx.local.conf -s stop 2>nul
taskkill /F /IM nginx.exe /T 2>nul
echo.
echo Server Stopped!
pause
