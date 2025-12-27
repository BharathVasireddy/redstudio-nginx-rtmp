#!/usr/bin/env bash
set -euo pipefail

GITHUB_REPO="${GITHUB_REPO:-}"
ORACLE_HOST="${ORACLE_HOST:-}"
ORACLE_USER="${ORACLE_USER:-}"
ORACLE_SSH_KEY_FILE="${ORACLE_SSH_KEY_FILE:-}"
ORACLE_SSH_KEY_PASSPHRASE="${ORACLE_SSH_KEY_PASSPHRASE:-}"

if ! command -v gh >/dev/null 2>&1; then
    echo "❌ GitHub CLI not found. Install: https://cli.github.com/"
    exit 1
fi

if ! gh auth status >/dev/null 2>&1; then
    echo "❌ GitHub CLI not authenticated. Run: gh auth login"
    exit 1
fi

if [ -z "${GITHUB_REPO}" ] || [ -z "${ORACLE_HOST}" ] || [ -z "${ORACLE_USER}" ] || [ -z "${ORACLE_SSH_KEY_FILE}" ]; then
    echo "Usage:"
    echo "  GITHUB_REPO=owner/repo \\"
    echo "  ORACLE_HOST=1.2.3.4 \\"
    echo "  ORACLE_USER=ubuntu \\"
    echo "  ORACLE_SSH_KEY_FILE=/path/to/private.key \\"
    echo "  $0"
    exit 1
fi

if [ ! -f "${ORACLE_SSH_KEY_FILE}" ]; then
    echo "❌ Private key not found: ${ORACLE_SSH_KEY_FILE}"
    exit 1
fi

echo "Setting GitHub Actions secrets for ${GITHUB_REPO}..."
gh secret set ORACLE_HOST -b"${ORACLE_HOST}" -R "${GITHUB_REPO}"
gh secret set ORACLE_USER -b"${ORACLE_USER}" -R "${GITHUB_REPO}"
gh secret set ORACLE_SSH_KEY -f "${ORACLE_SSH_KEY_FILE}" -R "${GITHUB_REPO}"

if [ -n "${ORACLE_SSH_KEY_PASSPHRASE}" ]; then
    gh secret set ORACLE_SSH_KEY_PASSPHRASE -b"${ORACLE_SSH_KEY_PASSPHRASE}" -R "${GITHUB_REPO}"
fi

echo "✅ GitHub Actions secrets set."
