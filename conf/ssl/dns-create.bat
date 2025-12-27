@echo off
REM DuckDNS TXT Record Creation Script for win-acme DNS-01 validation
REM Called by win-acme to create _acme-challenge TXT record

setlocal

REM Parameters passed by win-acme:
REM %1 = Identifier (domain being validated)
REM %2 = Record name (e.g., _acme-challenge.redstudious.duckdns.org)
REM %3 = Token/Challenge value to put in TXT record

set DOMAIN=redstudious
set TOKEN=539d8f28-36f7-4c76-bf21-47b39f303f2f
set TXT_VALUE=%~3

REM Update DuckDNS with TXT record
curl -s "https://www.duckdns.org/update?domains=%DOMAIN%&token=%TOKEN%&txt=%TXT_VALUE%&verbose=true"

REM Give DNS time to propagate
timeout /t 30 /nobreak >nul

endlocal
exit /b 0
