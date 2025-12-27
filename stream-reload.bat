@echo off
cd /d "%~dp0"
echo Reloading Configuration...
nginx.exe -s reload
echo.
echo Config Reloaded!
pause
