#!/usr/bin/env bash
set -euo pipefail

# Resolves derived inputs and writes them to $GITHUB_OUTPUT for downstream steps.
#
# Inputs (env):
#   CL_CLIENT       - validated to be one of clive's supported clients
#   CL_SOURCE_REPO  - optional override; empty -> use the default per client
#   CL_SOURCE_REF   - optional. Tag, branch, SHA. Empty -> latest release tag
#                     of CL_SOURCE_REPO (resolved via GitHub API).
#   NETWORK         - devnet/network label, also used as the default S3 path
#   S3_PATH         - optional override; empty -> "spec-${NETWORK}"
#
# Outputs (GITHUB_OUTPUT):
#   cl_source_repo
#   cl_source_ref
#   s3_path

case "${CL_CLIENT}" in
  lodestar)
    DEFAULT_REPO="ChainSafe/lodestar"
    ;;
  *)
    echo "::error::unsupported cl_client: ${CL_CLIENT}"
    exit 1
    ;;
esac

RESOLVED_REPO="${CL_SOURCE_REPO:-$DEFAULT_REPO}"
RESOLVED_S3_PATH="${S3_PATH:-spec-${NETWORK}}"

# Resolve cl_source_ref. Accepts:
#   - explicit tag (e.g. v1.43.0)
#   - explicit branch (e.g. unstable)
#   - explicit commit SHA
#   - empty -> latest release tag (non-prerelease) of CL_SOURCE_REPO
RESOLVED_REF="${CL_SOURCE_REF:-}"
if [[ -z "${RESOLVED_REF}" ]]; then
  echo "cl_source_ref empty; resolving latest release of ${RESOLVED_REPO}"
  if ! command -v gh >/dev/null 2>&1; then
    echo "::error::gh CLI not available on the runner; required to resolve latest release. Pass cl_source_ref explicitly or install gh."
    exit 1
  fi
  RESOLVED_REF=$(gh api "repos/${RESOLVED_REPO}/releases/latest" --jq .tag_name 2>/dev/null || true)
  if [[ -z "${RESOLVED_REF}" || "${RESOLVED_REF}" == "null" ]]; then
    echo "::error::could not resolve latest release for ${RESOLVED_REPO}. Pass cl_source_ref explicitly."
    exit 1
  fi
  echo "resolved latest release: ${RESOLVED_REF}"
fi

{
  echo "cl_source_repo=${RESOLVED_REPO}"
  echo "cl_source_ref=${RESOLVED_REF}"
  echo "s3_path=${RESOLVED_S3_PATH}"
} >> "${GITHUB_OUTPUT}"

echo "cl_source_repo=${RESOLVED_REPO}"
echo "cl_source_ref=${RESOLVED_REF}"
echo "s3_path=${RESOLVED_S3_PATH}"
