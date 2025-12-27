@echo off
cd /d "%~dp0"
echo Reloading Configuration...
nginx.exe -p "%~dp0" -c conf\nginx.local.conf -s reload
echo.
echo Config Reloaded!
pause
