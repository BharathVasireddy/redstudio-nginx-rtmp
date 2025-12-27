@echo off
title Stopping Red Studio Services...
echo.
echo ========================================================
echo   RED STUDIO - STOPPING SERVICES
echo ========================================================
echo.

echo [1/4] Stopping Tunnel...
taskkill /f /im cloudflared.exe >nul 2>&1
echo       - Stopped.

echo.
echo [2/4] Stopping Server Engine...
taskkill /f /im nginx.exe >nul 2>&1
echo       - Stopped.

echo.
echo [3/4] Stopping Admin API...
taskkill /fi "WINDOWTITLE eq Admin API*" /f >nul 2>&1
echo       - Stopped.

echo.
echo [4/4] Stopping Launchers...
REM Kill any other cmd windows running the launcher
taskkill /fi "WINDOWTITLE eq Red Studio Streaming System*" /f >nul 2>&1
echo       - Done.

echo.
echo ========================================================
echo   [ OK ]  ALL SERVICES STOPPED.
echo ========================================================
echo.
timeout /t 3 >nul
exit
