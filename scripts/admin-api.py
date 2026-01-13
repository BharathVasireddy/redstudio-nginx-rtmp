#!/usr/bin/env python3
import base64
import json
import os
import sys
import re
import secrets
import shutil
import subprocess
import time
import urllib.request
import xml.etree.ElementTree as ET
from datetime import datetime, timezone
from urllib.parse import parse_qs, quote, urlparse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Optional, Dict, Tuple

try:
    import crypt
except ImportError:  # pragma: no cover - not available on some platforms
    crypt = None

ROOT_DIR = Path(__file__).resolve().parents[1]
DATA_DIR = ROOT_DIR / "data"
OVERLAY_DIR = DATA_DIR / "overlays"
CONFIG_PATH = DATA_DIR / "restream.json"
DEFAULT_CONFIG = ROOT_DIR / "config" / "restream.default.json"
STREAM_STATUS_PATH = DATA_DIR / "stream-status.json"
PUBLIC_CONFIG_PATH = DATA_DIR / "public-config.json"
PUBLIC_HLS_CONF_PATH = DATA_DIR / "public-hls.conf"
IS_WINDOWS = os.name == "nt"
APPLY_SCRIPT = ROOT_DIR / "scripts" / ("restream-apply.ps1" if IS_WINDOWS else "restream-apply.sh")
STREAM_APP = os.environ.get("STREAM_APP", "live")
STREAM_NAME = os.environ.get("STREAM_NAME", "stream")
CONTROL_URL = os.environ.get("CONTROL_URL")
SESSION_COOKIE = os.environ.get("ADMIN_SESSION_COOKIE", "rs_admin")
SESSION_TTL = int(os.environ.get("ADMIN_SESSION_TTL", "86400"))
SESSIONS: Dict[str, Dict[str, object]] = {}
CPU_SAMPLE: Optional[Tuple[int, int, float]] = None
NET_SAMPLE: Optional[Tuple[int, int, float]] = None
OVERLAY_ALLOWED_POSITIONS = {
    "top-left",
    "top-right",
    "bottom-left",
    "bottom-right",
    "center",
    "top-center",
    "bottom-center",
    "center-left",
    "center-right",
    "custom",
}
OVERLAY_ALLOWED_SIZE_MODES = {"percent", "px"}
OVERLAY_ALLOWED_MIME = {
    "image/png": "png",
    "image/jpeg": "jpg",
    "image/jpg": "jpg",
    "image/webp": "webp",
}
OVERLAY_MAX_BYTES = 5 * 1024 * 1024
OVERLAY_MAX_COUNT = int(os.environ.get("OVERLAY_MAX_COUNT", "8"))
OVERLAY_ID_RE = re.compile(r"^[A-Za-z0-9_-]{4,32}$")
OVERLAY_FILENAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}\.(png|jpe?g|webp)$", re.IGNORECASE)
OVERLAY_DEFAULT = {
    "id": "",
    "enabled": False,
    "image_file": "",
    "position": "top-right",
    "offset_x": 24,
    "offset_y": 24,
    "size_mode": "percent",
    "size_value": 18,
    "opacity": 1.0,
    "rotate": 0,
}


def now_ts() -> int:
    return int(time.time())


def iso_from_ts(ts: int) -> str:
    return datetime.fromtimestamp(ts, tz=timezone.utc).isoformat()


def load_stream_status() -> dict:
    if STREAM_STATUS_PATH.exists():
        try:
            return json.loads(STREAM_STATUS_PATH.read_text(encoding="utf-8"))
        except json.JSONDecodeError:
            pass
    return {
        "active": False,
        "started_at": None,
        "started_at_epoch": None,
        "ended_at": None,
        "ended_at_epoch": None,
        "updated_at": None,
        "updated_at_epoch": None,
    }


def write_stream_status(active: bool, started_at: Optional[int] = None, ended_at: Optional[int] = None) -> None:
    status = load_stream_status()
    now = now_ts()
    status["active"] = active
    status["updated_at_epoch"] = now
    status["updated_at"] = iso_from_ts(now)

    if started_at is not None:
        status["started_at_epoch"] = started_at
        status["started_at"] = iso_from_ts(started_at)
        status["ended_at_epoch"] = None
        status["ended_at"] = None

    if ended_at is not None:
        status["ended_at_epoch"] = ended_at
        status["ended_at"] = iso_from_ts(ended_at)

    if active:
        status["ended_at_epoch"] = None
        status["ended_at"] = None

    STREAM_STATUS_PATH.parent.mkdir(parents=True, exist_ok=True)
    tmp_path = STREAM_STATUS_PATH.with_suffix(".tmp")
    tmp_path.write_text(json.dumps(status), encoding="utf-8")
    tmp_path.replace(STREAM_STATUS_PATH)


def write_public_config(public_live: bool, public_hls: bool) -> None:
    now = now_ts()
    payload = {
        "public_live": bool(public_live),
        "public_hls": bool(public_hls),
        "updated_at_epoch": now,
        "updated_at": iso_from_ts(now),
    }
    PUBLIC_CONFIG_PATH.parent.mkdir(parents=True, exist_ok=True)
    tmp_path = PUBLIC_CONFIG_PATH.with_suffix(".tmp")
    tmp_path.write_text(json.dumps(payload), encoding="utf-8")
    tmp_path.replace(PUBLIC_CONFIG_PATH)
    hls_value = "1" if public_hls else "0"
    PUBLIC_HLS_CONF_PATH.write_text(f"set $public_hls {hls_value};\n", encoding="utf-8")


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


def clamp_int(value: object, min_value: int, max_value: int, fallback: int) -> int:
    try:
        number = int(float(value))
    except (TypeError, ValueError):
        return fallback
    return max(min_value, min(max_value, number))


def clamp_float(value: object, min_value: float, max_value: float, fallback: float) -> float:
    try:
        number = float(value)
    except (TypeError, ValueError):
        return fallback
    return max(min_value, min(max_value, number))


def normalize_overlay_image_file(value: object) -> str:
    if value is None:
        return ""
    filename = str(value).strip()
    if "/" in filename or "\\" in filename:
        return ""
    if not filename:
        return ""
    if not OVERLAY_FILENAME_RE.match(filename):
        return ""
    safe = re.sub(r"[^A-Za-z0-9._-]", "", filename)
    return safe if safe and OVERLAY_FILENAME_RE.match(safe) else ""


def sanitize_overlay_filename(value: object, ext: str, fallback: str) -> str:
    if not value:
        return fallback
    name = str(value).strip()
    if not name:
        return fallback
    base = Path(name).name
    stem = Path(base).stem
    stem = re.sub(r"[^A-Za-z0-9._-]", "", stem).strip("._-")
    if not stem:
        return fallback
    candidate = f"{stem}.{ext}"
    return candidate if OVERLAY_FILENAME_RE.match(candidate) else fallback


def overlay_storage_path(filename: str) -> Path:
    return OVERLAY_DIR / filename


def overlay_legacy_path(filename: str) -> Path:
    return DATA_DIR / filename


def migrate_overlay_files(overlays: list) -> None:
    if not overlays:
        return
    OVERLAY_DIR.mkdir(parents=True, exist_ok=True)
    for item in overlays:
        if not isinstance(item, dict):
            continue
        filename = normalize_overlay_image_file(item.get("image_file"))
        if not filename:
            continue
        target = overlay_storage_path(filename)
        if target.exists():
            continue
        legacy = overlay_legacy_path(filename)
        if legacy.exists():
            try:
                shutil.move(str(legacy), str(target))
            except OSError:
                continue

def normalize_overlay_id(value: object) -> str:
    if not value:
        return ""
    candidate = str(value).strip()
    return candidate if OVERLAY_ID_RE.match(candidate) else ""


def generate_overlay_id() -> str:
    return secrets.token_hex(4)


def sanitize_overlay_item(payload: dict, existing: dict, fallback_id: str = "") -> dict:
    merged = {**OVERLAY_DEFAULT, **(existing if isinstance(existing, dict) else {})}
    merged["image_file"] = normalize_overlay_image_file(merged.get("image_file"))

    overlay_id = normalize_overlay_id(payload.get("id")) or normalize_overlay_id(merged.get("id"))
    if not overlay_id and fallback_id:
        overlay_id = normalize_overlay_id(fallback_id)
    if not overlay_id:
        overlay_id = generate_overlay_id()
    merged["id"] = overlay_id

    if "enabled" in payload:
        merged["enabled"] = bool(payload.get("enabled"))
    if "image_file" in payload:
        merged["image_file"] = normalize_overlay_image_file(payload.get("image_file"))
    if "position" in payload:
        position = str(payload.get("position", "")).strip().lower()
        if position in OVERLAY_ALLOWED_POSITIONS:
            merged["position"] = position
    if "offset_x" in payload:
        merged["offset_x"] = clamp_int(payload.get("offset_x"), 0, 2000, merged["offset_x"])
    if "offset_y" in payload:
        merged["offset_y"] = clamp_int(payload.get("offset_y"), 0, 2000, merged["offset_y"])
    if "size_mode" in payload:
        size_mode = str(payload.get("size_mode", "")).strip().lower()
        if size_mode in OVERLAY_ALLOWED_SIZE_MODES:
            merged["size_mode"] = size_mode
    if "size_value" in payload:
        if merged["size_mode"] == "px":
            merged["size_value"] = clamp_int(payload.get("size_value"), 16, 2000, int(merged["size_value"]))
        else:
            merged["size_value"] = clamp_float(payload.get("size_value"), 1.0, 100.0, float(merged["size_value"]))
    if "opacity" in payload:
        merged["opacity"] = clamp_float(payload.get("opacity"), 0.0, 1.0, float(merged["opacity"]))
    if "rotate" in payload:
        merged["rotate"] = clamp_int(payload.get("rotate"), -180, 180, int(merged["rotate"]))

    return merged


def sanitize_overlays(payload: dict, existing: dict) -> list:
    explicit_overlays = "overlays" in payload or "overlay" in payload
    existing_list = existing.get("overlays")
    if not isinstance(existing_list, list):
        legacy = existing.get("overlay")
        existing_list = [legacy] if isinstance(legacy, dict) else []

    existing_cleaned = []
    for index, item in enumerate(existing_list):
        if isinstance(item, dict):
            fallback_id = "primary" if index == 0 else f"overlay-{index + 1}"
            existing_cleaned.append(sanitize_overlay_item(item, {}, fallback_id=fallback_id))

    existing_by_id = {item["id"]: item for item in existing_cleaned if item.get("id")}

    raw_list = payload.get("overlays") if "overlays" in payload else None
    if raw_list is None or not isinstance(raw_list, list):
        raw_overlay = payload.get("overlay") if "overlay" in payload else None
        if isinstance(raw_overlay, dict):
            raw_list = [raw_overlay]
        elif raw_list is None:
            raw_list = None
        else:
            raw_list = []

    if raw_list is None:
        raw_list = existing_cleaned
        explicit_overlays = False

    cleaned = []
    seen_ids = set()
    for index, item in enumerate(raw_list):
        if not isinstance(item, dict):
            continue
        candidate_id = normalize_overlay_id(item.get("id"))
        existing_item = existing_by_id.get(candidate_id, {})
        fallback_id = "primary" if index == 0 else f"overlay-{index + 1}"
        overlay = sanitize_overlay_item(item, existing_item, fallback_id=fallback_id)
        if overlay["id"] in seen_ids:
            overlay["id"] = generate_overlay_id()
        seen_ids.add(overlay["id"])
        cleaned.append(overlay)
        if len(cleaned) >= OVERLAY_MAX_COUNT:
            break

    if not cleaned:
        if explicit_overlays:
            return []
        cleaned = [sanitize_overlay_item({}, {}, fallback_id="primary")]

    return cleaned


def delete_overlay_file(filename: str) -> None:
    if not filename:
        return
    stored = overlay_storage_path(filename)
    if stored.exists():
        stored.unlink()
        return
    legacy = overlay_legacy_path(filename)
    if legacy.exists():
        legacy.unlink()


def remove_overlay_files(overlays: Optional[list] = None, keep: Optional[set] = None, remove_all: bool = False) -> None:
    keep_set = set(keep or [])
    if remove_all or not overlays:
        if not OVERLAY_DIR.exists():
            return
        for path in OVERLAY_DIR.iterdir():
            if not path.is_file():
                continue
            if path.name in keep_set:
                continue
            if not OVERLAY_FILENAME_RE.match(path.name):
                continue
            path.unlink()
        return
    targets = set()
    for item in overlays:
        if not isinstance(item, dict):
            continue
        filename = normalize_overlay_image_file(item.get("image_file"))
        if filename:
            targets.add(filename)
    for filename in targets:
        if filename in keep_set:
            continue
        delete_overlay_file(filename)


def build_base_urls() -> list:
    if CONTROL_URL:
        parsed = urlparse(CONTROL_URL)
        if parsed.scheme and parsed.netloc:
            return [f"{parsed.scheme}://{parsed.netloc}"]

    host = os.environ.get("CONTROL_HOST", "127.0.0.1")
    port = os.environ.get("CONTROL_PORT")
    ports = []
    if port:
        ports.append(port)
    else:
        local_mode = os.environ.get("LOCAL_MODE") == "1"
        if local_mode:
            ports.extend(["8080", "80"])
        else:
            ports.extend(["80", "8080"])

    urls = []
    for value in ports:
        if str(value) == "80":
            urls.append(f"http://{host}")
        else:
            urls.append(f"http://{host}:{value}")
    return urls


def build_stat_urls() -> list:
    return [f"{base}/stat" for base in build_base_urls()]


def build_drop_urls(app: str, name: str) -> list:
    if CONTROL_URL:
        parsed = urlparse(CONTROL_URL)
        if parsed.scheme and parsed.netloc:
            base_urls = [f"{parsed.scheme}://{parsed.netloc}"]
        else:
            base_urls = build_base_urls()
    else:
        base_urls = build_base_urls()
    safe_name = quote(name, safe="")
    return [f"{base}/control/drop/publisher?app={app}&name={safe_name}" for base in base_urls]


def fetch_rtmp_stats() -> Tuple[Optional[bytes], Optional[str]]:
    last_error = None
    for url in build_stat_urls():
        try:
            with urllib.request.urlopen(url, timeout=4) as response:
                return response.read(), None
        except Exception as exc:
            last_error = str(exc)
    return None, last_error


def parse_int(value: Optional[str]) -> Optional[int]:
    if value is None:
        return None
    try:
        return int(float(value))
    except (TypeError, ValueError):
        return None


def parse_float(value: Optional[str]) -> Optional[float]:
    if value is None:
        return None
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def extract_stream_meta(xml_payload: bytes, app_name: str) -> list:
    try:
        root = ET.fromstring(xml_payload)
    except ET.ParseError:
        return []
    streams = []
    for app in root.findall("./server/application"):
        name_node = app.find("name")
        if name_node is None or name_node.text != app_name:
            continue
        for stream in app.findall("./live/stream"):
            entry = {
                "name": stream.findtext("name") or "",
                "video": {},
                "audio": {},
            }
            video = stream.find("./meta/video")
            if video is not None:
                entry["video"] = {
                    "width": parse_int(video.findtext("width")),
                    "height": parse_int(video.findtext("height")),
                    "frame_rate": parse_float(video.findtext("frame_rate")),
                    "codec": video.findtext("codec"),
                }
            audio = stream.find("./meta/audio")
            if audio is not None:
                entry["audio"] = {
                    "codec": audio.findtext("codec"),
                    "sample_rate": parse_int(audio.findtext("sample_rate")),
                    "channels": parse_int(audio.findtext("channels")),
                }
            streams.append(entry)
    return streams


def is_close(value: Optional[float], target: float, tolerance: float = 0.5) -> bool:
    if value is None:
        return False
    return abs(value - target) <= tolerance


def build_health_report() -> dict:
    report: Dict[str, object] = {
        "supported": True,
        "warnings": [],
        "ingest": {"active": False},
        "live": {"active": False},
        "overlays": {"total": 0, "enabled_count": 0},
        "metrics": {},
    }

    warnings = report["warnings"]
    config = load_config()
    overlays = config.get("overlays", [])
    if not isinstance(overlays, list):
        overlays = []
    enabled_overlays = [o for o in overlays if isinstance(o, dict) and o.get("enabled")]
    report["overlays"] = {"total": len(overlays), "enabled_count": len(enabled_overlays)}

    if any(isinstance(o, dict) and o.get("enabled") and not o.get("image_file") for o in overlays):
        warnings.append(
            {
                "level": "warning",
                "message": "An enabled overlay has no image file. Upload an image or disable it.",
            }
        )
    if len(enabled_overlays) > 3:
        warnings.append(
            {
                "level": "warning",
                "message": "More than 3 overlays are enabled. This can increase CPU load and cause stutter.",
            }
        )

    if config.get("public_hls") is False:
        warnings.append(
            {
                "level": "info",
                "message": "HLS access is disabled. Local players and embeds will show offline.",
            }
        )

    metrics = read_metrics()
    report["metrics"] = metrics
    if metrics.get("supported"):
        cpu_pct = (metrics.get("cpu") or {}).get("usage_pct")
        if isinstance(cpu_pct, (int, float)):
            if cpu_pct >= 90:
                warnings.append(
                    {
                        "level": "critical",
                        "message": f"CPU usage is {cpu_pct:.1f}%. High CPU can cause dropped frames.",
                    }
                )
            elif cpu_pct >= 80:
                warnings.append(
                    {
                        "level": "warning",
                        "message": f"CPU usage is {cpu_pct:.1f}%. Consider reducing overlays or output bitrate.",
                    }
                )
        mem_pct = (metrics.get("memory") or {}).get("used_pct")
        if isinstance(mem_pct, (int, float)) and mem_pct >= 90:
            warnings.append(
                {
                    "level": "warning",
                    "message": f"Memory usage is {mem_pct:.1f}%. This can cause buffering and stutter.",
                }
            )
    else:
        warnings.append(
            {
                "level": "info",
                "message": "CPU metrics are unavailable on this server. Monitor system load to avoid stutter.",
            }
        )

    xml_payload, stat_error = fetch_rtmp_stats()
    if not xml_payload:
        report["supported"] = False
        report["error"] = stat_error or "RTMP stats unavailable"
        return report

    ingest_streams = extract_stream_meta(xml_payload, "ingest")
    live_streams = extract_stream_meta(xml_payload, STREAM_APP)
    ingest_active = bool(ingest_streams)
    live_active = bool(live_streams)
    report["ingest"] = {"active": ingest_active}
    report["live"] = {"active": live_active}

    if ingest_streams:
        ingest = ingest_streams[0]
        report["ingest"] = {"active": True, **ingest}

    if live_streams:
        preferred = next((s for s in live_streams if s.get("name") == STREAM_NAME), live_streams[0])
        report["live"] = {"active": True, **preferred}

    if ingest_active and not live_active:
        warnings.append(
            {
                "level": "critical",
                "message": "Ingest is active but live output is not. The overlay pipeline may be down.",
            }
        )
    if not ingest_active:
        warnings.append(
            {
                "level": "info",
                "message": "No ingest detected. Start OBS to populate stream checks.",
            }
        )
    else:
        video = (report["ingest"].get("video") or {})
        audio = (report["ingest"].get("audio") or {})
        frame_rate = video.get("frame_rate")
        codec = video.get("codec")
        if codec and str(codec).upper() != "H264":
            warnings.append(
                {
                    "level": "warning",
                    "message": f"Video codec is {codec}. H.264 is recommended for smooth playback.",
                }
            )
        if isinstance(frame_rate, (int, float)):
            if frame_rate < 24:
                warnings.append(
                    {
                        "level": "warning",
                        "message": f"Frame rate is {frame_rate:.1f} fps. Use constant 30 or 60 fps in OBS.",
                    }
                )
            elif not any(is_close(frame_rate, rate) for rate in (24, 25, 30, 50, 60)):
                warnings.append(
                    {
                        "level": "warning",
                        "message": f"Non-standard frame rate ({frame_rate:.1f} fps). Use 30 or 60 fps for smoother HLS.",
                    }
                )
        else:
            warnings.append(
                {
                    "level": "info",
                    "message": "Frame rate not reported. Ensure OBS is set to constant FPS (30 or 60).",
                }
            )

        sample_rate = audio.get("sample_rate")
        if isinstance(sample_rate, int) and sample_rate != 48000:
            warnings.append(
                {
                    "level": "warning",
                    "message": f"Audio sample rate is {sample_rate} Hz. Set OBS audio to 48 kHz.",
                }
            )
        channels = audio.get("channels")
        if isinstance(channels, int) and channels < 2:
            warnings.append(
                {
                    "level": "warning",
                    "message": "Mono audio detected. Stereo audio is recommended for stable playback.",
                }
            )

    return report


def list_active_streams(xml_payload: bytes, app_name: str) -> list:
    try:
        root = ET.fromstring(xml_payload)
    except ET.ParseError:
        return []
    names = []
    for app in root.findall("./server/application"):
        name_node = app.find("name")
        if name_node is None or name_node.text != app_name:
            continue
        for stream in app.findall("./live/stream"):
            stream_name = stream.findtext("name")
            if stream_name:
                names.append(stream_name)
    return names


def trigger_reconnect() -> Tuple[bool, str]:
    xml_payload, stat_error = fetch_rtmp_stats()
    ingest_names = []
    if xml_payload:
        ingest_names = list_active_streams(xml_payload, "ingest")

    last_error = stat_error or "unknown error"
    dropped = []

    for name in ingest_names:
        for url in build_drop_urls("ingest", name):
            try:
                with urllib.request.urlopen(url, timeout=4) as response:
                    body = response.read().decode("utf-8")
                dropped.append(f"ingest:{name} -> {body}")
                break
            except Exception as exc:
                last_error = str(exc)

    for url in build_drop_urls("live", STREAM_NAME):
        try:
            with urllib.request.urlopen(url, timeout=4) as response:
                body = response.read().decode("utf-8")
            dropped.append(f"live:{STREAM_NAME} -> {body}")
            break
        except Exception as exc:
            last_error = str(exc)

    if dropped:
        return True, "; ".join(dropped)
    return False, last_error


def load_config() -> dict:
    if not CONFIG_PATH.exists() and DEFAULT_CONFIG.exists():
        CONFIG_PATH.write_text(DEFAULT_CONFIG.read_text(encoding="utf-8"), encoding="utf-8")
    if not CONFIG_PATH.exists():
        return {
            "destinations": [],
            "ingest_key": "",
            "public_live": True,
            "public_hls": True,
            "overlay": OVERLAY_DEFAULT.copy(),
            "overlays": [sanitize_overlay_item({}, {}, fallback_id="primary")],
        }
    payload = json.loads(CONFIG_PATH.read_text(encoding="utf-8"))
    if "ingest_key" not in payload:
        payload["ingest_key"] = ""
    if "public_live" not in payload:
        payload["public_live"] = True
    else:
        payload["public_live"] = bool(payload["public_live"])
    if "public_hls" not in payload:
        payload["public_hls"] = True
    else:
        payload["public_hls"] = bool(payload["public_hls"])
    overlays = sanitize_overlays(payload, payload)
    migrate_overlay_files(overlays)
    payload["overlays"] = overlays
    payload["overlay"] = overlays[0] if overlays else OVERLAY_DEFAULT.copy()
    return payload


if not STREAM_STATUS_PATH.exists():
    write_stream_status(False)
if not PUBLIC_CONFIG_PATH.exists():
    config = load_config()
    write_public_config(config.get("public_live", True), config.get("public_hls", True))


def save_config(payload: dict) -> None:
    existing = load_config()
    destinations = payload.get("destinations", existing.get("destinations", []))
    if not isinstance(destinations, list):
        raise ValueError("destinations must be a list")
    cleaned = [sanitize_destination(d) for d in destinations if isinstance(d, dict)]
    ingest_key = payload.get("ingest_key", existing.get("ingest_key", ""))
    if ingest_key is None:
        ingest_key = ""
    ingest_key = str(ingest_key).strip()
    if any(ch in ingest_key for ch in ["\n", "\r", ";", " "]):
        ingest_key = ""
    public_live = bool(payload.get("public_live", existing.get("public_live", True)))
    public_hls = bool(payload.get("public_hls", existing.get("public_hls", True)))
    overlays = sanitize_overlays(payload, existing)
    overlay = overlays[0] if overlays else OVERLAY_DEFAULT.copy()
    CONFIG_PATH.write_text(
        json.dumps(
            {
                "destinations": cleaned,
                "ingest_key": ingest_key,
                "public_live": public_live,
                "public_hls": public_hls,
                "overlay": overlay,
                "overlays": overlays,
            },
            indent=2,
        ),
        encoding="utf-8",
    )
    write_public_config(public_live, public_hls)


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
        if parsed.path == "/api/health":
            if not self._require_auth():
                return
            self._send_json(build_health_report())
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
        if parsed.path == "/api/overlay/image":
            try:
                if not self._require_auth():
                    return
                payload = self._read_json()
                action = str(payload.get("action", "")).strip().lower()
                overlay_id = normalize_overlay_id(payload.get("overlay_id") or payload.get("id"))
                existing = load_config()
                overlays = existing.get("overlays", [])
                if not isinstance(overlays, list):
                    overlays = [existing.get("overlay")] if isinstance(existing.get("overlay"), dict) else []
                overlays = sanitize_overlays({"overlays": overlays}, existing)

                def save_overlays(next_overlays: list) -> None:
                    save_config({"overlays": next_overlays})

                def find_overlay_index(target_id: str) -> int:
                    for idx, item in enumerate(overlays):
                        if isinstance(item, dict) and item.get("id") == target_id:
                            return idx
                    return -1

                if action == "clear":
                    if overlay_id:
                        idx = find_overlay_index(overlay_id)
                        if idx == -1:
                            raise ValueError("overlay not found")
                        image_file = overlays[idx].get("image_file", "")
                        delete_overlay_file(image_file)
                        overlays[idx]["image_file"] = ""
                        overlays[idx]["enabled"] = False
                        save_overlays(overlays)
                        self._send_json({"status": "cleared", "overlay_id": overlay_id})
                    else:
                        remove_overlay_files(overlays, remove_all=True)
                        save_overlays([])
                        self._send_json({"status": "cleared", "overlays": []})
                    return
                if action == "delete":
                    if not overlay_id:
                        raise ValueError("overlay_id required")
                    idx = find_overlay_index(overlay_id)
                    if idx == -1:
                        raise ValueError("overlay not found")
                    image_file = overlays[idx].get("image_file", "")
                    delete_overlay_file(image_file)
                    overlays.pop(idx)
                    if not overlays:
                        overlays = [sanitize_overlay_item({}, {}, fallback_id="primary")]
                    save_overlays(overlays)
                    self._send_json({"status": "deleted", "overlay_id": overlay_id})
                    return
                data_url = str(payload.get("data_url", "")).strip()
                if not data_url.startswith("data:") or "," not in data_url:
                    raise ValueError("invalid data url")
                header, b64_data = data_url.split(",", 1)
                if ";base64" not in header:
                    raise ValueError("invalid data url")
                mime = header.split(";", 1)[0].replace("data:", "", 1)
                ext = OVERLAY_ALLOWED_MIME.get(mime)
                if not ext:
                    raise ValueError("unsupported image type")
                raw = base64.b64decode(b64_data, validate=True)
                if len(raw) > OVERLAY_MAX_BYTES:
                    raise ValueError("image too large")
                if not overlay_id:
                    overlay_id = generate_overlay_id()
                idx = find_overlay_index(overlay_id)
                if idx == -1:
                    overlays.append(sanitize_overlay_item({"id": overlay_id}, {}))
                    idx = len(overlays) - 1
                original_name = payload.get("original_name") or payload.get("filename") or payload.get("name")
                used_names = {
                    item.get("image_file")
                    for item in overlays
                    if isinstance(item, dict) and item.get("id") != overlay_id
                }
                fallback = f"overlay-{overlay_id}.{ext}"
                filename = sanitize_overlay_filename(original_name, ext, fallback)
                if filename in used_names:
                    filename = f"{Path(filename).stem}-{overlay_id}.{ext}"
                if filename in used_names:
                    filename = fallback
                if not OVERLAY_FILENAME_RE.match(filename):
                    filename = fallback
                overlay_path = overlay_storage_path(filename)
                overlay_path.parent.mkdir(parents=True, exist_ok=True)
                overlay_path.write_bytes(raw)
                previous_file = overlays[idx].get("image_file", "")
                overlays[idx]["image_file"] = filename
                save_overlays(overlays)
                if previous_file and previous_file != filename:
                    delete_overlay_file(previous_file)
                self._send_json(
                    {
                        "status": "ok",
                        "image_file": filename,
                        "image_url": f"/admin/overlays/{filename}",
                        "overlay_id": overlay_id,
                    }
                )
            except Exception as exc:
                self._send_json({"error": str(exc)}, status=400)
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
                write_stream_status(True, started_at=now_ts())
                self._send_json({"status": "ok"})
                return
            if key == stored:
                write_stream_status(True, started_at=now_ts())
                self._send_json({"status": "ok"})
                return
            self._send_json({"error": "forbidden"}, status=403)
            return
        if parsed.path == "/api/publish_done":
            write_stream_status(False, ended_at=now_ts())
            self._send_json({"status": "ok"})
            return
        if parsed.path == "/api/restream/apply":
            try:
                if not self._require_auth():
                    return
                query = parse_qs(parsed.query)
                env = os.environ.copy()
                if query.get("restart", ["0"])[0] == "1":
                    env["RESTART_NGINX"] = "1"
                if sys.platform == "darwin":
                    env.setdefault("LOCAL_MODE", "1")
                reconnect = query.get("reconnect", ["0"])[0] == "1"
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
                payload = {"status": "applied"}
                if reconnect:
                    try:
                        ok, result = trigger_reconnect()
                        if ok:
                            payload["reconnect"] = "ok"
                            payload["reconnect_result"] = result
                        else:
                            payload["reconnect"] = "failed"
                            payload["reconnect_error"] = result
                    except Exception as exc:
                        payload["reconnect"] = "failed"
                        payload["reconnect_error"] = str(exc)
                self._send_json(payload)
            except subprocess.CalledProcessError as exc:
                self._send_json({"error": f"apply failed: {exc}"}, status=500)
            return
        if parsed.path == "/api/stream/reconnect":
            try:
                if not self._require_auth():
                    return
                ok, result = trigger_reconnect()
                if ok:
                    self._send_json({"status": "reconnecting", "result": result})
                else:
                    self._send_json({"error": f"reconnect failed: {result}"}, status=500)
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
