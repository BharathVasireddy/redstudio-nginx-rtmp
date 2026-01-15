#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OS_NAME="$(uname -s)"
NGINX_VERSION="${NGINX_VERSION:-1.24.0}"
FORCE_STOP=false
NO_START=false
BUILD_TMP_DIR=""
PYTHON_BIN=""
ADMIN_USER=""
ADMIN_PASS=""
ADMIN_CREDS_CREATED="false"
ADMIN_STOPPED="false"

usage() {
  cat <<'EOF'
Usage: scripts/setup-local.sh [--force-stop] [--no-start] [--nginx-version <ver>]

Options:
  --force-stop       Stop any nginx listening on port 8080.
  --no-start         Only install/build; do not start the server.
  --nginx-version    Nginx version to build (default: 1.24.0).
EOF
}

log() {
  echo ">> $*"
}

warn() {
  echo "!! $*" >&2
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

retry() {
  local retries="${1:-3}"
  shift
  local count=0
  until "$@"; do
    count=$((count + 1))
    if [[ "${count}" -ge "${retries}" ]]; then
      return 1
    fi
    sleep 2
  done
  return 0
}

cleanup_tmp() {
  if [[ -n "${BUILD_TMP_DIR:-}" && -d "${BUILD_TMP_DIR}" ]]; then
    rm -rf "${BUILD_TMP_DIR}"
  fi
}

get_nginx_bin() {
  if [[ -x "/usr/local/nginx/sbin/nginx" ]]; then
    echo "/usr/local/nginx/sbin/nginx"
    return 0
  fi
  command -v nginx || true
}

ensure_python() {
  if command -v python3 >/dev/null 2>&1; then
    PYTHON_BIN="$(command -v python3)"
    return 0
  fi
  if [[ -x "/opt/homebrew/bin/python3" ]]; then
    PYTHON_BIN="/opt/homebrew/bin/python3"
    return 0
  fi
  if [[ -x "/usr/local/bin/python3" ]]; then
    PYTHON_BIN="/usr/local/bin/python3"
    return 0
  fi
  die "python3 not found. Install python3 and retry."
}

prepare_local_files() {
  log "Preparing local config files..."
mkdir -p "${ROOT_DIR}/data" "${ROOT_DIR}/temp/hls" "${ROOT_DIR}/temp/hls-abr" "${ROOT_DIR}/logs" "${ROOT_DIR}/conf/data"
  if [[ ! -f "${ROOT_DIR}/data/restream.json" ]]; then
    cp "${ROOT_DIR}/config/restream.default.json" "${ROOT_DIR}/data/restream.json"
  fi
  ensure_python
  "${PYTHON_BIN}" "${ROOT_DIR}/scripts/restream-generate.py" \
    "${ROOT_DIR}/data/restream.json" \
    "${ROOT_DIR}/data/restream.conf"
  ln -sf "${ROOT_DIR}/data/restream.conf" "${ROOT_DIR}/conf/data/restream.conf"
  "${PYTHON_BIN}" - <<'PY' "${ROOT_DIR}/data/restream.json" "${ROOT_DIR}/data/public-config.json" "${ROOT_DIR}/data/public-hls.conf" "${ROOT_DIR}/data/overlay-bypass.conf"
import json
import sys
import time
from datetime import datetime, timezone

json_file, public_config, public_hls_conf, overlay_bypass_conf = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]

try:
    with open(json_file, "r", encoding="utf-8") as fh:
        data = json.load(fh)
except FileNotFoundError:
    data = {}

def parse_bool(value, default):
    if isinstance(value, bool):
        return value
    if value is None:
        return default
    if isinstance(value, (int, float)):
        return value != 0
    if isinstance(value, str):
        text = value.strip().lower()
        if text in ("1", "true", "yes", "on"):
            return True
        if text in ("0", "false", "no", "off"):
            return False
    return default

public_live = bool(data.get("public_live", True))
public_hls = bool(data.get("public_hls", True))
force_transcode = parse_bool(data.get("force_transcode"), True)
overlay_active = False
raw_overlays = data.get("overlays")
if not isinstance(raw_overlays, list):
    raw_overlay = data.get("overlay")
    raw_overlays = [raw_overlay] if isinstance(raw_overlay, dict) else []
for item in raw_overlays:
    if not isinstance(item, dict):
        continue
    if not bool(item.get("enabled")):
        continue
    image_file = str(item.get("image_file", "") or "").strip()
    if image_file:
        overlay_active = True
        break

now = int(time.time())
payload = {
    "public_live": public_live,
    "public_hls": public_hls,
    "updated_at_epoch": now,
    "updated_at": datetime.fromtimestamp(now, tz=timezone.utc).isoformat(),
}

with open(public_config, "w", encoding="utf-8") as fh:
    json.dump(payload, fh)

with open(public_hls_conf, "w", encoding="utf-8") as fh:
    fh.write(f"set $public_hls {1 if public_hls else 0};\n")

with open(overlay_bypass_conf, "w", encoding="utf-8") as fh:
    if overlay_active or force_transcode:
        fh.write("# overlay pipeline active\n")
    else:
        fh.write("push rtmp://127.0.0.1/live/stream;\n")
PY
}

generate_password() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -base64 18 | tr -d '/+=' | cut -c1-18
    return
  fi
  ensure_python
  "${PYTHON_BIN}" - <<'PY'
import secrets
import string
alphabet = string.ascii_letters + string.digits
print("".join(secrets.choice(alphabet) for _ in range(18)))
PY
}

ensure_admin_credentials() {
  local creds="${ROOT_DIR}/data/admin.credentials"
  if [[ -f "${creds}" ]]; then
    ADMIN_USER="$(grep -E '^user=' "${creds}" | head -n 1 | cut -d= -f2- || true)"
    ADMIN_PASS="$(grep -E '^password=' "${creds}" | head -n 1 | cut -d= -f2- || true)"
    return 0
  fi
  ADMIN_USER="admin"
  ADMIN_PASS="$(generate_password)"
  cat > "${creds}" <<EOF
user=${ADMIN_USER}
password=${ADMIN_PASS}
EOF
  chmod 600 "${creds}" || true
  ADMIN_CREDS_CREATED="true"
  log "Created local admin credentials in data/admin.credentials"
}

admin_api_alive() {
  ensure_python
  "${PYTHON_BIN}" - <<'PY'
import socket
import sys
sock = socket.socket()
sock.settimeout(0.5)
try:
    sock.connect(("127.0.0.1", 9090))
    sys.exit(0)
except Exception:
    sys.exit(1)
finally:
    sock.close()
PY
}

stop_admin_api() {
  local pid_file="${ROOT_DIR}/logs/admin-api.pid"
  if [[ -f "${pid_file}" ]]; then
    local admin_pid
    admin_pid="$(cat "${pid_file}" 2>/dev/null || true)"
    if [[ -n "${admin_pid}" ]] && kill -0 "${admin_pid}" >/dev/null 2>&1; then
      kill "${admin_pid}" >/dev/null 2>&1 || true
      ADMIN_STOPPED="true"
    fi
    rm -f "${pid_file}"
  fi

  if ! command -v lsof >/dev/null 2>&1; then
    return 0
  fi

  local pids
  pids="$(lsof -nP -iTCP:9090 -sTCP:LISTEN 2>/dev/null | awk 'NR>1 {print $2}' | sort -u || true)"
  if [[ -z "${pids}" ]]; then
    if command -v sudo >/dev/null 2>&1; then
      pids="$(sudo lsof -nP -iTCP:9090 -sTCP:LISTEN 2>/dev/null | awk 'NR>1 {print $2}' | sort -u || true)"
    fi
    if [[ -z "${pids}" ]]; then
      return 0
    fi
  fi

  if [[ "${FORCE_STOP}" == "true" ]]; then
    kill_listening_on_port 9090 || true
    ADMIN_STOPPED="true"
    return 0
  fi

  local pid cmd
  for pid in ${pids}; do
    cmd="$(ps -p "${pid}" -o command= 2>/dev/null || true)"
    if [[ "${cmd}" == *"admin-api.py"* || "${cmd}" == *"${ROOT_DIR}"* ]]; then
      kill "${pid}" >/dev/null 2>&1 || true
      ADMIN_STOPPED="true"
      continue
    fi
    warn "Port 9090 is in use by another process. Use --force-stop to stop it."
  done
}

start_admin_api() {
  local pid_file="${ROOT_DIR}/logs/admin-api.pid"
  local log_file="${ROOT_DIR}/logs/admin-api.log"
  stop_admin_api
  if admin_api_alive; then
    if [[ "${FORCE_STOP}" == "true" ]]; then
      kill_listening_on_port 9090 || true
    else
      die "Port 9090 is in use. Re-run with --force-stop."
    fi
  fi
  if [[ -f "${pid_file}" ]]; then
    local old_pid
    old_pid="$(cat "${pid_file}" 2>/dev/null || true)"
    if [[ -n "${old_pid}" ]] && kill -0 "${old_pid}" >/dev/null 2>&1; then
      log "Admin API process detected (pid ${old_pid})."
      return 0
    fi
    rm -f "${pid_file}"
  fi
  log "Starting admin API on http://127.0.0.1:9090 ..."
  nohup env ADMIN_API_HOST=127.0.0.1 ADMIN_API_PORT=9090 PYTHONUNBUFFERED=1 \
    "${PYTHON_BIN}" "${ROOT_DIR}/scripts/admin-api.py" > "${log_file}" 2>&1 &
  echo $! > "${pid_file}"
  sleep 1
  local admin_pid
  admin_pid="$(cat "${pid_file}" 2>/dev/null || true)"
  if [[ -z "${admin_pid}" ]] || ! kill -0 "${admin_pid}" >/dev/null 2>&1; then
    die "Admin API failed to start. Check ${log_file}"
  fi
}

health_check() {
  local ok=true
  if command -v curl >/dev/null 2>&1; then
    if ! curl -fsS "http://localhost:8080/" >/dev/null 2>&1; then
      warn "Health check failed: http://localhost:8080/"
      ok=false
    fi
    if ! curl -fsS "http://localhost:8080/admin/login.html" >/dev/null 2>&1; then
      warn "Health check failed: http://localhost:8080/admin/login.html"
      ok=false
    fi
    local admin_code
    admin_code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:9090/api/session" || true)"
    if [[ "${admin_code}" != "200" && "${admin_code}" != "401" ]]; then
      warn "Health check failed: http://127.0.0.1:9090/api/session (HTTP ${admin_code:-0})"
      ok=false
    fi
  fi
  if command -v lsof >/dev/null 2>&1; then
    if ! lsof -nP -iTCP:1935 -sTCP:LISTEN >/dev/null 2>&1; then
      warn "RTMP port 1935 is not listening."
      ok=false
    fi
  fi
  if [[ "${ok}" == "true" ]]; then
    log "Health check passed."
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --force-stop)
      FORCE_STOP=true
      ;;
    --no-start)
      NO_START=true
      ;;
    --nginx-version)
      shift
      NGINX_VERSION="${1:-}"
      if [[ -z "${NGINX_VERSION}" ]]; then
        die "Missing value for --nginx-version"
      fi
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "Unknown option: $1"
      ;;
  esac
  shift
done

ensure_cmd() {
  local cmd="$1"
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    die "Missing required command: ${cmd}"
  fi
}

ensure_homebrew() {
  if command -v brew >/dev/null 2>&1; then
    return 0
  fi
  log "Homebrew not found. Installing..."
  if ! retry 3 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"; then
    die "Homebrew install failed after retries."
  fi
  export PATH="/opt/homebrew/bin:/usr/local/bin:${PATH}"
  ensure_cmd brew
}

install_mac_deps() {
  ensure_homebrew
  log "Installing macOS dependencies..."
  if ! retry 3 brew install pcre2 zlib openssl@3 python; then
    die "Homebrew install failed after retries."
  fi
}

install_linux_deps() {
  if ! command -v apt-get >/dev/null 2>&1; then
    die "Unsupported Linux (apt-get not found). Install dependencies manually."
  fi
  log "Installing Linux dependencies..."
  if ! retry 3 sudo apt-get update; then
    die "apt-get update failed after retries."
  fi
  if ! retry 3 sudo apt-get install -y python3 git build-essential libpcre3 libpcre3-dev \
    zlib1g zlib1g-dev libssl-dev libgd-dev libgeoip-dev curl unzip; then
    die "apt-get install failed after retries."
  fi
}

port_8080_in_use() {
  if command -v lsof >/dev/null 2>&1; then
    lsof -nP -iTCP:8080 -sTCP:LISTEN >/dev/null 2>&1
    return $?
  fi
  if command -v ss >/dev/null 2>&1; then
    ss -lnt 2>/dev/null | grep -qE ':8080\s'
    return $?
  fi
  return 1
}

kill_listening_on_port() {
  local port="$1"
  if ! command -v lsof >/dev/null 2>&1; then
    return 1
  fi
  local pids
  pids="$(lsof -nP -iTCP:${port} -sTCP:LISTEN 2>/dev/null | awk 'NR>1 {print $2}' | sort -u || true)"
  if [[ -z "${pids}" ]] && command -v sudo >/dev/null 2>&1; then
    pids="$(sudo lsof -nP -iTCP:${port} -sTCP:LISTEN 2>/dev/null | awk 'NR>1 {print $2}' | sort -u || true)"
  fi
  if [[ -z "${pids}" ]]; then
    return 0
  fi
  local pid
  for pid in ${pids}; do
    if ! kill "${pid}" >/dev/null 2>&1; then
      if command -v sudo >/dev/null 2>&1; then
        sudo kill "${pid}" >/dev/null 2>&1 || true
      fi
    fi
  done
  sleep 1
  return 0
}

stop_port_8080() {
  if ! port_8080_in_use; then
    return 0
  fi
  warn "Port 8080 is already in use."
  local can_stop="false"
  if [[ "${FORCE_STOP}" == "true" ]]; then
    can_stop="true"
  elif command -v lsof >/dev/null 2>&1; then
    if lsof -nP -iTCP:8080 -sTCP:LISTEN 2>/dev/null | awk 'NR>1 {print $1}' | grep -q '^nginx$'; then
      warn "Detected nginx on port 8080. Stopping it automatically."
      can_stop="true"
    fi
  fi
  if [[ "${can_stop}" != "true" ]]; then
    die "Use --force-stop to stop the existing service on 8080."
  fi
  if command -v brew >/dev/null 2>&1; then
    brew services stop nginx >/dev/null 2>&1 || true
  fi
  if [[ -x "/usr/local/nginx/sbin/nginx" ]]; then
    sudo /usr/local/nginx/sbin/nginx -s stop >/dev/null 2>&1 || true
  fi
  if command -v nginx >/dev/null 2>&1; then
    sudo "$(command -v nginx)" -s stop >/dev/null 2>&1 || true
  fi
  if [[ "${FORCE_STOP}" == "true" ]]; then
    kill_listening_on_port 8080 || true
  fi
  sleep 1
  if port_8080_in_use; then
    die "Port 8080 is still in use. Stop it manually and retry."
  fi
}

nginx_has_rtmp() {
  local nginx_bin
  nginx_bin="$(get_nginx_bin)"
  if [[ -z "${nginx_bin}" ]]; then
    return 1
  fi
  "${nginx_bin}" -V 2>&1 | grep -q "nginx-rtmp-module"
}

build_nginx_mac() {
  ensure_cmd curl
  ensure_cmd tar
  ensure_cmd make
  ensure_cmd cc

  log "Building nginx ${NGINX_VERSION} with RTMP module..."
  BUILD_TMP_DIR="$(mktemp -d)"
  trap cleanup_tmp EXIT

  local rtmp_dir="${ROOT_DIR}/vendor/nginx-rtmp-module"
  if [[ ! -d "${rtmp_dir}" ]]; then
    die "RTMP module not found at ${rtmp_dir}"
  fi

  pushd "${BUILD_TMP_DIR}" >/dev/null
  curl -fsSLO "http://nginx.org/download/nginx-${NGINX_VERSION}.tar.gz"
  tar -xzf "nginx-${NGINX_VERSION}.tar.gz"
  cd "nginx-${NGINX_VERSION}"

  local openssl_prefix
  local pcre2_prefix
  local zlib_prefix

  openssl_prefix="$(brew --prefix openssl@3 2>/dev/null || true)"
  if [[ -z "${openssl_prefix}" ]]; then
    die "OpenSSL not found. Run: brew install openssl@3"
  fi
  pcre2_prefix="$(brew --prefix pcre2 2>/dev/null || true)"
  if [[ -z "${pcre2_prefix}" ]]; then
    die "PCRE2 not found. Run: brew install pcre2"
  fi
  zlib_prefix="$(brew --prefix zlib 2>/dev/null || true)"
  if [[ -z "${zlib_prefix}" ]]; then
    die "zlib not found. Run: brew install zlib"
  fi

  local cc_opt
  local ld_opt
  cc_opt="-I${openssl_prefix}/include -I${pcre2_prefix}/include -I${zlib_prefix}/include"
  ld_opt="-L${openssl_prefix}/lib -L${pcre2_prefix}/lib -L${zlib_prefix}/lib"

  ./configure \
    --prefix=/usr/local/nginx \
    --with-http_ssl_module \
    --with-http_secure_link_module \
    --with-http_realip_module \
    --with-cc-opt="${cc_opt}" \
    --with-ld-opt="${ld_opt}" \
    --add-module="${rtmp_dir}"

  make -j"$(sysctl -n hw.ncpu)"
  sudo make install
  sudo ln -sf /usr/local/nginx/sbin/nginx /usr/local/bin/nginx
  popd >/dev/null
}

build_nginx_linux() {
  log "Building nginx with RTMP module using setup-oracle.sh..."
  chmod +x "${ROOT_DIR}/setup-oracle.sh"
  sudo "${ROOT_DIR}/setup-oracle.sh"
}

start_server() {
  chmod +x "${ROOT_DIR}/stream-start.sh" "${ROOT_DIR}/stream-stop.sh" "${ROOT_DIR}/stream-reload.sh"
  "${ROOT_DIR}/stream-start.sh"
}

main() {
  log "Starting local setup in ${ROOT_DIR}"

  case "${OS_NAME}" in
    Darwin)
      install_mac_deps
      ;;
    Linux)
      install_linux_deps
      ;;
    *)
      die "Unsupported OS: ${OS_NAME}"
      ;;
  esac

  ensure_python
  stop_port_8080
  prepare_local_files
  ensure_admin_credentials

  if ! nginx_has_rtmp; then
    if [[ "${OS_NAME}" == "Darwin" ]]; then
      build_nginx_mac
    else
      build_nginx_linux
    fi
  else
    log "nginx with RTMP module found."
  fi

  log "Validating nginx config..."
  local nginx_bin
  nginx_bin="$(get_nginx_bin)"
  if [[ -z "${nginx_bin}" ]]; then
    die "nginx not found after build."
  fi
  "${nginx_bin}" -t -p "${ROOT_DIR}" -c conf/nginx.local.conf

  if [[ "${NO_START}" == "true" ]]; then
    log "Setup complete. Server not started (per --no-start)."
    exit 0
  fi

  start_server
  start_admin_api
  health_check

  echo ""
  echo "--------------------------------------------"
  echo "Dashboard: http://localhost:8080/"
  echo "Admin: http://localhost:8080/admin/"
  if [[ "${ADMIN_CREDS_CREATED}" == "true" ]]; then
    echo "Admin User: ${ADMIN_USER}"
    echo "Admin Pass: ${ADMIN_PASS}"
  else
    if [[ -n "${ADMIN_USER}" && -n "${ADMIN_PASS}" ]]; then
      echo "Admin User: ${ADMIN_USER}"
      echo "Admin Pass: ${ADMIN_PASS}"
    else
      echo "Admin Credentials: ${ROOT_DIR}/data/admin.credentials"
    fi
  fi
  echo "RTMP URL: rtmp://localhost/ingest"
  echo "--------------------------------------------"
}

main
