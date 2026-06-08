#!/usr/bin/env bash
set -euo pipefail

# Install rclone at the requested version. Matches the pattern syncoor uses.

VERSION="${RCLONE_VERSION:-v1.68.2}"

if command -v rclone >/dev/null 2>&1; then
  if rclone version | grep -q "rclone ${VERSION#v}"; then
    echo "rclone ${VERSION} already installed"
    exit 0
  fi
fi

ARCH=$(uname -m)
case "${ARCH}" in
  x86_64) RC_ARCH="amd64" ;;
  aarch64|arm64) RC_ARCH="arm64" ;;
  *) echo "::error::unsupported arch: ${ARCH}"; exit 1 ;;
esac

URL="https://github.com/rclone/rclone/releases/download/${VERSION}/rclone-${VERSION}-linux-${RC_ARCH}.zip"
TMP=$(mktemp -d)
curl -fsSL -o "${TMP}/rclone.zip" "${URL}"
unzip -q "${TMP}/rclone.zip" -d "${TMP}"
sudo mv "${TMP}/rclone-${VERSION}-linux-${RC_ARCH}/rclone" /usr/local/bin/rclone
rclone version | head -1
