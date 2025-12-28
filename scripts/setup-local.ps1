param(
    [switch]$ForceStop,
    [switch]$NoStart,
    [switch]$NoAdmin
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Log {
    param([string]$Message)
    Write-Host ">> $Message"
}

function Write-Warn {
    param([string]$Message)
    Write-Warning $Message
}

function Die {
    param([string]$Message)
    Write-Error $Message
    exit 1
}

$Root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path

function Get-PythonCmd {
    $cmd = Get-Command python3 -ErrorAction SilentlyContinue
    if ($cmd -and $cmd.Path -notmatch "WindowsApps") { return @{ Exe = $cmd.Path; Args = @() } }
    $cmd = Get-Command python -ErrorAction SilentlyContinue
    if ($cmd -and $cmd.Path -notmatch "WindowsApps") { return @{ Exe = $cmd.Path; Args = @() } }
    $cmd = Get-Command py -ErrorAction SilentlyContinue
    if ($cmd -and $cmd.Path -notmatch "WindowsApps") { return @{ Exe = $cmd.Path; Args = @("-3") } }
    return $null
}

function Ensure-Dirs {
    $paths = @(
        (Join-Path $Root "data"),
        (Join-Path $Root "temp\hls"),
        (Join-Path $Root "logs"),
        (Join-Path $Root "conf\data")
    )
    foreach ($path in $paths) {
        New-Item -ItemType Directory -Force -Path $path | Out-Null
    }
}

function Ensure-RestreamConfig {
    $restreamJson = Join-Path $Root "data\restream.json"
    $restreamConf = Join-Path $Root "data\restream.conf"
    $restreamDefault = Join-Path $Root "config\restream.default.json"
    $restreamConfCopy = Join-Path $Root "conf\data\restream.conf"

    if (!(Test-Path $restreamJson)) {
        Copy-Item $restreamDefault $restreamJson -Force
    }

    $py = Get-PythonCmd
    if ($py) {
        & $py.Exe @($py.Args + @((Join-Path $Root "scripts\restream-generate.py"), $restreamJson, $restreamConf)) | Out-Null
    } else {
        if (!(Test-Path $restreamConf)) {
            "## Auto-generated (python not found)" | Out-File -FilePath $restreamConf -Encoding ASCII -Force
        }
        Write-Warn "python not found. Admin API and restream config generation may be limited."
    }

    Copy-Item $restreamConf $restreamConfCopy -Force
}

function New-Password {
    $chars = "ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789"
    $bytes = New-Object byte[] 24
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    $result = New-Object System.Text.StringBuilder
    foreach ($b in $bytes) {
        [void]$result.Append($chars[$b % $chars.Length])
    }
    return $result.ToString().Substring(0, 18)
}

function Ensure-AdminCreds {
    $creds = Join-Path $Root "data\admin.credentials"
    if (Test-Path $creds) {
        $user = ""
        $pass = ""
        foreach ($line in Get-Content $creds -ErrorAction SilentlyContinue) {
            if ($line -match "^user=") { $user = $line.Substring(5) }
            if ($line -match "^password=") { $pass = $line.Substring(9) }
        }
        return @{ Created = $false; Path = $creds; User = $user; Pass = $pass }
    }
    $user = "admin"
    $pass = New-Password
    "user=$user`npassword=$pass" | Out-File -FilePath $creds -Encoding ASCII -Force
    return @{ Created = $true; Path = $creds; User = $user; Pass = $pass }
}

function Get-PortPids {
    param([int]$Port)
    try {
        $conns = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction Stop
        return $conns.OwningProcess | Sort-Object -Unique
    } catch {
        $lines = netstat -ano -p tcp | Select-String -Pattern "LISTENING"
        $pids = @()
        foreach ($line in $lines) {
            $parts = ($line -replace "\s+", " ").Trim().Split(" ")
            if ($parts.Length -ge 5 -and $parts[1].EndsWith(":$Port")) {
                $pids += [int]$parts[4]
            }
        }
        return $pids | Sort-Object -Unique
    }
}

function Stop-Port8080 {
    $pids = @(Get-PortPids -Port 8080)
    if (-not $pids -or $pids.Count -eq 0) {
        return
    }
    Write-Warn "Port 8080 is already in use."
    if (-not $ForceStop) {
        $nonNginx = @()
        foreach ($pid in $pids) {
            try {
                $proc = Get-Process -Id $pid -ErrorAction Stop
                if ($proc.Name -ne "nginx") {
                    $nonNginx += $proc.Name
                }
            } catch {
                $nonNginx += "unknown"
            }
        }
        if ($nonNginx.Count -gt 0) {
            Die "Port 8080 is in use by: $($nonNginx -join ', '). Re-run with -ForceStop to stop it."
        }
        Write-Log "Detected nginx on port 8080. Stopping it automatically."
    }
    $nginxExe = Join-Path $Root "nginx.exe"
    if (Test-Path $nginxExe) {
        & $nginxExe -p $Root -c conf\nginx.local.conf -s stop 2>$null | Out-Null
    }
    Start-Sleep -Seconds 1
    $pids = Get-PortPids -Port 8080
    if ($pids -and $pids.Count -gt 0) {
        if ($ForceStop) {
            foreach ($pid in $pids) {
                Stop-Process -Id $pid -Force -ErrorAction SilentlyContinue
            }
        } else {
            Get-Process -Name nginx -ErrorAction SilentlyContinue | Stop-Process -Force
        }
        Start-Sleep -Seconds 1
    }
    $pids = Get-PortPids -Port 8080
    if ($pids -and $pids.Count -gt 0) {
        Die "Port 8080 is still in use. Stop the other service and retry."
    }
}

function Stop-Port9090 {
    $pids = @(Get-PortPids -Port 9090)
    if (-not $pids -or $pids.Count -eq 0) {
        return
    }
    Write-Warn "Port 9090 is already in use."
    if (-not $ForceStop) {
        Die "Port 9090 is in use. Re-run with -ForceStop to stop it."
    }
    foreach ($pid in $pids) {
        Stop-Process -Id $pid -Force -ErrorAction SilentlyContinue
    }
    Start-Sleep -Seconds 1
    $pids = Get-PortPids -Port 9090
    if ($pids -and $pids.Count -gt 0) {
        Die "Port 9090 is still in use. Stop the other service and retry."
    }
}

function Start-Nginx {
    $nginxExe = Join-Path $Root "nginx.exe"
    if (!(Test-Path $nginxExe)) {
        Die "nginx.exe not found in repo root."
    }
    Start-Process -FilePath $nginxExe -ArgumentList "-p `"$Root`" -c conf\nginx.local.conf" -WorkingDirectory $Root | Out-Null
}

function Check-NginxRtmp {
    $nginxExe = Join-Path $Root "nginx.exe"
    if (!(Test-Path $nginxExe)) {
        return
    }
    try {
        $output = & $nginxExe -V 2>&1
        if ($output -notmatch "nginx-rtmp-module") {
            Write-Warn "nginx.exe may not include RTMP. If streaming fails, rebuild nginx with RTMP."
        }
    } catch {
        # ignore version probe failures
    }
}

function Start-AdminApi {
    if ($NoAdmin) {
        Write-Log "Admin API start skipped (--NoAdmin)."
        return
    }
    $py = Get-PythonCmd
    if (-not $py) {
        Write-Warn "python not found; admin API will not start. Install Python from python.org and re-run."
        return
    }
    $logOut = Join-Path $Root "logs\admin-api.out.log"
    $logErr = Join-Path $Root "logs\admin-api.err.log"
    $pidFile = Join-Path $Root "logs\admin-api.pid"
    $env:PYTHONUNBUFFERED = "1"
    $proc = Start-Process -FilePath $py.Exe -ArgumentList ($py.Args + @((Join-Path $Root "scripts\admin-api.py"))) `
        -WorkingDirectory $Root -WindowStyle Hidden -RedirectStandardOutput $logOut -RedirectStandardError $logErr -PassThru
    $proc.Id | Out-File -FilePath $pidFile -Encoding ASCII -Force
    Start-Sleep -Milliseconds 700
}

function Health-Check {
    $urls = @("http://localhost:8080/", "http://localhost:8080/admin/login.html")
    foreach ($url in $urls) {
        try {
            Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 3 | Out-Null
        } catch {
            Write-Warn "Health check failed: $url"
        }
    }
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
    if ($code -ne 200 -and $code -ne 401) { Write-Warn "Health check failed: admin API (HTTP $code)" }
    try {
        $ports = @(1935, 8080, 9090)
        foreach ($port in $ports) {
            $listening = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue
            if (-not $listening) { Write-Warn "Port $port is not listening." }
        }
    } catch {
        # ignore
    }
}

Write-Log "Starting Windows local setup in $Root"
Ensure-Dirs
Stop-Port8080
Stop-Port9090
Ensure-RestreamConfig
$creds = Ensure-AdminCreds
Check-NginxRtmp

if (-not $NoStart) {
    Start-Nginx
    Start-AdminApi
    Start-Sleep -Seconds 1
    Health-Check
}

Write-Host ""
Write-Host "--------------------------------------------"
Write-Host "Dashboard: http://localhost:8080/"
Write-Host "Admin: http://localhost:8080/admin/"
if ($creds.Created -eq $true) {
    Write-Host "Admin User: $($creds.User)"
    Write-Host "Admin Pass: $($creds.Pass)"
} else {
    if ($creds.User -and $creds.Pass) {
        Write-Host "Admin User: $($creds.User)"
        Write-Host "Admin Pass: $($creds.Pass)"
    } else {
        Write-Host "Admin Credentials: $($creds.Path)"
    }
}
Write-Host "RTMP URL: rtmp://localhost/ingest"
Write-Host "--------------------------------------------"
