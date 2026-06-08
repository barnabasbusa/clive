#!/usr/bin/env bash
set -euo pipefail

# Lodestar adapter: clone, build, run spec tests, emit JUnit + raw logs.
#
# Inputs (env):
#   ACTION_PATH               - clive action root (provided by composite step)
#   OUT_DIR                   - where to deposit JUnit XML + raw stdout
#   CL_SOURCE_REPO            - e.g. ChainSafe/lodestar
#   CL_SOURCE_REF             - tag/branch/commit
#   CONSENSUS_SPEC_TESTS_REF  - optional override of the fixtures version.
#                               Empty -> use the version pinned in the client repo.
#   NETWORK                   - devnet label (for log/result naming)
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

echo "::group::Clone ${CL_SOURCE_REPO}@${CL_SOURCE_REF}"
rm -rf "${SRC_DIR}"
git clone --depth 1 --branch "${CL_SOURCE_REF}" \
  "https://github.com/${CL_SOURCE_REPO}.git" "${SRC_DIR}" 2>&1 | tee -a "${LOG_FILE}" || {
    # depth-1 fails on raw SHAs; retry full clone + checkout
    rm -rf "${SRC_DIR}"
    git clone "https://github.com/${CL_SOURCE_REPO}.git" "${SRC_DIR}" 2>&1 | tee -a "${LOG_FILE}"
    git -C "${SRC_DIR}" checkout "${CL_SOURCE_REF}" 2>&1 | tee -a "${LOG_FILE}"
}
RESOLVED_SHA=$(git -C "${SRC_DIR}" rev-parse HEAD)
echo "resolved HEAD: ${RESOLVED_SHA}"
echo "::endgroup::"

cd "${SRC_DIR}"

echo "::group::Read pinned spec-tests version"
# Lodestar pins the spec-tests version in a constants file. The exact path has
# moved over time; probe the common locations and grep for a SemVer.
PINNED_REF=""
for f in \
  packages/spec-test-runner/src/specTestVersioning.ts \
  packages/beacon-node/test/spec/specTestVersioning.ts \
  packages/state-transition/test/spec/specTestVersioning.ts \
  packages/spec-test-util/src/specTestVersioning.ts; do
  if [[ -f "$f" ]]; then
    PINNED_REF=$(grep -Eo 'v[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.]+)?' "$f" | head -1 || true)
    if [[ -n "${PINNED_REF}" ]]; then
      echo "  found pin in $f: ${PINNED_REF}"
      break
    fi
  fi
done
if [[ -z "${PINNED_REF}" ]]; then
  echo "::warning::could not find a pinned consensus-spec-tests version in the lodestar source tree"
fi

EFFECTIVE_REF="${CONSENSUS_SPEC_TESTS_REF:-$PINNED_REF}"
if [[ -z "${EFFECTIVE_REF}" ]]; then
  echo "::error::no consensus_spec_tests_ref provided and no pin found in source"
  exit 1
fi
echo "effective consensus-spec-tests ref: ${EFFECTIVE_REF}"
echo "::endgroup::"

echo "::group::Resolve client_version"
CLIENT_VERSION=$(jq -r .version package.json 2>/dev/null || echo "")
if [[ -z "${CLIENT_VERSION}" || "${CLIENT_VERSION}" == "null" ]]; then
  CLIENT_VERSION="${CL_SOURCE_REF}"
fi
CLIENT_VERSION="${CLIENT_VERSION}-${RESOLVED_SHA:0:8}"
echo "client_version=${CLIENT_VERSION}"
echo "::endgroup::"

echo "::group::yarn install"
corepack enable
corepack prepare yarn@stable --activate
yarn install --immutable 2>&1 | tee -a "${LOG_FILE}"
echo "::endgroup::"

echo "::group::yarn build"
yarn build 2>&1 | tee -a "${LOG_FILE}"
echo "::endgroup::"

echo "::group::Download consensus-spec-tests fixtures (${EFFECTIVE_REF})"
# Lodestar's own download script reads the pinned version from source. We've
# already let it stay pinned for v0 — overriding the constant requires patching
# multiple files and is left for v1. If a user supplied a different ref, fail
# loudly here so it isn't silently ignored.
if [[ -n "${CONSENSUS_SPEC_TESTS_REF}" && "${CONSENSUS_SPEC_TESTS_REF}" != "${PINNED_REF}" ]]; then
  echo "::error::clive v0 does not yet support overriding lodestar's pinned consensus-spec-tests ref."
  echo "::error::requested=${CONSENSUS_SPEC_TESTS_REF} pinned=${PINNED_REF}"
  echo "::error::leave consensus_spec_tests_ref empty to use the pin, or wait for v1."
  exit 1
fi
yarn download-spec-tests 2>&1 | tee -a "${LOG_FILE}"
echo "::endgroup::"

echo "::group::Run spec tests"
set +e
# Vitest supports a JUnit reporter via env var; route its output into OUT_DIR
# so junit-to-hive.py can pick it up.
VITEST_JUNIT_OUTPUT_FILE="${JUNIT_DIR}/lodestar-spec.xml" \
yarn test:spec --reporter=junit --outputFile="${JUNIT_DIR}/lodestar-spec.xml" 2>&1 | tee -a "${LOG_FILE}"
RC=$?
set -e
echo "spec test exit code: ${RC}"
echo "::endgroup::"

{
  echo "client_version=${CLIENT_VERSION}"
  echo "consensus_spec_tests_ref=${EFFECTIVE_REF}"
} >> "${GITHUB_OUTPUT}"

# Don't propagate the spec-test exit code yet; gate.sh decides based on the
# fail_on category list after the JUnit summarizer has run.
exit 0
