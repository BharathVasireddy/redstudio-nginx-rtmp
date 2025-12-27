#!/usr/bin/env bash
set -euo pipefail

PUB_KEY_FILE="${1:-${ORACLE_SSH_PUB_KEY:-}}"
ORACLE_USER="${2:-${ORACLE_USER:-}}"
ORACLE_HOST="${3:-${ORACLE_HOST:-}}"
ORACLE_PORT="${ORACLE_PORT:-22}"

if [ -z "${PUB_KEY_FILE}" ] || [ -z "${ORACLE_USER}" ] || [ -z "${ORACLE_HOST}" ]; then
    echo "Usage: $0 /path/to/key.pub oracle_user oracle_host"
    echo "Or set ORACLE_SSH_PUB_KEY, ORACLE_USER, ORACLE_HOST (optional ORACLE_PORT)."
    exit 1
fi

if [ ! -f "${PUB_KEY_FILE}" ]; then
    echo "Public key not found: ${PUB_KEY_FILE}"
    exit 1
fi

echo "Installing public key on ${ORACLE_USER}@${ORACLE_HOST}:${ORACLE_PORT}..."

if command -v ssh-copy-id >/dev/null 2>&1; then
    ssh-copy-id -i "${PUB_KEY_FILE}" -p "${ORACLE_PORT}" "${ORACLE_USER}@${ORACLE_HOST}"
else
    cat "${PUB_KEY_FILE}" | ssh -p "${ORACLE_PORT}" "${ORACLE_USER}@${ORACLE_HOST}" \
        "mkdir -p ~/.ssh && chmod 700 ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"
fi

echo "✅ Public key installed."
