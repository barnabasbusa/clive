#!/usr/bin/env bash
set -euo pipefail

# Prysm adapter: clone, install Bazelisk, run a narrow `bazel test` against the
# spectest packages, harvest bazel's per-target `test.xml`, and emit
# clive-meta.json.
#
# Inputs (env):
#   ACTION_PATH               - clive action root
#   OUT_DIR                   - where to deposit JUnit XML + raw stdout
#   CL_SOURCE_REPO            - e.g. prysmaticlabs/prysm
#   CL_SOURCE_REF             - tag/branch/commit
#   CONSENSUS_SPEC_TESTS_REF  - currently informational (Prysm pulls fixtures
#                               via Bazel rules that pin the version internally)
#   NETWORK                   - devnet label
#   CLIVE_TEST_SCOPE          - smoke | full (default: smoke)
#                                 smoke: bazel test //testing/spectest/general/...
#                                 full:  bazel test //testing/spectest/...
#
# Outputs ($GITHUB_OUTPUT):
#   client_version, consensus_spec_tests_ref

mkdir -p "${OUT_DIR}/junit"
SRC_DIR="${ACTION_PATH}/.cache/prysm"
LOG_FILE="${OUT_DIR}/prysm.log"
META_FILE="${OUT_DIR}/clive-meta.json"
SCOPE="${CLIVE_TEST_SCOPE:-smoke}"

echo "::group::Clone ${CL_SOURCE_REPO}@${CL_SOURCE_REF}"
rm -rf "${SRC_DIR}"
if ! git clone --depth 1 --branch "${CL_SOURCE_REF}" \
  "https://github.com/${CL_SOURCE_REPO}.git" "${SRC_DIR}" 2>&1 | tee -a "${LOG_FILE}"; then
  rm -rf "${SRC_DIR}"
  git clone "https://github.com/${CL_SOURCE_REPO}.git" "${SRC_DIR}" 2>&1 | tee -a "${LOG_FILE}"
  git -C "${SRC_DIR}" checkout "${CL_SOURCE_REF}" 2>&1 | tee -a "${LOG_FILE}"
fi
RESOLVED_SHA=$(git -C "${SRC_DIR}" rev-parse HEAD)
echo "resolved HEAD: ${RESOLVED_SHA}"
echo "::endgroup::"

cd "${SRC_DIR}"

echo "::group::Resolve client_version"
PRYSM_VERSION=$(cat runtime/version/version.go 2>/dev/null \
  | grep -E '^\s*version\s*=' | head -1 | sed -E 's/.*"([^"]+)".*/\1/' || true)
[[ -z "${PRYSM_VERSION}" ]] && PRYSM_VERSION="${CL_SOURCE_REF}"
CLIENT_VERSION="${PRYSM_VERSION}-${RESOLVED_SHA:0:8}"
echo "client_version=${CLIENT_VERSION}"
echo "::endgroup::"

echo "::group::Bazel toolchain"
# Bazelisk is the recommended Bazel launcher; respects .bazelversion in repo.
which bazel || true
which bazelisk || true
bazel --version 2>&1 || true
echo "::endgroup::"

case "${SCOPE}" in
  smoke) BAZEL_TARGETS="//testing/spectest/general/..." ;;
  full)  BAZEL_TARGETS="//testing/spectest/..." ;;
  *)     echo "::error::unknown CLIVE_TEST_SCOPE: ${SCOPE}"; exit 1 ;;
esac

echo "::group::bazel test ${BAZEL_TARGETS}"
set +e
bazel test \
  --test_output=errors \
  --keep_going \
  ${BAZEL_TARGETS} 2>&1 | tee -a "${LOG_FILE}"
RC=$?
set -e
echo "bazel exit: ${RC}"
echo "::endgroup::"

echo "::group::Harvest JUnit XML from bazel-testlogs"
HARVEST_DIR="${OUT_DIR}/junit"
TESTLOGS_DIR="${SRC_DIR}/bazel-testlogs"
SUITES_JSON='[]'
COUNT=0
if [[ -d "${TESTLOGS_DIR}" ]]; then
  while IFS= read -r xml; do
    rel="${xml#${TESTLOGS_DIR}/}"
    flat=$(echo "${rel}" | tr '/' '_')
    cp "${xml}" "${HARVEST_DIR}/${flat}"
    COUNT=$((COUNT+1))
  done < <(find "${TESTLOGS_DIR}" -name "test.xml" -type f 2>/dev/null)
fi
echo "harvested ${COUNT} JUnit file(s)"
ls -lah "${HARVEST_DIR}" | tee -a "${LOG_FILE}"

for f in "${HARVEST_DIR}"/*.xml; do
  base=$(basename "${f}")
  # Best-effort: infer preset/category from the file path. testing/spectest/general/
  # = preset-agnostic categories (bls, kzg, ssz_generic).
  case "${base}" in
    *general_bls*) cat="bls"; preset="" ;;
    *general_ssz_generic*) cat="ssz_generic"; preset="" ;;
    *general_kzg*) cat="kzg"; preset="" ;;
    *minimal_*) cat=""; preset="minimal" ;;
    *mainnet_*) cat=""; preset="mainnet" ;;
    *) cat=""; preset="" ;;
  esac
  SUITES_JSON=$(jq --arg jf "${base}" \
                  --arg category "${cat}" \
                  --arg preset "${preset}" \
    '. + [{junit_file:$jf, project:"prysm:bazel-spectest", preset:$preset, fork:"", category:$category, subcategory:null}]' \
    <<<"${SUITES_JSON}")
done
echo "::endgroup::"

EFFECTIVE_REF="${CONSENSUS_SPEC_TESTS_REF:-unknown}"

echo "::group::Write clive-meta.json"
jq -n \
  --arg client prysm \
  --arg source_repo "${CL_SOURCE_REPO}" \
  --arg source_ref "${CL_SOURCE_REF}" \
  --arg source_sha "${RESOLVED_SHA}" \
  --arg client_version "${CLIENT_VERSION}" \
  --arg consensus_spec_tests_ref "${EFFECTIVE_REF}" \
  --arg network "${NETWORK}" \
  --argjson suites "${SUITES_JSON}" \
  '{client:$client, source_repo:$source_repo, source_ref:$source_ref, source_sha:$source_sha,
    client_version:$client_version, consensus_spec_tests_ref:$consensus_spec_tests_ref,
    network:$network, suites:$suites}' > "${META_FILE}"
cat "${META_FILE}"
echo "::endgroup::"

{
  echo "client_version=${CLIENT_VERSION}"
  echo "consensus_spec_tests_ref=${EFFECTIVE_REF}"
} >> "${GITHUB_OUTPUT}"

exit 0
