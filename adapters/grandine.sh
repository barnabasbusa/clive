#!/usr/bin/env bash
set -euo pipefail

# Grandine adapter: clone, install Rust deps, fetch spec-test fixtures via
# Grandine's own script, run cargo-nextest with a clive JUnit profile filtered
# to spec-test-bearing crates, emit clive-meta.json.
#
# Grandine's CI runs `cargo test --workspace`, but for clive we only want the
# spec-test fraction. The narrow filter targets the crates that we know carry
# consensus-spec-tests vector executors.
#
# Inputs (env):
#   ACTION_PATH               - clive action root
#   OUT_DIR                   - where to deposit JUnit XML + raw stdout
#   CL_SOURCE_REPO            - e.g. grandinetech/grandine
#   CL_SOURCE_REF             - tag/branch/commit (Grandine has no
#                               glamsterdam-devnet-5 branch; use the default
#                               branch `develop` for now)
#   CONSENSUS_SPEC_TESTS_REF  - informational; download_spec_tests.sh pins it
#   NETWORK                   - devnet label
#   CLIVE_TEST_SCOPE          - smoke | full (default: smoke)
#                                 smoke: only spec_test_utils + a single
#                                        crate's spec tests
#                                 full:  workspace-wide cargo test
#
# Outputs ($GITHUB_OUTPUT):
#   client_version, consensus_spec_tests_ref

mkdir -p "${OUT_DIR}/junit"
SRC_DIR="${ACTION_PATH}/.cache/grandine"
LOG_FILE="${OUT_DIR}/grandine.log"
META_FILE="${OUT_DIR}/clive-meta.json"
SCOPE="${CLIVE_TEST_SCOPE:-smoke}"

echo "::group::Clone ${CL_SOURCE_REPO}@${CL_SOURCE_REF} (with submodules)"
rm -rf "${SRC_DIR}"
# Grandine vendors eth2_libp2p (and others) via git submodules. A plain shallow
# clone leaves the workspace member directories empty and cargo fails on metadata.
if ! git clone --depth 1 --recurse-submodules --shallow-submodules \
       --branch "${CL_SOURCE_REF}" \
       "https://github.com/${CL_SOURCE_REPO}.git" "${SRC_DIR}" 2>&1 | tee -a "${LOG_FILE}"; then
  rm -rf "${SRC_DIR}"
  git clone --recurse-submodules \
    "https://github.com/${CL_SOURCE_REPO}.git" "${SRC_DIR}" 2>&1 | tee -a "${LOG_FILE}"
  git -C "${SRC_DIR}" checkout "${CL_SOURCE_REF}" 2>&1 | tee -a "${LOG_FILE}"
  git -C "${SRC_DIR}" submodule update --init --recursive 2>&1 | tee -a "${LOG_FILE}"
fi
RESOLVED_SHA=$(git -C "${SRC_DIR}" rev-parse HEAD)
echo "resolved HEAD: ${RESOLVED_SHA}"
echo "::endgroup::"

cd "${SRC_DIR}"

echo "::group::Resolve client_version"
GRANDINE_VERSION=$(grep -E '^version ' Cargo.toml 2>/dev/null \
  | head -1 | sed -E 's/^version *= *"([^"]+)".*/\1/' || true)
[[ -z "${GRANDINE_VERSION}" ]] && GRANDINE_VERSION="${CL_SOURCE_REF}"
CLIENT_VERSION="${GRANDINE_VERSION}-${RESOLVED_SHA:0:8}"
echo "client_version=${CLIENT_VERSION}"
echo "::endgroup::"

echo "::group::Install nextest config (junit profile)"
mkdir -p "${SRC_DIR}/.config"
cat > "${SRC_DIR}/.config/nextest.toml" <<'TOML'
[profile.clive]
fail-fast = false
failure-output = "immediate"
status-level = "fail"

[profile.clive.junit]
path = "junit.xml"
store-success-output = false
store-failure-output = true
report-name = "grandine-spec-tests"
TOML
echo "::endgroup::"

echo "::group::Download consensus-spec-tests fixtures"
# Grandine's helper reads `SPEC_VERSION` from the env (default = its own pin).
# Forward CONSENSUS_SPEC_TESTS_REF when set so we can force a uniform version
# across the matrix.
EFFECTIVE_REF="${CONSENSUS_SPEC_TESTS_REF:-}"
if [[ -n "${EFFECTIVE_REF}" ]]; then
  echo "overriding grandine's pinned spec-tests version -> ${EFFECTIVE_REF}"
  SPEC_VERSION="${EFFECTIVE_REF}" bash scripts/download_spec_tests.sh 2>&1 | tee -a "${LOG_FILE}"
else
  bash scripts/download_spec_tests.sh 2>&1 | tee -a "${LOG_FILE}"
fi
echo "::endgroup::"

# Two run modes:
#   smoke: scope down with nextest's -E filter so we only run one crate's tests,
#          but keep workspace-level features so the workspace graph compiles.
#   full:  match Grandine's own CI: workspace test with the same feature set.
NEXTEST_ARGS=(--profile clive --release
              --no-default-features
              --features default-networks,arkworks,blst
              --workspace
              --exclude zkvm_host --exclude zkvm_guest_risc0
              --exclude c_grandine --exclude csharp_grandine)

case "${SCOPE}" in
  smoke) NEXTEST_ARGS+=(-E 'package(fork_choice_control)') ;;
  full)  : ;;  # run the full workspace
  *)     echo "::error::unknown CLIVE_TEST_SCOPE: ${SCOPE}"; exit 1 ;;
esac

echo "::group::cargo nextest run ${NEXTEST_ARGS[*]}"
set +e
cargo nextest run "${NEXTEST_ARGS[@]}" 2>&1 | tee -a "${LOG_FILE}"
RC=$?
set -e
echo "nextest exit: ${RC}"
echo "::endgroup::"

echo "::group::Harvest JUnit"
HARVEST_DIR="${OUT_DIR}/junit"
GENERATED="${SRC_DIR}/target/nextest/clive/junit.xml"
SUITES_JSON='[]'
if [[ -f "${GENERATED}" ]]; then
  destination="${HARVEST_DIR}/grandine-spec.xml"
  cp "${GENERATED}" "${destination}"
  echo "junit -> ${destination}"
  # Default smoke target is `fork_choice_control` — declare that category so
  # the row lands under `spec/<fork>/fork_choice/<preset>` rather than the
  # `uncategorised` fallback. `full` scope covers the workspace; leaving
  # category empty there lets junit-to-hive.py auto-split.
  case "${SCOPE}" in
    smoke) SMOKE_CATEGORY="fork_choice" ;;
    *)     SMOKE_CATEGORY="" ;;
  esac
  SUITES_JSON=$(jq -n --arg category "${SMOKE_CATEGORY}" \
    '[{junit_file:"grandine-spec.xml", project:"cargo-nextest:clive",
       preset:"", fork:"", category:$category, subcategory:null}]')
else
  echo "::warning::no JUnit produced at ${GENERATED}"
fi
echo "::endgroup::"

# Resolve the effective ref the fixtures landed at — when the caller supplied
# one we used it; otherwise read what download_spec_tests.sh stamped on disk.
if [[ -z "${EFFECTIVE_REF}" ]]; then
  EFFECTIVE_REF=$(cat consensus-spec-tests/.version 2>/dev/null || echo "unknown")
fi

echo "::group::Write clive-meta.json"
jq -n \
  --arg client grandine \
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
