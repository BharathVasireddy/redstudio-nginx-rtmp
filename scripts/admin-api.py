#!/usr/bin/env python3
import json
import os
import subprocess
import urllib.request
from urllib.parse import parse_qs, urlparse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


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


class Handler(BaseHTTPRequestHandler):
    def log_message(self, format: str, *args) -> None:
        return

    def _send_json(self, data: dict, status: int = 200) -> None:
        body = json.dumps(data).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _read_json(self) -> dict:
        length = int(self.headers.get("Content-Length", 0))
        raw = self.rfile.read(length) if length else b"{}"
        return json.loads(raw.decode("utf-8"))

    def do_GET(self) -> None:
        parsed = urlparse(self.path)
        if parsed.path == "/api/restream":
            self._send_json(load_config())
            return
        self._send_json({"error": "not found"}, status=404)

    def do_POST(self) -> None:
        parsed = urlparse(self.path)
        if parsed.path == "/api/restream":
            try:
                payload = self._read_json()
                save_config(payload)
                self._send_json({"status": "ok"})
            except Exception as exc:
                self._send_json({"error": str(exc)}, status=400)
            return
        if parsed.path == "/api/restream/apply":
            try:
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
