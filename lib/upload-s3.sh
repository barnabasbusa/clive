#!/usr/bin/env bash
set -euo pipefail

# Upload the normalised results to S3 and emit a public result_url.
#
# Inputs (env):
#   OUT_DIR         - contains results/*.json + listing-fragment.jsonl
#   S3_BUCKET       - default 'hive-results'
#   S3_PATH         - e.g. spec-glamsterdam-devnet-5
#   S3_PUBLIC_URL   - optional; used for the result_url output
#   RCLONE_CONFIG   - inline rclone config contents

if [[ -z "${RCLONE_CONFIG:-}" ]]; then
  echo "::error::rclone_config is empty; cannot upload"
  exit 1
fi

CONFIG_FILE=$(mktemp)
echo "${RCLONE_CONFIG}" > "${CONFIG_FILE}"
trap 'rm -f "${CONFIG_FILE}"' EXIT

# Convention: the rclone remote is named after the bucket. Matches the syncoor
# convention so we can reuse the existing rclone_config secret unchanged.
REMOTE="${S3_BUCKET}"

echo "::group::Upload results/"
if [[ -d "${OUT_DIR}/results" ]]; then
  rclone --config "${CONFIG_FILE}" copy \
    "${OUT_DIR}/results/" \
    "${REMOTE}:${S3_BUCKET}/${S3_PATH}/results/"
fi
echo "::endgroup::"

echo "::group::Append listing.jsonl"
# Fetch the existing listing (if any), prepend our fragment, dedupe by fileName,
# then re-upload. This mirrors what hive's index workflow does.
TMP_LISTING=$(mktemp)
rclone --config "${CONFIG_FILE}" cat \
  "${REMOTE}:${S3_BUCKET}/${S3_PATH}/listing.jsonl" 2>/dev/null > "${TMP_LISTING}" || true

# Newest-first: our fragment lines first, then existing lines (deduped by fileName).
cat "${OUT_DIR}/listing-fragment.jsonl" "${TMP_LISTING}" \
  | awk '!seen[$0]++' \
  | head -n 1000 > "${TMP_LISTING}.new"

rclone --config "${CONFIG_FILE}" copyto \
  "${TMP_LISTING}.new" \
  "${REMOTE}:${S3_BUCKET}/${S3_PATH}/listing.jsonl"

rm -f "${TMP_LISTING}" "${TMP_LISTING}.new"
echo "::endgroup::"

echo "::group::Upload run log"
if [[ -f "${OUT_DIR}/lodestar.log" ]]; then
  rclone --config "${CONFIG_FILE}" copy \
    "${OUT_DIR}/lodestar.log" \
    "${REMOTE}:${S3_BUCKET}/${S3_PATH}/"
fi
echo "::endgroup::"

PUBLIC_URL="${S3_PUBLIC_URL:-https://hive.ethpandaops.io/${S3_PATH}/}"
echo "result_url=${PUBLIC_URL}" >> "${GITHUB_OUTPUT}"
echo "result_url=${PUBLIC_URL}"
