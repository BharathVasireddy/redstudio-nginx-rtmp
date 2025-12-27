@echo off
REM DuckDNS TXT Record Deletion Script for win-acme DNS-01 validation
REM Called by win-acme to clean up after validation

setlocal

set DOMAIN=redstudious
set TOKEN=539d8f28-36f7-4c76-bf21-47b39f303f2f

REM Clear the TXT record
curl -s "https://www.duckdns.org/update?domains=%DOMAIN%&token=%TOKEN%&txt=&clear=true&verbose=true"

endlocal
exit /b 0
