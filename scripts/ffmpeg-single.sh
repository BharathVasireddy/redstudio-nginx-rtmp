#!/usr/bin/env bash
set -euo pipefail

STREAM_NAME="${1:-stream}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HLS_DIR="${ROOT_DIR}/temp/hls"
LOG_DIR="${ROOT_DIR}/logs"
LOG_FILE="${LOG_DIR}/ffmpeg-${STREAM_NAME}.log"

mkdir -p "${LOG_DIR}"
exec >> "${LOG_FILE}" 2>&1
echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] Starting FFmpeg Single Quality for ${STREAM_NAME}"

# Kill any existing FFmpeg process for this stream
pkill -f "ffmpeg .*live/${STREAM_NAME}" 2>/dev/null || true

mkdir -p "${HLS_DIR}"

INPUT_URL="rtmp://127.0.0.1/live/${STREAM_NAME}"

# Single quality 720p stream - much lower CPU usage
ffmpeg -hide_banner -loglevel warning -stats -y \
  -i "${INPUT_URL}" \
  -c:v libx264 -preset ultrafast -tune zerolatency \
  -g 60 -keyint_min 60 -sc_threshold 0 \
  -b:v 2500k -maxrate:v 2800k -bufsize:v 5000k \
  -c:a aac -b:a 128k \
  -f hls -hls_time 2 -hls_list_size 6 \
  -hls_flags delete_segments+append_list+program_date_time \
  -hls_segment_filename "${HLS_DIR}/seg_%03d.ts" \
  "${HLS_DIR}/master.m3u8"
