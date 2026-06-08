#!/usr/bin/env bash
set -euo pipefail

# Upload normalised results to S3 and (re)generate listing.jsonl from the full
# `results/` set. Mirrors the pattern hive-github-action uses for its own
# listing.jsonl: don't append, regenerate from the source of truth.
#
# Inputs (env):
#   ACTION_PATH     - composite action root (for invoking lib/regen-listing.py)
#   OUT_DIR         - contains results/*.json + lodestar.log
#   S3_BUCKET       - bucket name (default 'hive-results' resolved upstream)
#   S3_PATH         - e.g. spec-glamsterdam-devnet-5
#   S3_PUBLIC_URL   - optional public URL prefix for the result_url output
#
# Assumes rclone is already set up via AnimMouse/setup-rclone with a remote
# named `s3` (hive-github-action's convention).

REMOTE="s3"

echo "::group::Push results/ to S3"
if [[ -d "${OUT_DIR}/results" && -n "$(ls -A "${OUT_DIR}/results" 2>/dev/null)" ]]; then
  rclone copy --no-traverse \
    "${OUT_DIR}/results/" \
    "${REMOTE}:${S3_BUCKET}/${S3_PATH}/results/"
else
  echo "::warning::no results/*.json to upload"
fi
echo "::endgroup::"

echo "::group::Push run log"
if [[ -f "${OUT_DIR}/lodestar.log" ]]; then
  rclone copy "${OUT_DIR}/lodestar.log" "${REMOTE}:${S3_BUCKET}/${S3_PATH}/"
fi
echo "::endgroup::"

echo "::group::Regenerate listing.jsonl from full results set"
TMP_RESULTS=$(mktemp -d)
trap 'rm -rf "${TMP_RESULTS}"' EXIT

# Pull every result back down so the listing reflects all historical runs, not
# just this one.
rclone copy --progress --transfers=50 --include "*.json" \
  "${REMOTE}:${S3_BUCKET}/${S3_PATH}/results/" "${TMP_RESULTS}/" || true

LISTING="${OUT_DIR}/listing.jsonl"
python3 "${ACTION_PATH}/lib/regen-listing.py" \
  --results-dir "${TMP_RESULTS}" \
  --output "${LISTING}"

echo "regenerated $(wc -l < "${LISTING}" | tr -d ' ') row(s) into ${LISTING}"
rclone copyto "${LISTING}" "${REMOTE}:${S3_BUCKET}/${S3_PATH}/listing.jsonl"
echo "::endgroup::"

PUBLIC_URL="${S3_PUBLIC_URL:-https://hive.ethpandaops.io/${S3_PATH}/}"
echo "result_url=${PUBLIC_URL}" >> "${GITHUB_OUTPUT}"
echo "result_url=${PUBLIC_URL}"
