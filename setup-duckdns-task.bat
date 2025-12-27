@echo off
REM Creates a Windows Scheduled Task to run DuckDNS update every 5 minutes
REM Run this script as Administrator!

set SCRIPT_PATH=%~dp0duckdns-update.bat

echo Creating scheduled task for DuckDNS updates...
schtasks /create /tn "DuckDNS Update" /tr "\"%SCRIPT_PATH%\"" /sc minute /mo 5 /ru SYSTEM /f

if %errorlevel% equ 0 (
    echo.
    echo SUCCESS! DuckDNS will update every 5 minutes.
    echo Task name: "DuckDNS Update"
    echo.
    echo To remove this task later, run:
    echo   schtasks /delete /tn "DuckDNS Update" /f
) else (
    echo.
    echo FAILED! Make sure to run this script as Administrator.
)

pause
