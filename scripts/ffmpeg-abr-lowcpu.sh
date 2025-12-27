#!/usr/bin/env bash
set -euo pipefail

STREAM_NAME="${1:-stream}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HLS_DIR="${ROOT_DIR}/temp/hls"

pkill -f "ffmpeg .*live/${STREAM_NAME}" 2>/dev/null || true

mkdir -p "${HLS_DIR}/0" "${HLS_DIR}/1"

INPUT_URL="rtmp://127.0.0.1/live/${STREAM_NAME}"

ffmpeg -hide_banner -y \
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
  -hls_flags delete_segments+append_list+program_date_time \
  -hls_segment_filename "${HLS_DIR}/%v/seg_%03d.ts" \
  -master_pl_name master.m3u8 \
  -var_stream_map "v:0,a:0 v:1,a:1" \
  "${HLS_DIR}/%v/index.m3u8"
