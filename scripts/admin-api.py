#!/usr/bin/env python3
import json
import os
import secrets
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
APPLY_SCRIPT = ROOT_DIR / "scripts" / "restream-apply.sh"
STREAM_APP = os.environ.get("STREAM_APP", "live")
STREAM_NAME = os.environ.get("STREAM_NAME", "stream")
CONTROL_URL = os.environ.get(
    "CONTROL_URL",
    f"http://127.0.0.1/control/drop/publisher?app={STREAM_APP}&name={STREAM_NAME}",
)
SESSION_COOKIE = os.environ.get("ADMIN_SESSION_COOKIE", "rs_admin")
SESSION_TTL = int(os.environ.get("ADMIN_SESSION_TTL", "86400"))
SESSIONS: Dict[str, Dict[str, object]] = {}


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
        return {"destinations": []}
    return json.loads(CONFIG_PATH.read_text(encoding="utf-8"))


def save_config(payload: dict) -> None:
    destinations = payload.get("destinations", [])
    if not isinstance(destinations, list):
        raise ValueError("destinations must be a list")
    cleaned = [sanitize_destination(d) for d in destinations if isinstance(d, dict)]
    CONFIG_PATH.write_text(json.dumps({"destinations": cleaned}, indent=2), encoding="utf-8")


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
        if parsed.path == "/api/restream/apply":
            try:
                if not self._require_auth():
                    return
                query = parse_qs(parsed.query)
                env = os.environ.copy()
                if query.get("restart", ["0"])[0] == "1":
                    env["RESTART_NGINX"] = "1"
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
