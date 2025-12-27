@echo off
REM DuckDNS IP Update Script for redstudious.duckdns.org
REM This script updates your dynamic IP with DuckDNS

setlocal

set DOMAIN=redstudious
set TOKEN=539d8f28-36f7-4c76-bf21-47b39f303f2f
set LOGFILE=%~dp0logs\duckdns.log

REM Create logs directory if it doesn't exist
if not exist "%~dp0logs" mkdir "%~dp0logs"

REM Get current timestamp
for /f "tokens=2 delims==" %%a in ('wmic OS Get localdatetime /value') do set "dt=%%a"
set "timestamp=%dt:~0,4%-%dt:~4,2%-%dt:~6,2% %dt:~8,2%:%dt:~10,2%:%dt:~12,2%"

REM Update DuckDNS
curl -s "https://www.duckdns.org/update?domains=%DOMAIN%&token=%TOKEN%&ip=" > "%TEMP%\duckdns_result.txt"
set /p RESULT=<"%TEMP%\duckdns_result.txt"

REM Log the result
echo [%timestamp%] DuckDNS update: %RESULT% >> "%LOGFILE%"

if "%RESULT%"=="OK" (
    echo DuckDNS updated successfully!
) else (
    echo DuckDNS update failed. Check your token.
)

del "%TEMP%\duckdns_result.txt" 2>nul
endlocal
