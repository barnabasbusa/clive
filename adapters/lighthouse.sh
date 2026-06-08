#!/usr/bin/env bash
set -euo pipefail

# Lighthouse adapter: clone, fetch fixtures (via testing/ef_tests/Makefile),
# run cargo-nextest with a clive-installed profile that emits JUnit, then write
# clive-meta.json describing the suite.
#
# Inputs (env):
#   ACTION_PATH               - clive action root
#   OUT_DIR                   - where to deposit JUnit XML + raw stdout
#   CL_SOURCE_REPO            - e.g. sigp/lighthouse
#   CL_SOURCE_REF             - tag/branch/commit
#   CONSENSUS_SPEC_TESTS_REF  - optional override of fixtures version
#                               (Lighthouse reads CONSENSUS_SPECS_TEST_VERSION
#                               from testing/ef_tests/Makefile; we forward this
#                               input to it).
#   NETWORK                   - devnet label
#   CLIVE_TEST_SCOPE          - smoke | full (default: full)
#                                 smoke: only fake_crypto pass, single test filter
#                                 full:  both real-crypto and fake_crypto passes
#
# Outputs ($GITHUB_OUTPUT):
#   client_version, consensus_spec_tests_ref

mkdir -p "${OUT_DIR}/junit"
SRC_DIR="${ACTION_PATH}/.cache/lighthouse"
LOG_FILE="${OUT_DIR}/lighthouse.log"
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
EF_MAKEFILE="${SRC_DIR}/testing/ef_tests/Makefile"
[[ -f "${EF_MAKEFILE}" ]] || { echo "::error::${EF_MAKEFILE} missing"; exit 1; }
PINNED_REF=$(grep -E '^CONSENSUS_SPECS_TEST_VERSION ?\??= ?' "${EF_MAKEFILE}" \
  | head -1 | sed -E 's/^[^=]*= *//')
EFFECTIVE_REF="${CONSENSUS_SPEC_TESTS_REF:-$PINNED_REF}"
echo "pinned=${PINNED_REF} effective=${EFFECTIVE_REF}"
echo "::endgroup::"

echo "::group::Resolve client_version"
CARGO_VERSION=$(grep -E '^version ?= ?"' Cargo.toml | head -1 | sed -E 's/^[^"]*"([^"]+)"$/\1/')
[[ -z "${CARGO_VERSION}" ]] && CARGO_VERSION="${CL_SOURCE_REF}"
CLIENT_VERSION="${CARGO_VERSION}-${RESOLVED_SHA:0:8}"
echo "client_version=${CLIENT_VERSION}"
echo "::endgroup::"

echo "::group::Install a clive nextest profile"
# `cargo nextest` writes JUnit when a profile config opts in. Drop a config in
# the repo's .config/nextest.toml that hive's `make test-ef` flow leaves alone.
mkdir -p "${SRC_DIR}/.config"
JUNIT_RELATIVE="../../target/nextest/clive/junit.xml"
cat > "${SRC_DIR}/.config/nextest.toml" <<'TOML'
[profile.clive]
fail-fast = false
failure-output = "immediate"
status-level = "fail"

[profile.clive.junit]
path = "junit.xml"
store-success-output = false
store-failure-output = true
report-name = "lighthouse-ef-tests"
TOML
echo "wrote ${SRC_DIR}/.config/nextest.toml"
echo "::endgroup::"

echo "::group::Download consensus-spec-tests fixtures (${EFFECTIVE_REF})"
CONSENSUS_SPECS_TEST_VERSION="${EFFECTIVE_REF}" make -C "${SRC_DIR}/testing/ef_tests" 2>&1 | tee -a "${LOG_FILE}"
echo "::endgroup::"

# --- run --------------------------------------------------------------------
# Lighthouse's `make run-ef-tests` runs nextest twice (real-crypto, fake_crypto).
# For clive's smoke we restrict to a small filter; full does both passes.
SUITES_JSON='[]'

# Helper that runs nextest, copies the resulting junit.xml into OUT_DIR/junit/
# under a clive-controlled name, and registers a suite entry.
run_nextest() {
  local label="$1" features="$2" filter_expr="${3:-}" suite_basename="$4" preset="$5" fork="$6" category="$7" subcategory="$8"
  echo "::group::nextest [${label}] (features=${features})"
  set +e
  ( cd "${SRC_DIR}" \
    && cargo nextest run \
        --profile clive \
        --release \
        -p ef_tests \
        --features "${features}" \
        ${filter_expr:+-E "${filter_expr}"} \
  ) 2>&1 | tee -a "${LOG_FILE}"
  local rc=${PIPESTATUS[0]}
  set -e
  local generated="${SRC_DIR}/target/nextest/clive/junit.xml"
  local destination="${OUT_DIR}/junit/${suite_basename}"
  if [[ -f "${generated}" ]]; then
    cp "${generated}" "${destination}"
    echo "nextest [${label}] exit: ${rc}; junit -> ${destination}"
    SUITES_JSON=$(jq --arg jf "${suite_basename}" \
                    --arg project "ef_tests:${features}" \
                    --arg preset "${preset}" \
                    --arg fork "${fork}" \
                    --arg category "${category}" \
                    --arg subcategory "${subcategory}" \
      '. + [{junit_file:$jf, project:$project, preset:$preset, fork:$fork, category:$category,
             subcategory:(if $subcategory == "" then null else $subcategory end)}]' \
      <<<"${SUITES_JSON}")
  else
    echo "::warning::nextest [${label}] produced no JUnit at ${generated}"
  fi
  echo "::endgroup::"
}

case "${SCOPE}" in
  smoke)
    # Keep the smoke quick: bls + fake_crypto, no real-crypto pass, no large
    # state-transition vector trees.
    run_nextest "bls/fake_crypto" \
      "ef_tests,fake_crypto" \
      "test(/bls/)" \
      "lighthouse-bls.xml" "" "" "bls" ""
    ;;
  full)
    run_nextest "all/real_crypto" \
      "ef_tests" \
      "" \
      "lighthouse-real_crypto.xml" "" "" "all" ""
    run_nextest "all/fake_crypto" \
      "ef_tests,fake_crypto" \
      "" \
      "lighthouse-fake_crypto.xml" "" "" "all" ""
    ;;
  *)
    echo "::error::unknown CLIVE_TEST_SCOPE: ${SCOPE}"; exit 1 ;;
esac

echo "::group::Write clive-meta.json"
jq -n \
  --arg client lighthouse \
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
