@echo off
cd /d "%~dp0"
echo Starting Streaming Server...
if not exist data mkdir data
if not exist data\restream.json copy config\restream.default.json data\restream.json >nul
if not exist logs mkdir logs
if not exist conf\data mkdir conf\data

set PYTHON_EXE=
set PYTHON_ARGS=
where python3 >nul 2>&1 && set PYTHON_EXE=python3
if "%PYTHON_EXE%"=="" (
  where python >nul 2>&1 && set PYTHON_EXE=python
)
if "%PYTHON_EXE%"=="" (
  where py >nul 2>&1 && set PYTHON_EXE=py && set PYTHON_ARGS=-3
)

if not "%PYTHON_EXE%"=="" (
  %PYTHON_EXE% %PYTHON_ARGS% scripts\restream-generate.py data\restream.json data\restream.conf >nul 2>&1
) else (
  if not exist data\restream.conf echo ## Auto-generated (python not found) > data\restream.conf
)
copy /y data\restream.conf conf\data\restream.conf >nul 2>&1
if not exist data\public-hls.conf echo set $public_hls 1;> data\public-hls.conf
if not exist data\public-config.json echo {"public_live":true,"public_hls":true}> data\public-config.json

if not exist data\admin.credentials (
  set ADMIN_PASS=
  for /f %%p in ('powershell -NoProfile -Command "$c='ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789';$b=New-Object byte[] 24;[System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($b);$s= -join ($b|%%{$c[$_%%$c.Length]});$s.Substring(0,18)"') do set ADMIN_PASS=%%p
  if "%ADMIN_PASS%"=="" set ADMIN_PASS=admin
  echo user=admin> data\admin.credentials
  echo password=%ADMIN_PASS%>> data\admin.credentials
)

start "" nginx.exe -p "%~dp0" -c conf\nginx.local.conf
if not "%PYTHON_EXE%"=="" (
  start "Admin API" cmd /c "%PYTHON_EXE% %PYTHON_ARGS% scripts\admin-api.py > logs\admin-api.log 2>&1"
)
echo.
echo Server Started!
echo --------------------------------------------
echo Dashboard: http://localhost:8080/
echo Admin: http://localhost:8080/admin/
echo Admin Credentials: data\admin.credentials
echo Stream Key: any (local only)
echo URL: rtmp://localhost/ingest
echo --------------------------------------------
pause
