@echo off
REM push-update.bat - Run this on Windows to push changes to Oracle Cloud
REM Usage: push-update.bat "Your commit message"

setlocal

echo.
echo ====================================
echo   Red Studio - Push Updates
echo ====================================
echo.

REM Check for commit message
if "%~1"=="" (
    set /p "COMMIT_MSG=Enter commit message: "
) else (
    set "COMMIT_MSG=%~1"
)

REM Add all changes
echo Adding changes...
git add -A

REM Commit with message
echo Committing: %COMMIT_MSG%
git commit -m "%COMMIT_MSG%"

REM Push to remote
echo Pushing to GitHub...
git push origin main

echo.
echo ====================================
echo   Pushed successfully!
echo ====================================
echo.
echo Now SSH into Oracle Cloud and run:
echo   cd /var/www/nginx-rtmp-module
echo   ./deploy.sh
echo.

pause
