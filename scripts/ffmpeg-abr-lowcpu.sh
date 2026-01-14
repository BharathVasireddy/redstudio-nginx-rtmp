#!/usr/bin/env bash
set -euo pipefail

STREAM_NAME="${1:-stream}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HLS_DIR="${ROOT_DIR}/temp/hls-abr"
LOG_DIR="${ROOT_DIR}/logs"
LOG_FILE="${LOG_DIR}/ffmpeg-${STREAM_NAME}.log"
MASTER_PLAYLIST="${HLS_DIR}/master.m3u8"
INPUT_URL="rtmp://127.0.0.1/live/${STREAM_NAME}"

mkdir -p "${LOG_DIR}"
exec >> "${LOG_FILE}" 2>&1
echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] Starting FFmpeg ABR (lowcpu) for ${STREAM_NAME}"

pkill -f "ffmpeg .*${INPUT_URL}" 2>/dev/null || true
pkill -f "ffmpeg .*${HLS_DIR}" 2>/dev/null || true
sleep 1

mkdir -p "${HLS_DIR}/0" "${HLS_DIR}/1"

cat > "${MASTER_PLAYLIST}" <<EOF
#EXTM3U
#EXT-X-VERSION:6
#EXT-X-INDEPENDENT-SEGMENTS
#EXT-X-STREAM-INF:BANDWIDTH=6000000,RESOLUTION=1920x1080
0/index.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=3000000,RESOLUTION=1280x720
1/index.m3u8
EOF
echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] Wrote master playlist to ${MASTER_PLAYLIST}"

ffmpeg -hide_banner -loglevel warning -stats -y \
  -i "${INPUT_URL}" \
  -filter_complex \
    "[0:v]split=2[v1080][v720]; \
     [v1080]scale=w=1920:h=1080:force_original_aspect_ratio=decrease,pad=1920:1080:(ow-iw)/2:(oh-ih)/2[v1080out]; \
     [v720]scale=w=1280:h=720:force_original_aspect_ratio=decrease,pad=1280:720:(ow-iw)/2:(oh-ih)/2[v720out]" \
  -map "[v1080out]" -map 0:a? \
  -c:v:0 libx264 -preset veryfast -tune zerolatency -g 60 -keyint_min 60 -sc_threshold 0 \
  -b:v:0 5500k -maxrate:v:0 6000k -bufsize:v:0 11000k \
  -c:a:0 aac -b:a:0 128k \
  -map "[v720out]" -map 0:a? \
  -c:v:1 libx264 -preset veryfast -tune zerolatency -g 60 -keyint_min 60 -sc_threshold 0 \
  -b:v:1 2800k -maxrate:v:1 3000k -bufsize:v:1 6000k \
  -c:a:1 aac -b:a:1 128k \
  -f hls -hls_time 2 -hls_list_size 6 \
  -hls_flags delete_segments+append_list+program_date_time+temp_file \
  -hls_segment_filename "${HLS_DIR}/%v/seg_%03d.ts" \
  -var_stream_map "v:0,a:0 v:1,a:1" \
  "${HLS_DIR}/%v/index.m3u8"
