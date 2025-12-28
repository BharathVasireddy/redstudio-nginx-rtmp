param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

$Root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$Ok = $true

function Warn($msg) {
    Write-Warning $msg
    $script:Ok = $false
}

Write-Host ">> Running local diagnostics..."

$nginxExe = Join-Path $Root "nginx.exe"
if (Test-Path $nginxExe) {
    try {
        $out = & $nginxExe -V 2>&1
        if ($out -notmatch "nginx-rtmp-module") {
            Warn "nginx.exe found but RTMP module missing."
        }
    } catch {
        Warn "Unable to read nginx.exe version."
    }
} else {
    Warn "nginx.exe not found in repo root."
}

$restreamJson = Join-Path $Root "data\restream.json"
$restreamConf = Join-Path $Root "data\restream.conf"
if (!(Test-Path $restreamJson)) { Warn "Missing data\\restream.json" }
if (!(Test-Path $restreamConf)) { Warn "Missing data\\restream.conf" }

try {
    $ports = @(8080, 1935, 9090)
    foreach ($port in $ports) {
        $listening = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue
        if (-not $listening) { Warn "Port $port is not listening." }
    }
} catch {
    # ignore if Get-NetTCPConnection not available
}

try {
    Invoke-WebRequest -Uri "http://localhost:8080/" -UseBasicParsing -TimeoutSec 3 | Out-Null
} catch { Warn "HTTP check failed: /" }
try {
    Invoke-WebRequest -Uri "http://localhost:8080/admin/login.html" -UseBasicParsing -TimeoutSec 3 | Out-Null
} catch { Warn "HTTP check failed: /admin/login.html" }
try {
    $res = Invoke-WebRequest -Uri "http://127.0.0.1:9090/api/session" -UseBasicParsing -TimeoutSec 3
    $code = $res.StatusCode
} catch {
    try {
        $code = $_.Exception.Response.StatusCode.value__
    } catch {
        $code = 0
    }
}
if ($code -ne 200 -and $code -ne 401) { Warn "Admin API check failed (HTTP $code)" }

if ($Ok) {
    Write-Host ">> All checks passed."
    exit 0
}

Write-Warning "Some checks failed. Review the warnings above."
exit 1
