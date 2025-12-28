# Windows (Local)

## 1) Clone the repository

- Install Git for Windows: https://git-scm.com/download/win
- In Command Prompt or PowerShell:

```
git clone https://github.com/BharathVasireddy/redstudio-nginx-rtmp.git
cd redstudio-nginx-rtmp
```

If you prefer, download the ZIP from GitHub and extract it.

## 2) Start the server

Recommended (PowerShell):

```
scripts\setup-local.bat -ForceStop
```

If PowerShell blocks scripts, run:

```
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\setup-local.ps1 -ForceStop
```

If the admin UI does not load, the script will try to install Python via `winget`/`choco`. If those are missing, it will download the official installer via PowerShell. If it still fails, install Python 3 from https://www.python.org/downloads/ and disable the Windows Store "App execution aliases" for python.

If you enable YouTube (or other restreams) on Windows and apply fails, make sure `nginx.exe` is present in the repo root.

Or double-click:

```
stream-start.bat
```

Admin credentials are stored at `data\admin.credentials`.

## 3) Stream locally

- Dashboard: `http://localhost:8080/`
- Server: `rtmp://localhost/ingest`
- Stream key: any value (local does not enforce ingest keys by default)

## 4) Stop the server

```
stream-stop.bat
```

Recommended stop:

```
scripts\stop-local.bat
```

Diagnostics:

```
scripts\doctor-local.bat
```
