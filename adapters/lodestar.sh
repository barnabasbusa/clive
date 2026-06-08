#!/usr/bin/env bash
set -euo pipefail

# Lodestar adapter: clone, install, build, run spec tests, emit per-scope JUnit
# files + clive-meta.json describing what each file represents.
#
# Inputs (env):
#   ACTION_PATH               - clive action root (provided by composite step)
#   OUT_DIR                   - where to deposit JUnit XML + raw stdout
#   CL_SOURCE_REPO            - e.g. ChainSafe/lodestar
#   CL_SOURCE_REF             - tag/branch/commit
#   CONSENSUS_SPEC_TESTS_REF  - optional override of the fixtures version
#   NETWORK                   - devnet label
#   CLIVE_TEST_SCOPE          - bls | general | minimal | mainnet | full
#                               (default: full)
#
# Outputs ($GITHUB_OUTPUT):
#   client_version, consensus_spec_tests_ref

mkdir -p "${OUT_DIR}/junit"
SRC_DIR="${ACTION_PATH}/.cache/lodestar"
LOG_FILE="${OUT_DIR}/lodestar.log"
META_FILE="${OUT_DIR}/clive-meta.json"

SCOPE="${CLIVE_TEST_SCOPE:-full}"

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

echo "::group::Read pinned consensus-spec-tests version"
PIN_FILE="${SRC_DIR}/spec-tests-version.json"
[[ -f "${PIN_FILE}" ]] || { echo "::error::${PIN_FILE} missing"; exit 1; }
PINNED_REF=$(jq -r '.ethereumConsensusSpecsTests.specVersion' "${PIN_FILE}")
EFFECTIVE_REF="${CONSENSUS_SPEC_TESTS_REF:-$PINNED_REF}"
echo "pinned=${PINNED_REF} effective=${EFFECTIVE_REF}"
if [[ -n "${CONSENSUS_SPEC_TESTS_REF}" && "${CONSENSUS_SPEC_TESTS_REF}" != "${PINNED_REF}" ]]; then
  echo "::warning::overriding lodestar's pinned spec-tests version"
  jq --arg v "${CONSENSUS_SPEC_TESTS_REF}" \
    '.ethereumConsensusSpecsTests.specVersion = $v' \
    "${PIN_FILE}" > "${PIN_FILE}.new"
  mv "${PIN_FILE}.new" "${PIN_FILE}"
fi
echo "::endgroup::"

echo "::group::Resolve client_version"
CLIENT_VERSION=$(jq -r .version package.json 2>/dev/null || echo "")
[[ -z "${CLIENT_VERSION}" || "${CLIENT_VERSION}" == "null" ]] && CLIENT_VERSION="${CL_SOURCE_REF}"
CLIENT_VERSION="${CLIENT_VERSION}-${RESOLVED_SHA:0:8}"
echo "client_version=${CLIENT_VERSION}"
echo "::endgroup::"

echo "::group::Activate pnpm via corepack"
corepack enable >> "${LOG_FILE}" 2>&1
PACKAGE_MANAGER=$(jq -r '.packageManager // empty' package.json)
[[ -n "${PACKAGE_MANAGER}" ]] \
  && corepack prepare "${PACKAGE_MANAGER}" --activate 2>&1 | tee -a "${LOG_FILE}" \
  || corepack prepare pnpm@latest --activate 2>&1 | tee -a "${LOG_FILE}"
pnpm --version | tee -a "${LOG_FILE}"
echo "::endgroup::"

echo "::group::pnpm install"
pnpm install --frozen-lockfile 2>&1 | tee -a "${LOG_FILE}"
echo "::endgroup::"

echo "::group::pnpm build"
pnpm build 2>&1 | tee -a "${LOG_FILE}"
echo "::endgroup::"

echo "::group::pnpm download-spec-tests (${EFFECTIVE_REF})"
pnpm download-spec-tests 2>&1 | tee -a "${LOG_FILE}"
echo "::endgroup::"

BEACON_DIR="${SRC_DIR}/packages/beacon-node"
SUITES_JSON='[]'

# Run a single vitest project, writing the JUnit XML into ${OUT_DIR}/junit.
# Adds a suite entry to ${SUITES_JSON}.
#
# Args:
#   label         - clive scope label (also becomes the suite JUnit filename)
#   junit_basename
#   project       - vitest project name (spec-minimal | spec-mainnet)
#   preset        - canonical preset string for clive-meta
#   fork          - "" when suite is multi-fork (preset suites)
#   category      - clive category string
#   path          - vitest test path
#   node_opts     - extra NODE_OPTIONS for the run (e.g. heap size for mainnet)
vitest_run() {
  local label="$1" junit_basename="$2" project="$3" preset="$4" fork="$5" category="$6" path="$7" node_opts="${8:-}"
  local junit_path="${OUT_DIR}/junit/${junit_basename}"
  echo "::group::vitest [${label}]"
  ( cd "${BEACON_DIR}" \
    && NODE_OPTIONS="${node_opts}" \
       pnpm exec vitest run --project "${project}" "${path}" \
        --reporter=junit \
        --outputFile="${junit_path}" \
  ) 2>&1 | tee -a "${LOG_FILE}"
  local rc=${PIPESTATUS[0]}
  echo "vitest [${label}] exit: ${rc}; junit: ${junit_path}"
  echo "::endgroup::"
  if [[ -f "${junit_path}" ]]; then
    SUITES_JSON=$(jq --arg jf "${junit_basename}" \
                    --arg project "${project}" \
                    --arg preset "${preset}" \
                    --arg fork "${fork}" \
                    --arg category "${category}" \
      '. + [{junit_file:$jf, project:$project, preset:$preset, fork:$fork, category:$category, subcategory:null}]' \
      <<<"${SUITES_JSON}")
  else
    echo "::warning::no JUnit file produced for ${label}; suite omitted from clive-meta"
  fi
  return $rc
}

set +e
case "${SCOPE}" in
  bls)
    vitest_run "bls/minimal"          "lodestar-bls.xml"               spec-minimal minimal "" bls               test/spec/bls/
    ;;
  general)
    vitest_run "general/minimal"      "lodestar-general.xml"           spec-minimal minimal "" ssz_generic       test/spec/general/
    ;;
  minimal)
    vitest_run "presets/minimal"      "lodestar-presets-minimal.xml"   spec-minimal minimal "" sanity            test/spec/presets/
    ;;
  mainnet)
    vitest_run "presets/mainnet"      "lodestar-presets-mainnet.xml"   spec-mainnet mainnet "" sanity            test/spec/presets/ \
      "--max-old-space-size=4096"
    ;;
  full)
    vitest_run "bls/minimal"          "lodestar-bls.xml"               spec-minimal minimal "" bls               test/spec/bls/
    vitest_run "general/minimal"      "lodestar-general.xml"           spec-minimal minimal "" ssz_generic       test/spec/general/
    vitest_run "presets/minimal"      "lodestar-presets-minimal.xml"   spec-minimal minimal "" sanity            test/spec/presets/
    vitest_run "presets/mainnet"      "lodestar-presets-mainnet.xml"   spec-mainnet mainnet "" sanity            test/spec/presets/ \
      "--max-old-space-size=4096"
    ;;
  *)
    echo "::error::unknown CLIVE_TEST_SCOPE: ${SCOPE}"; exit 1 ;;
esac
set -e

echo "::group::JUnit artefacts"
ls -lah "${OUT_DIR}/junit" 2>&1 | tee -a "${LOG_FILE}" || true
echo "::endgroup::"

echo "::group::Write clive-meta.json"
jq -n \
  --arg client lodestar \
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
