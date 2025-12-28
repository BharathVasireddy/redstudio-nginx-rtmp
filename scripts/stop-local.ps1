param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$Root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path

Write-Host "Stopping local services..."

$nginxExe = Join-Path $Root "nginx.exe"
if (Test-Path $nginxExe) {
    try {
        & $nginxExe -p $Root -c conf\nginx.local.conf -s stop 2>$null | Out-Null
    } catch {
        # ignore
    }
}

$pidFile = Join-Path $Root "logs\admin-api.pid"
if (Test-Path $pidFile) {
    $pid = Get-Content $pidFile -ErrorAction SilentlyContinue
    if ($pid) {
        try {
            Stop-Process -Id $pid -Force -ErrorAction SilentlyContinue
        } catch {
            # ignore
        }
    }
    Remove-Item $pidFile -Force -ErrorAction SilentlyContinue
}

Write-Host "Local services stopped."
