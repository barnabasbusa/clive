#!/usr/bin/env bash
set -euo pipefail

# Lodestar adapter: clone, install, build, run spec tests, emit JUnit + raw logs.
#
# Inputs (env):
#   ACTION_PATH               - clive action root (provided by composite step)
#   OUT_DIR                   - where to deposit JUnit XML + raw stdout
#   CL_SOURCE_REPO            - e.g. ChainSafe/lodestar
#   CL_SOURCE_REF             - tag/branch/commit
#   CONSENSUS_SPEC_TESTS_REF  - optional override of the fixtures version.
#                               Empty -> use the version pinned in the client repo
#                               (Lodestar reads it from `spec-tests-version.json`).
#   NETWORK                   - devnet label (for log/result naming)
#   CLIVE_TEST_SCOPE          - optional. one of:
#                                 full         (default; everything)
#                                 bls          (only BLS spec tests — fast smoke)
#                                 general      (general only)
#                                 minimal      (minimal presets only)
#                                 mainnet      (mainnet presets only)
#
# Outputs ($GITHUB_OUTPUT):
#   client_version            - resolved version string from the source tree
#   consensus_spec_tests_ref  - the effective fixtures ref (whether user-supplied
#                               or read back from the source pin)

mkdir -p "${OUT_DIR}"
SRC_DIR="${ACTION_PATH}/.cache/lodestar"
LOG_FILE="${OUT_DIR}/lodestar.log"
JUNIT_DIR="${OUT_DIR}/junit"
mkdir -p "${JUNIT_DIR}"

SCOPE="${CLIVE_TEST_SCOPE:-full}"

echo "::group::Clone ${CL_SOURCE_REPO}@${CL_SOURCE_REF}"
rm -rf "${SRC_DIR}"
if ! git clone --depth 1 --branch "${CL_SOURCE_REF}" \
  "https://github.com/${CL_SOURCE_REPO}.git" "${SRC_DIR}" 2>&1 | tee -a "${LOG_FILE}"; then
  # depth-1 fails on raw SHAs; retry full clone + checkout
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
if [[ ! -f "${PIN_FILE}" ]]; then
  echo "::error::expected ${PIN_FILE} in the Lodestar source tree; file missing"
  exit 1
fi
PINNED_REF=$(jq -r '.ethereumConsensusSpecsTests.specVersion' "${PIN_FILE}")
if [[ -z "${PINNED_REF}" || "${PINNED_REF}" == "null" ]]; then
  echo "::error::could not read .ethereumConsensusSpecsTests.specVersion from ${PIN_FILE}"
  exit 1
fi
echo "pinned spec-tests version: ${PINNED_REF}"

EFFECTIVE_REF="${CONSENSUS_SPEC_TESTS_REF:-$PINNED_REF}"
echo "effective consensus-spec-tests ref: ${EFFECTIVE_REF}"

# When the caller asked for a version different from Lodestar's pin, patch the
# pin file in place so `pnpm download-spec-tests` (which reads exclusively from
# spec-tests-version.json) fetches the requested version.
if [[ -n "${CONSENSUS_SPEC_TESTS_REF}" && "${CONSENSUS_SPEC_TESTS_REF}" != "${PINNED_REF}" ]]; then
  echo "::warning::overriding lodestar's pinned spec-tests version: ${PINNED_REF} -> ${CONSENSUS_SPEC_TESTS_REF}"
  jq --arg v "${CONSENSUS_SPEC_TESTS_REF}" \
    '.ethereumConsensusSpecsTests.specVersion = $v' \
    "${PIN_FILE}" > "${PIN_FILE}.new"
  mv "${PIN_FILE}.new" "${PIN_FILE}"
  echo "patched ${PIN_FILE}:"
  jq . "${PIN_FILE}"
fi
echo "::endgroup::"

echo "::group::Resolve client_version"
CLIENT_VERSION=$(jq -r .version package.json 2>/dev/null || echo "")
if [[ -z "${CLIENT_VERSION}" || "${CLIENT_VERSION}" == "null" ]]; then
  CLIENT_VERSION="${CL_SOURCE_REF}"
fi
CLIENT_VERSION="${CLIENT_VERSION}-${RESOLVED_SHA:0:8}"
echo "client_version=${CLIENT_VERSION}"
echo "::endgroup::"

echo "::group::Activate pnpm via corepack"
# Lodestar pins pnpm via package.json#packageManager; corepack picks it up.
corepack enable >> "${LOG_FILE}" 2>&1
# `corepack prepare` reads the pin and installs the matching pnpm.
PACKAGE_MANAGER=$(jq -r '.packageManager // empty' package.json)
if [[ -n "${PACKAGE_MANAGER}" ]]; then
  corepack prepare "${PACKAGE_MANAGER}" --activate 2>&1 | tee -a "${LOG_FILE}"
else
  corepack prepare pnpm@latest --activate 2>&1 | tee -a "${LOG_FILE}"
fi
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

# Call vitest directly (bypassing `pnpm <script> --`) so reporter/outputFile
# flags reach vitest unambiguously. Lodestar's vitest.config.ts hard-sets
# `reporters` via getReporters(), but CLI `--reporter` replaces that.
JUNIT_OUT="${JUNIT_DIR}/lodestar-spec.xml"
BEACON_DIR="${SRC_DIR}/packages/beacon-node"

vitest_run() {
  local label="$1"; shift
  echo "::group::vitest [${label}]: pnpm exec vitest run $*"
  ( cd "${BEACON_DIR}" && \
    pnpm exec vitest run "$@" \
      --reporter=junit \
      --outputFile="${JUNIT_OUT}" \
  ) 2>&1 | tee -a "${LOG_FILE}"
  local rc=${PIPESTATUS[0]}
  echo "vitest [${label}] exit: ${rc}"
  echo "::endgroup::"
  return $rc
}

set +e
case "${SCOPE}" in
  bls)
    vitest_run "bls/minimal"      --project spec-minimal test/spec/bls/
    ;;
  general)
    vitest_run "general/minimal"  --project spec-minimal test/spec/general/
    ;;
  minimal)
    vitest_run "presets/minimal"  --project spec-minimal test/spec/presets/
    ;;
  mainnet)
    vitest_run "presets/mainnet"  --project spec-mainnet test/spec/presets/
    ;;
  full)
    # Sequenced; each run rewrites the junit file. We rename between runs so the
    # later normaliser sees all of them.
    vitest_run "bls/minimal"     --project spec-minimal test/spec/bls/ \
      && mv "${JUNIT_OUT}" "${JUNIT_DIR}/lodestar-bls.xml" || true
    vitest_run "general/minimal" --project spec-minimal test/spec/general/ \
      && mv "${JUNIT_OUT}" "${JUNIT_DIR}/lodestar-general.xml" || true
    vitest_run "presets/minimal" --project spec-minimal test/spec/presets/ \
      && mv "${JUNIT_OUT}" "${JUNIT_DIR}/lodestar-presets-minimal.xml" || true
    vitest_run "presets/mainnet" --project spec-mainnet test/spec/presets/ \
      && mv "${JUNIT_OUT}" "${JUNIT_DIR}/lodestar-presets-mainnet.xml" || true
    ;;
  *)
    echo "::error::unknown CLIVE_TEST_SCOPE: ${SCOPE}"
    exit 1
    ;;
esac
RC=$?
set -e
echo "::group::JUnit artefacts"
ls -lah "${JUNIT_DIR}" 2>&1 | tee -a "${LOG_FILE}" || true
echo "::endgroup::"

{
  echo "client_version=${CLIENT_VERSION}"
  echo "consensus_spec_tests_ref=${EFFECTIVE_REF}"
} >> "${GITHUB_OUTPUT}"

# Don't propagate the spec-test exit code yet; gate.sh decides based on the
# fail_on category list after the JUnit summarizer has run.
exit 0
