#!/usr/bin/env bash
set -euo pipefail

# Nimbus adapter: clone, bootstrap nim, build the XML-output spec-test binary,
# run it with --xml:..., then write clive-meta.json describing the suite.
#
# Inputs (env):
#   ACTION_PATH               - clive action root
#   OUT_DIR                   - where to deposit JUnit XML + raw stdout
#   CL_SOURCE_REPO            - e.g. status-im/nimbus-eth2
#   CL_SOURCE_REF             - tag/branch/commit
#   CONSENSUS_SPEC_TESTS_REF  - optional, not honoured by Nimbus yet (warns)
#   NETWORK                   - devnet label
#   CLIVE_TEST_SCOPE          - minimal | mainnet | full (default: minimal)
#                                Nimbus splits preset at COMPILE time, so each
#                                preset is a different binary.
#
# Outputs ($GITHUB_OUTPUT):
#   client_version, consensus_spec_tests_ref

mkdir -p "${OUT_DIR}/junit"
SRC_DIR="${ACTION_PATH}/.cache/nimbus-eth2"
LOG_FILE="${OUT_DIR}/nimbus.log"
META_FILE="${OUT_DIR}/clive-meta.json"
SCOPE="${CLIVE_TEST_SCOPE:-minimal}"

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
# Nimbus's version-string lives in a beacon_chain/version.nim file; fall back to
# the ref if we can't parse it cheaply.
NIMBUS_VERSION_RAW=$(grep -E 'versionMajor|versionMinor|versionBuild' beacon_chain/version.nim 2>/dev/null \
  | sed -E 's/.*= *([0-9]+).*/\1/' | tr '\n' '.' || true)
[[ -z "${NIMBUS_VERSION_RAW}" ]] && NIMBUS_VERSION_RAW="${CL_SOURCE_REF}"
CLIENT_VERSION="${NIMBUS_VERSION_RAW%.}-${RESOLVED_SHA:0:8}"
echo "client_version=${CLIENT_VERSION}"
echo "::endgroup::"

if [[ -n "${CONSENSUS_SPEC_TESTS_REF}" ]]; then
  echo "::warning::Nimbus pins its spec-test fixtures via scripts/setup_scenarios.sh; clive cannot override it yet. Ignoring CONSENSUS_SPEC_TESTS_REF=${CONSENSUS_SPEC_TESTS_REF}"
fi

echo "::group::Nimbus toolchain bootstrap (make update)"
# `make update` fetches submodules + builds the vendored nim compiler.
# This is the slow step (5-15 min cold).
make -j"$(nproc 2>/dev/null || sysctl -n hw.ncpu)" update 2>&1 | tee -a "${LOG_FILE}"
echo "::endgroup::"

echo "::group::Download consensus-spec-tests fixtures"
# Nimbus's scenario script writes to vendor/nim-eth2-scenarios/...
scripts/setup_scenarios.sh fixturesCache 2>&1 | tee -a "${LOG_FILE}"
echo "::endgroup::"

# Helper: build then run one preset binary; copy its JUnit + register a suite.
run_preset() {
  local preset="$1" suite_basename="$2"
  local binary="consensus_spec_tests_${preset}"
  echo "::group::Build ${binary}"
  make -j"$(nproc 2>/dev/null || sysctl -n hw.ncpu)" \
    DISABLE_TEST_FIXTURES_SCRIPT=1 \
    "${binary}" 2>&1 | tee -a "${LOG_FILE}"
  echo "::endgroup::"

  echo "::group::Run ${binary}"
  set +e
  ./build/"${binary}" --xml:"./build/${binary}.xml" --console 2>&1 | tee -a "${LOG_FILE}"
  local rc=$?
  set -e
  echo "${binary} exit: ${rc}"
  echo "::endgroup::"

  local generated="${SRC_DIR}/build/${binary}.xml"
  local destination="${OUT_DIR}/junit/${suite_basename}"
  if [[ -f "${generated}" ]]; then
    cp "${generated}" "${destination}"
    echo "junit -> ${destination}"
    SUITES_JSON=$(jq --arg jf "${suite_basename}" \
                    --arg project "${binary}" \
                    --arg preset "${preset}" \
      '. + [{junit_file:$jf, project:$project, preset:$preset, fork:"", category:"sanity", subcategory:null}]' \
      <<<"${SUITES_JSON}")
  else
    echo "::warning::no JUnit produced at ${generated}"
  fi
}

SUITES_JSON='[]'
case "${SCOPE}" in
  minimal) run_preset minimal "nimbus-presets-minimal.xml" ;;
  mainnet) run_preset mainnet "nimbus-presets-mainnet.xml" ;;
  full)
    run_preset minimal "nimbus-presets-minimal.xml"
    run_preset mainnet "nimbus-presets-mainnet.xml"
    ;;
  *)
    echo "::error::unknown CLIVE_TEST_SCOPE: ${SCOPE}"; exit 1 ;;
esac

echo "::group::Resolve consensus-spec-tests version that was downloaded"
# scripts/setup_scenarios.sh pins the version internally; surface what it
# actually placed on disk so clive-meta records the effective ref.
EFFECTIVE_REF="${CONSENSUS_SPEC_TESTS_REF:-}"
if [[ -z "${EFFECTIVE_REF}" ]]; then
  EFFECTIVE_REF=$(find vendor -maxdepth 6 -type d -name 'tests' 2>/dev/null \
    | head -1 | xargs -I{} dirname {} 2>/dev/null \
    | xargs -I{} cat {}/VERSION 2>/dev/null | head -1 || true)
  [[ -z "${EFFECTIVE_REF}" ]] && EFFECTIVE_REF="unknown"
fi
echo "effective consensus-spec-tests ref: ${EFFECTIVE_REF}"
echo "::endgroup::"

echo "::group::Write clive-meta.json"
jq -n \
  --arg client nimbus \
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
