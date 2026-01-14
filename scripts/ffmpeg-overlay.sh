#!/usr/bin/env bash
set -euo pipefail

STREAM_NAME="${1:-stream}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG_DIR="${ROOT_DIR}/logs"
LOG_FILE="${LOG_DIR}/ffmpeg-overlay-${STREAM_NAME}.log"
CONFIG_FILE="${ROOT_DIR}/data/restream.json"

mkdir -p "${LOG_DIR}"
exec >> "${LOG_FILE}" 2>&1
echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] Starting FFmpeg overlay for ${STREAM_NAME}"

pkill -f "ffmpeg .*ingest/${STREAM_NAME}" 2>/dev/null || true

FFMPEG_BIN="${FFMPEG_BIN:-}"
if [ -z "${FFMPEG_BIN}" ]; then
    if command -v ffmpeg >/dev/null 2>&1; then
        FFMPEG_BIN="$(command -v ffmpeg)"
    elif [ -x "/opt/homebrew/bin/ffmpeg" ]; then
        FFMPEG_BIN="/opt/homebrew/bin/ffmpeg"
    elif [ -x "/usr/local/bin/ffmpeg" ]; then
        FFMPEG_BIN="/usr/local/bin/ffmpeg"
    elif [ -x "/opt/local/bin/ffmpeg" ]; then
        FFMPEG_BIN="/opt/local/bin/ffmpeg"
    elif [ -x "/usr/bin/ffmpeg" ]; then
        FFMPEG_BIN="/usr/bin/ffmpeg"
    fi
fi

if [ -z "${FFMPEG_BIN}" ]; then
    echo "FFmpeg not found. Install ffmpeg and ensure it is on PATH." >&2
    exit 1
fi

OVERLAY_COUNT="0"
OVERLAY_FILTER_COMPLEX=""
OVERLAY_VIDEO_LABEL=""
OVERLAY_BYPASS_FILE="${ROOT_DIR}/data/overlay-bypass.conf"

OVERLAY_CONFIG="$(python3 - <<'PY' "${CONFIG_FILE}" "${ROOT_DIR}/data"
import json
import shlex
import sys
from pathlib import Path

config_path = Path(sys.argv[1])
data_dir = Path(sys.argv[2])
overlay_dir = data_dir / "overlays"
defaults = {
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
allowed_positions = {
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

try:
    data = json.loads(config_path.read_text(encoding="utf-8"))
except Exception:
    data = {}

raw_overlays = data.get("overlays")
if not isinstance(raw_overlays, list):
    raw_overlay = data.get("overlay")
    raw_overlays = [raw_overlay] if isinstance(raw_overlay, dict) else []

def clamp_int(value, min_value, max_value, fallback):
    try:
        number = int(float(value))
    except (TypeError, ValueError):
        return fallback
    return max(min_value, min(max_value, number))

def clamp_float(value, min_value, max_value, fallback):
    try:
        number = float(value)
    except (TypeError, ValueError):
        return fallback
    return max(min_value, min(max_value, number))

def fmt_float(value):
    text = f"{value:.3f}".rstrip("0").rstrip(".")
    return text if text else "0"

def normalize_overlay(raw):
    overlay = {**defaults, **(raw if isinstance(raw, dict) else {})}
    overlay["enabled"] = bool(overlay.get("enabled", defaults["enabled"]))
    overlay["image_file"] = str(overlay.get("image_file", "") or "").strip()
    position = str(overlay.get("position", defaults["position"])).strip().lower()
    overlay["position"] = position if position in allowed_positions else defaults["position"]
    size_mode = str(overlay.get("size_mode", defaults["size_mode"])).strip().lower()
    overlay["size_mode"] = size_mode if size_mode in ("percent", "px") else defaults["size_mode"]
    size_value = overlay.get("size_value", defaults["size_value"])
    if overlay["size_mode"] == "px":
        overlay["size_value"] = clamp_int(size_value, 16, 2000, defaults["size_value"])
    else:
        overlay["size_value"] = clamp_float(size_value, 1.0, 100.0, float(defaults["size_value"]))
    overlay["offset_x"] = clamp_int(overlay.get("offset_x", defaults["offset_x"]), 0, 2000, defaults["offset_x"])
    overlay["offset_y"] = clamp_int(overlay.get("offset_y", defaults["offset_y"]), 0, 2000, defaults["offset_y"])
    overlay["opacity"] = clamp_float(overlay.get("opacity", defaults["opacity"]), 0.0, 1.0, defaults["opacity"])
    overlay["rotate"] = clamp_int(overlay.get("rotate", defaults["rotate"]), -180, 180, defaults["rotate"])
    return overlay

def build_position(overlay):
    offset_x = overlay["offset_x"]
    offset_y = overlay["offset_y"]
    position = overlay["position"]
    if position == "top-right":
        return f"main_w-overlay_w-{offset_x}", f"{offset_y}"
    if position == "bottom-left":
        return f"{offset_x}", f"main_h-overlay_h-{offset_y}"
    if position == "bottom-right":
        return f"main_w-overlay_w-{offset_x}", f"main_h-overlay_h-{offset_y}"
    if position == "center":
        return f"(main_w-overlay_w)/2+{offset_x}", f"(main_h-overlay_h)/2+{offset_y}"
    if position == "top-center":
        return f"(main_w-overlay_w)/2+{offset_x}", f"{offset_y}"
    if position == "bottom-center":
        return f"(main_w-overlay_w)/2+{offset_x}", f"main_h-overlay_h-{offset_y}"
    if position == "center-left":
        return f"{offset_x}", f"(main_h-overlay_h)/2+{offset_y}"
    if position == "center-right":
        return f"main_w-overlay_w-{offset_x}", f"(main_h-overlay_h)/2+{offset_y}"
    return f"{offset_x}", f"{offset_y}"

active = []
for item in raw_overlays:
    overlay = normalize_overlay(item)
    if not overlay["enabled"]:
        continue
    if not overlay["image_file"]:
        continue
    image_path = overlay_dir / overlay["image_file"]
    if not image_path.exists():
        image_path = data_dir / overlay["image_file"]
    if not image_path.exists():
        continue
    overlay["image_path"] = str(image_path)
    overlay["x"], overlay["y"] = build_position(overlay)
    active.append(overlay)

if not active:
    print("OVERLAY_COUNT=0")
    sys.exit(0)

filters = []
base_label = "0:v"
for idx, overlay in enumerate(active, start=1):
    ovl_label = f"ovl{idx}"
    wm_label = f"wm{idx}"
    base_ref = f"base_ref{idx}"
    base_out = f"base{idx}"

    chain = f"[{idx}:v]format=rgba,colorchannelmixer=aa={fmt_float(overlay['opacity'])}"
    if overlay["rotate"]:
        chain += f",rotate={overlay['rotate']}*PI/180:fillcolor=none"
    chain += f"[{ovl_label}]"
    filters.append(chain)

    if overlay["size_mode"] == "percent":
        size_value = fmt_float(overlay["size_value"])
        filters.append(
            f"[{ovl_label}][{base_label}]scale2ref=w=main_w*{size_value}/100:h=-1[{wm_label}][{base_ref}]"
        )
        filters.append(
            f"[{base_ref}][{wm_label}]overlay=x={overlay['x']}:y={overlay['y']}:format=auto[{base_out}]"
        )
    else:
        size_value = int(overlay["size_value"])
        filters.append(f"[{ovl_label}]scale={size_value}:-1[{wm_label}]")
        filters.append(
            f"[{base_label}][{wm_label}]overlay=x={overlay['x']}:y={overlay['y']}:format=auto[{base_out}]"
        )
    base_label = base_out

filter_complex = ";".join(filters)
print(f"OVERLAY_COUNT={len(active)}")
print(f"OVERLAY_VIDEO_LABEL={base_label}")
print(f"OVERLAY_FILTER_COMPLEX={shlex.quote(filter_complex)}")
for idx, overlay in enumerate(active):
    print(f"OVERLAY_INPUT_{idx}={shlex.quote(overlay['image_path'])}")
PY
)"

if [ -n "${OVERLAY_CONFIG}" ]; then
    eval "${OVERLAY_CONFIG}"
fi

if [ "${OVERLAY_COUNT}" -eq 0 ]; then
    if [ -f "${OVERLAY_BYPASS_FILE}" ] && grep -q "push rtmp://127.0.0.1/live" "${OVERLAY_BYPASS_FILE}"; then
        echo "No overlays enabled; bypassing FFmpeg pipeline."
        exit 0
    fi
fi

INPUT_URL="rtmp://127.0.0.1/ingest/${STREAM_NAME}"
OUTPUT_STREAM_NAME="${OUTPUT_STREAM_NAME:-stream}"
OUTPUT_URL="rtmp://127.0.0.1/live/${OUTPUT_STREAM_NAME}"

if [ "${OVERLAY_COUNT}" -gt 0 ] && [ -n "${OVERLAY_FILTER_COMPLEX}" ] && [ -n "${OVERLAY_VIDEO_LABEL}" ]; then
    ffmpeg_cmd=(
        "${FFMPEG_BIN}" -hide_banner -loglevel warning -stats -y
        -fflags +genpts -use_wallclock_as_timestamps 1 -thread_queue_size 512 -i "${INPUT_URL}"
    )
    overlay_inputs_added=0
    for ((i = 0; i < OVERLAY_COUNT; i++)); do
        input_var="OVERLAY_INPUT_${i}"
        overlay_path="${!input_var:-}"
        if [ -z "${overlay_path}" ] || [ ! -f "${overlay_path}" ]; then
            continue
        fi
        overlay_inputs_added=$((overlay_inputs_added + 1))
        ffmpeg_cmd+=( -loop 1 -i "${overlay_path}" )
    done
    if [ "${overlay_inputs_added}" -ne "${OVERLAY_COUNT}" ]; then
        echo "Overlay inputs missing; falling back to passthrough." >&2
    else
        ffmpeg_cmd+=(
            -filter_complex "${OVERLAY_FILTER_COMPLEX}"
            -map "[${OVERLAY_VIDEO_LABEL}]" -map 0:a?
            -r 30
            -vsync 1
            -c:v libx264 -preset ultrafast -tune zerolatency -g 60 -keyint_min 60 -sc_threshold 0 -pix_fmt yuv420p
            -c:a aac -b:a 128k -ar 48000 -ac 2 -af "aresample=async=1:min_hard_comp=0.100000:first_pts=0"
            -f flv "${OUTPUT_URL}"
        )
        "${ffmpeg_cmd[@]}"
        exit 0
    fi
fi

"${FFMPEG_BIN}" -hide_banner -loglevel warning -stats -y \
    -fflags +genpts -use_wallclock_as_timestamps 1 -thread_queue_size 512 -i "${INPUT_URL}" \
    -map 0 -c copy \
    -f flv "${OUTPUT_URL}"
