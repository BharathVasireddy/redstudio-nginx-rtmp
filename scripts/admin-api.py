#!/usr/bin/env python3
import json
import os
import secrets
import shutil
import subprocess
import time
import urllib.request
from urllib.parse import parse_qs, urlparse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Optional, Dict, Tuple

try:
    import crypt
except ImportError:  # pragma: no cover - not available on some platforms
    crypt = None

ROOT_DIR = Path(__file__).resolve().parents[1]
DATA_DIR = ROOT_DIR / "data"
CONFIG_PATH = DATA_DIR / "restream.json"
DEFAULT_CONFIG = ROOT_DIR / "config" / "restream.default.json"
IS_WINDOWS = os.name == "nt"
APPLY_SCRIPT = ROOT_DIR / "scripts" / ("restream-apply.ps1" if IS_WINDOWS else "restream-apply.sh")
STREAM_APP = os.environ.get("STREAM_APP", "live")
STREAM_NAME = os.environ.get("STREAM_NAME", "stream")
CONTROL_URL = os.environ.get(
    "CONTROL_URL",
    f"http://127.0.0.1/control/drop/publisher?app={STREAM_APP}&name={STREAM_NAME}",
)
SESSION_COOKIE = os.environ.get("ADMIN_SESSION_COOKIE", "rs_admin")
SESSION_TTL = int(os.environ.get("ADMIN_SESSION_TTL", "86400"))
SESSIONS: Dict[str, Dict[str, object]] = {}
CPU_SAMPLE: Optional[Tuple[int, int, float]] = None
NET_SAMPLE: Optional[Tuple[int, int, float]] = None


def now_ts() -> int:
    return int(time.time())


def sanitize_destination(dest: dict) -> dict:
    allowed_keys = {"id", "name", "enabled", "rtmp_url", "stream_key"}
    clean = {k: dest.get(k) for k in allowed_keys}
    clean["enabled"] = bool(clean.get("enabled"))
    for key in ["id", "name", "rtmp_url", "stream_key"]:
        value = clean.get(key)
        if value is None:
            clean[key] = ""
            continue
        value = str(value).strip()
        if any(ch in value for ch in ["\n", "\r", ";"]):
            value = ""
        clean[key] = value
    return clean


def load_config() -> dict:
    if not CONFIG_PATH.exists() and DEFAULT_CONFIG.exists():
        CONFIG_PATH.write_text(DEFAULT_CONFIG.read_text(encoding="utf-8"), encoding="utf-8")
    if not CONFIG_PATH.exists():
        return {"destinations": [], "ingest_key": ""}
    payload = json.loads(CONFIG_PATH.read_text(encoding="utf-8"))
    if "ingest_key" not in payload:
        payload["ingest_key"] = ""
    return payload


def save_config(payload: dict) -> None:
    existing = load_config()
    destinations = payload.get("destinations", [])
    if not isinstance(destinations, list):
        raise ValueError("destinations must be a list")
    cleaned = [sanitize_destination(d) for d in destinations if isinstance(d, dict)]
    ingest_key = payload.get("ingest_key", existing.get("ingest_key", ""))
    if ingest_key is None:
        ingest_key = ""
    ingest_key = str(ingest_key).strip()
    if any(ch in ingest_key for ch in ["\n", "\r", ";", " "]):
        ingest_key = ""
    CONFIG_PATH.write_text(
        json.dumps({"destinations": cleaned, "ingest_key": ingest_key}, indent=2),
        encoding="utf-8",
    )


def load_ingest_key() -> str:
    return str(load_config().get("ingest_key", "")).strip()


def read_metrics() -> dict:
    global CPU_SAMPLE, NET_SAMPLE
    if os.name != "posix" or not Path("/proc/stat").exists():
        return {"supported": False}

    metrics: Dict[str, object] = {"supported": True}
    now = time.time()

    # CPU usage
    try:
        with open("/proc/stat", "r", encoding="utf-8") as handle:
            line = handle.readline()
        parts = line.split()
        values = [int(v) for v in parts[1:]]
        total = sum(values)
        idle = values[3] + (values[4] if len(values) > 4 else 0)
        usage_pct = None
        if CPU_SAMPLE:
            prev_total, prev_idle, prev_ts = CPU_SAMPLE
            total_delta = total - prev_total
            idle_delta = idle - prev_idle
            if total_delta > 0:
                usage_pct = max(0.0, min(100.0, (1 - idle_delta / total_delta) * 100))
        CPU_SAMPLE = (total, idle, now)
        metrics["cpu"] = {"usage_pct": usage_pct}
    except Exception:
        metrics["cpu"] = {"usage_pct": None}

    # Memory
    mem_total = None
    mem_available = None
    try:
        with open("/proc/meminfo", "r", encoding="utf-8") as handle:
            for line in handle:
                if line.startswith("MemTotal:"):
                    mem_total = int(line.split()[1])
                elif line.startswith("MemAvailable:"):
                    mem_available = int(line.split()[1])
                if mem_total and mem_available:
                    break
        if mem_total is not None and mem_available is not None:
            used = mem_total - mem_available
            metrics["memory"] = {
                "total_mb": round(mem_total / 1024, 1),
                "used_mb": round(used / 1024, 1),
                "used_pct": round((used / mem_total) * 100, 1),
            }
    except Exception:
        metrics["memory"] = {"total_mb": None, "used_mb": None, "used_pct": None}

    # Disk
    try:
        usage = shutil.disk_usage(str(ROOT_DIR))
        total_gb = usage.total / (1024**3)
        used_gb = usage.used / (1024**3)
        metrics["disk"] = {
            "total_gb": round(total_gb, 1),
            "used_gb": round(used_gb, 1),
            "used_pct": round((used_gb / total_gb) * 100, 1) if total_gb > 0 else None,
        }
    except Exception:
        metrics["disk"] = {"total_gb": None, "used_gb": None, "used_pct": None}

    # Network
    try:
        rx_total = 0
        tx_total = 0
        with open("/proc/net/dev", "r", encoding="utf-8") as handle:
            lines = handle.readlines()[2:]
        for line in lines:
            iface, data = line.split(":", 1)
            iface = iface.strip()
            if iface == "lo":
                continue
            fields = data.split()
            rx_total += int(fields[0])
            tx_total += int(fields[8])
        rx_mbps = None
        tx_mbps = None
        if NET_SAMPLE:
            prev_rx, prev_tx, prev_ts = NET_SAMPLE
            delta = max(0.001, now - prev_ts)
            rx_mbps = round(((rx_total - prev_rx) * 8) / (1_000_000 * delta), 2)
            tx_mbps = round(((tx_total - prev_tx) * 8) / (1_000_000 * delta), 2)
        NET_SAMPLE = (rx_total, tx_total, now)
        metrics["network"] = {
            "rx_mbps": rx_mbps,
            "tx_mbps": tx_mbps,
            "rx_bytes": rx_total,
            "tx_bytes": tx_total,
        }
    except Exception:
        metrics["network"] = {"rx_mbps": None, "tx_mbps": None}

    # Uptime + loadavg
    try:
        with open("/proc/uptime", "r", encoding="utf-8") as handle:
            uptime_sec = float(handle.read().split()[0])
        metrics["uptime_sec"] = int(uptime_sec)
    except Exception:
        metrics["uptime_sec"] = None

    try:
        load = os.getloadavg()
        metrics["loadavg"] = [round(v, 2) for v in load]
    except Exception:
        metrics["loadavg"] = None

    return metrics


def parse_plain_credentials() -> Optional[Tuple[str, str]]:
    creds_path = DATA_DIR / "admin.credentials"
    if not creds_path.exists():
        return None
    user = ""
    password = ""
    for line in creds_path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if line.startswith("user="):
            user = line.split("=", 1)[1].strip()
        elif line.startswith("password="):
            password = line.split("=", 1)[1].strip()
    if user and password:
        return user, password
    return None


def verify_password(user: str, password: str) -> bool:
    creds = parse_plain_credentials()
    if creds and user == creds[0] and password == creds[1]:
        return True
    htpasswd_path = DATA_DIR / "admin.htpasswd"
    if not htpasswd_path.exists():
        return False
    if crypt is None:
        return False
    for line in htpasswd_path.read_text(encoding="utf-8").splitlines():
        if ":" not in line:
            continue
        name, hashed = line.split(":", 1)
        if name != user:
            continue
        try:
            return crypt.crypt(password, hashed) == hashed
        except Exception:
            return False
    return False


def create_session(user: str) -> str:
    token = secrets.token_urlsafe(32)
    SESSIONS[token] = {"user": user, "exp": now_ts() + SESSION_TTL}
    return token


def parse_cookies(header: str) -> Dict[str, str]:
    cookies = {}
    for part in header.split(";"):
        part = part.strip()
        if not part or "=" not in part:
            continue
        name, value = part.split("=", 1)
        cookies[name] = value
    return cookies


class Handler(BaseHTTPRequestHandler):
    def log_message(self, format: str, *args) -> None:
        return

    def _send_json(self, data: dict, status: int = 200, headers: Optional[Dict[str, str]] = None) -> None:
        body = json.dumps(data).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        if headers:
            for key, value in headers.items():
                self.send_header(key, value)
        self.end_headers()
        self.wfile.write(body)

    def _cookie_attrs(self) -> str:
        attrs = ["Path=/", "HttpOnly", "SameSite=Strict"]
        host = self.headers.get("Host", "")
        proto = self.headers.get("X-Forwarded-Proto", "")
        if proto == "https" or (
            host and not host.startswith("localhost") and not host.startswith("127.0.0.1")
        ):
            attrs.append("Secure")
        return "; ".join(attrs)

    def _session_user(self) -> Optional[str]:
        cookies = parse_cookies(self.headers.get("Cookie", ""))
        token = cookies.get(SESSION_COOKIE)
        if not token:
            return None
        session = SESSIONS.get(token)
        if not session:
            return None
        if session["exp"] < now_ts():
            del SESSIONS[token]
            return None
        return str(session["user"])

    def _require_auth(self) -> Optional[str]:
        user = self._session_user()
        if not user:
            self._send_json({"error": "unauthorized"}, status=401)
            return None
        return user

    def _read_json(self) -> dict:
        length = int(self.headers.get("Content-Length", 0))
        raw = self.rfile.read(length) if length else b"{}"
        return json.loads(raw.decode("utf-8"))

    def do_GET(self) -> None:
        parsed = urlparse(self.path)
        if parsed.path == "/api/session":
            user = self._require_auth()
            if user:
                self._send_json({"user": user})
            return
        if parsed.path == "/api/restream":
            if not self._require_auth():
                return
            self._send_json(load_config())
            return
        if parsed.path == "/api/ingest":
            if not self._require_auth():
                return
            self._send_json({"ingest_key": load_ingest_key()})
            return
        if parsed.path == "/api/metrics":
            if not self._require_auth():
                return
            self._send_json(read_metrics())
            return
        self._send_json({"error": "not found"}, status=404)

    def do_POST(self) -> None:
        parsed = urlparse(self.path)
        if parsed.path == "/api/login":
            try:
                payload = self._read_json()
                user = str(payload.get("user", "")).strip()
                password = str(payload.get("password", "")).strip()
                if not user or not password or not verify_password(user, password):
                    self._send_json({"error": "invalid credentials"}, status=401)
                    return
                token = create_session(user)
                headers = {
                    "Set-Cookie": f"{SESSION_COOKIE}={token}; {self._cookie_attrs()}",
                    "Cache-Control": "no-store",
                }
                self._send_json({"status": "ok"}, headers=headers)
            except Exception as exc:
                self._send_json({"error": str(exc)}, status=400)
            return
        if parsed.path == "/api/logout":
            cookies = parse_cookies(self.headers.get("Cookie", ""))
            token = cookies.get(SESSION_COOKIE)
            if token and token in SESSIONS:
                del SESSIONS[token]
            headers = {
                "Set-Cookie": f"{SESSION_COOKIE}=; {self._cookie_attrs()}; Max-Age=0",
                "Cache-Control": "no-store",
            }
            self._send_json({"status": "ok"}, headers=headers)
            return
        if parsed.path == "/api/restream":
            try:
                if not self._require_auth():
                    return
                payload = self._read_json()
                save_config(payload)
                self._send_json({"status": "ok"})
            except Exception as exc:
                self._send_json({"error": str(exc)}, status=400)
            return
        if parsed.path == "/api/ingest":
            try:
                if not self._require_auth():
                    return
                payload = self._read_json()
                current = load_config()
                save_config(
                    {
                        "destinations": current.get("destinations", []),
                        "ingest_key": payload.get("ingest_key", ""),
                    }
                )
                self._send_json({"status": "ok"})
            except Exception as exc:
                self._send_json({"error": str(exc)}, status=400)
            return
        if parsed.path == "/api/publish":
            params = parse_qs(parsed.query)
            length = int(self.headers.get("Content-Length", 0))
            if length and not params:
                body = self.rfile.read(length).decode("utf-8")
                params = parse_qs(body)
            key = ""
            if "key" in params:
                key = params.get("key", [""])[0]
            else:
                key = params.get("name", [""])[0]
            key = str(key).strip()
            stored = load_ingest_key()
            if not stored:
                self._send_json({"status": "ok"})
                return
            if key == stored:
                self._send_json({"status": "ok"})
                return
            self._send_json({"error": "forbidden"}, status=403)
            return
        if parsed.path == "/api/restream/apply":
            try:
                if not self._require_auth():
                    return
                query = parse_qs(parsed.query)
                env = os.environ.copy()
                if query.get("restart", ["0"])[0] == "1":
                    env["RESTART_NGINX"] = "1"
                if IS_WINDOWS:
                    subprocess.run(
                        [
                            "powershell",
                            "-NoProfile",
                            "-ExecutionPolicy",
                            "Bypass",
                            "-File",
                            str(APPLY_SCRIPT),
                        ],
                        check=True,
                        env=env,
                    )
                else:
                    subprocess.run(["bash", str(APPLY_SCRIPT)], check=True, env=env)
                self._send_json({"status": "applied"})
            except subprocess.CalledProcessError as exc:
                self._send_json({"error": f"apply failed: {exc}"}, status=500)
            return
        if parsed.path == "/api/stream/reconnect":
            try:
                if not self._require_auth():
                    return
                with urllib.request.urlopen(CONTROL_URL, timeout=4) as response:
                    body = response.read().decode("utf-8")
                self._send_json({"status": "reconnecting", "result": body})
            except Exception as exc:
                self._send_json({"error": f"reconnect failed: {exc}"}, status=500)
            return
        self._send_json({"error": "not found"}, status=404)


def main() -> int:
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    host = os.environ.get("ADMIN_API_HOST", "127.0.0.1")
    port = int(os.environ.get("ADMIN_API_PORT", "9090"))
    server = ThreadingHTTPServer((host, port), Handler)
    server.serve_forever()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
