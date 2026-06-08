#!/usr/bin/env bash
set -euo pipefail

# Resolves derived inputs and writes them to $GITHUB_OUTPUT for downstream steps.
#
# Inputs (env):
#   CL_CLIENT       - validated to be one of clive's supported clients
#   CL_SOURCE_REPO  - optional override; empty -> use the default per client
#   NETWORK         - devnet/network label, also used as the default S3 path
#   S3_PATH         - optional override; empty -> "spec-${NETWORK}"
#
# Outputs (GITHUB_OUTPUT):
#   cl_source_repo
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

{
  echo "cl_source_repo=${RESOLVED_REPO}"
  echo "s3_path=${RESOLVED_S3_PATH}"
} >> "${GITHUB_OUTPUT}"

echo "cl_source_repo=${RESOLVED_REPO}"
echo "s3_path=${RESOLVED_S3_PATH}"
