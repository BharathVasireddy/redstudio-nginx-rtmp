param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$Root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$dataDir = Join-Path $Root "data"
$jsonFile = Join-Path $dataDir "restream.json"
$confFile = Join-Path $dataDir "restream.conf"
$confCopy = Join-Path $Root "conf\data\restream.conf"
$defaultConfig = Join-Path $Root "config\restream.default.json"
$nginxExe = Join-Path $Root "nginx.exe"
$restart = ($env:RESTART_NGINX -eq "1")

function Get-PythonCmd {
    $cmd = Get-Command python3 -ErrorAction SilentlyContinue
    if ($cmd -and $cmd.Path -notmatch "WindowsApps") { return @{ Exe = $cmd.Path; Args = @() } }
    $cmd = Get-Command python -ErrorAction SilentlyContinue
    if ($cmd -and $cmd.Path -notmatch "WindowsApps") { return @{ Exe = $cmd.Path; Args = @() } }
    $cmd = Get-Command py -ErrorAction SilentlyContinue
    if ($cmd -and $cmd.Path -notmatch "WindowsApps") { return @{ Exe = $cmd.Path; Args = @("-3") } }
    return $null
}

New-Item -ItemType Directory -Force -Path $dataDir | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $Root "conf\data") | Out-Null

if (!(Test-Path $jsonFile)) {
    Copy-Item $defaultConfig $jsonFile -Force
}

$py = Get-PythonCmd
if (-not $py) {
    Write-Error "python not found. Install Python and retry."
    exit 1
}

& $py.Exe @($py.Args + @((Join-Path $Root "scripts\restream-generate.py"), $jsonFile, $confFile)) | Out-Null
Copy-Item $confFile $confCopy -Force

if (!(Test-Path $nginxExe)) {
    Write-Error "nginx.exe not found in repo root."
    exit 1
}

& $nginxExe -p $Root -c conf\nginx.local.conf -t | Out-Null

if ($restart) {
    & $nginxExe -p $Root -c conf\nginx.local.conf -s stop | Out-Null
    Start-Process -FilePath $nginxExe -ArgumentList "-p `"$Root`" -c conf\nginx.local.conf" -WorkingDirectory $Root | Out-Null
} else {
    & $nginxExe -p $Root -c conf\nginx.local.conf -s reload | Out-Null
}
