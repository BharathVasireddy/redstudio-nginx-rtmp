@echo off
setlocal EnableDelayedExpansion
title Red Studio Streaming System - Auto-Launcher

REM Configuration
set NGINX_BIN=nginx.exe
set TUNNEL_NAME=redstudio
set TUNNEL_BIN="C:\Program Files (x86)\cloudflared\cloudflared.exe"

cls
echo ========================================================
echo   RED STUDIO STREAMING SYSTEM - WATCHDOG v2.0
echo ========================================================
echo.

REM --- PHASE 1: CLEANUP ---
echo [1/4] Checking environment...
echo       - Stopping any old server processes...
taskkill /f /im nginx.exe >nul 2>&1
taskkill /f /im cloudflared.exe >nul 2>&1
echo       - Done.

REM --- PHASE 2: CHECKS ---
if not exist "%NGINX_BIN%" (
    echo [ERROR] nginx.exe not found!
    goto :ERROR
)

if not exist logs mkdir logs 2>nul
if not exist temp\hls mkdir temp\hls 2>nul
echo       - Folders verified.

REM --- PHASE 3: LAUNCH ---
echo.
echo [2/4] Starting Server Engine...
start "Red Studio Engine" /min "%NGINX_BIN%"
timeout /t 2 /nobreak >nul

REM Verify NGINX is running
tasklist /FI "IMAGENAME eq nginx.exe" 2>NUL | find /I /N "nginx.exe">NUL
if "%ERRORLEVEL%"=="0" (
    echo       [OK] Engine Started.
) else (
    echo [ERROR] Engine failed to start.
    echo         Check logs/error.log for details.
    goto :ERROR
)

REM --- PHASE 3.5: ADMIN API SERVER ---
echo.
echo [2.5/4] Starting Admin API Server...
if exist "api\package.json" (
    pushd api
    start "Admin API" /min cmd /c "node server.js"
    popd
    timeout /t 2 /nobreak >nul
    echo       [OK] Admin API Started on http://localhost:3000
) else (
    echo [WARNING] Admin API not found. Skipping.
)

echo.
echo [3/4] Establishing Secure Tunnel...
if exist %TUNNEL_BIN% (
    start "Secure Tunnel" /min %TUNNEL_BIN% tunnel run %TUNNEL_NAME%
    echo       [OK] Tunnel Started.
) else (
    echo [WARNING] Cloudflared not found. Tunnel skipped.
)

REM --- PHASE 4: WATCHDOG LOOP ---
cls
color 0A
echo.
echo ========================================================
echo   [ ONLINE ]  SYSTEM IS LIVE AND PROTECTED
echo ========================================================
echo.
echo   1. Broadcast URL:   rtmp://localhost/live
echo   2. Stream Key:      stream?user=streamadmin^&pass=YOUR_KEY
echo.
echo   3. Admin Dashboard: http://localhost:8080/admin.html
echo   4. Admin API:       http://localhost:3000
echo.
echo   [!] KEEP THIS WINDOW OPEN
echo   [!] If the server crashes, I will restart it automatically.
echo.
echo   To stop: Double-click STOP-STREAM.bat
echo.
echo ========================================================
echo   Running Watchdog...

:WATCHDOG_LOOP
timeout /t 5 /nobreak >nul

REM Check NGINX
tasklist /FI "IMAGENAME eq nginx.exe" 2>NUL | find /I /N "nginx.exe">NUL
if "%ERRORLEVEL%"=="1" (
    echo.
    echo [CRITICAL] ENGINE CRASH DETECTED! Restarting...
    start "Red Studio Engine" /min "%NGINX_BIN%"
    echo [RECOVERED] Engine is back online.
)

REM Check Admin API (node process)
tasklist /FI "WINDOWTITLE eq Admin API*" 2>NUL | find /I /N "cmd.exe">NUL
if "%ERRORLEVEL%"=="1" (
    if exist "api\package.json" (
        pushd api
        start "Admin API" /min cmd /c "node server.js"
        popd
    )
)

goto :WATCHDOG_LOOP

:ERROR
color 0C
echo.
echo [FATAL ERROR] System failed to start.
echo Please check logs\error.log
pause
