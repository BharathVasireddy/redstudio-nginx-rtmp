#!/usr/bin/env bash
set -euo pipefail

STREAM_NAME="${1:-stream}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HLS_DIR="${ROOT_DIR}/temp/hls"

pkill -f "ffmpeg .*live/${STREAM_NAME}" 2>/dev/null || true

mkdir -p "${HLS_DIR}/0" "${HLS_DIR}/1" "${HLS_DIR}/2"

INPUT_URL="rtmp://127.0.0.1/live/${STREAM_NAME}"

ffmpeg -hide_banner -y \
  -i "${INPUT_URL}" \
  -filter_complex \
    "[0:v]split=3[v1080][v720][v480]; \
     [v1080]scale=w=1920:h=1080:force_original_aspect_ratio=decrease,pad=1920:1080:(ow-iw)/2:(oh-ih)/2[v1080out]; \
     [v720]scale=w=1280:h=720:force_original_aspect_ratio=decrease,pad=1280:720:(ow-iw)/2:(oh-ih)/2[v720out]; \
     [v480]scale=w=854:h=480:force_original_aspect_ratio=decrease,pad=854:480:(ow-iw)/2:(oh-ih)/2[v480out]" \
  -map "[v1080out]" -map 0:a? \
  -c:v:0 libx264 -preset veryfast -tune zerolatency -g 60 -keyint_min 60 -sc_threshold 0 \
  -b:v:0 6000k -maxrate:v:0 6500k -bufsize:v:0 12000k \
  -c:a:0 aac -b:a:0 128k \
  -map "[v720out]" -map 0:a? \
  -c:v:1 libx264 -preset veryfast -tune zerolatency -g 60 -keyint_min 60 -sc_threshold 0 \
  -b:v:1 3000k -maxrate:v:1 3200k -bufsize:v:1 6000k \
  -c:a:1 aac -b:a:1 128k \
  -map "[v480out]" -map 0:a? \
  -c:v:2 libx264 -preset veryfast -tune zerolatency -g 60 -keyint_min 60 -sc_threshold 0 \
  -b:v:2 1500k -maxrate:v:2 1600k -bufsize:v:2 3000k \
  -c:a:2 aac -b:a:2 96k \
  -f hls -hls_time 2 -hls_list_size 6 \
  -hls_flags delete_segments+append_list+program_date_time \
  -hls_segment_filename "${HLS_DIR}/%v/seg_%03d.ts" \
  -master_pl_name master.m3u8 \
  -var_stream_map "v:0,a:0 v:1,a:1 v:2,a:2" \
  "${HLS_DIR}/%v/index.m3u8"
