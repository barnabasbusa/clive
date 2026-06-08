#!/usr/bin/env bash
set -euo pipefail

# Teku adapter: clone, run gradle's reference-tests task, harvest the JUnit
# XML that gradle writes by default, and emit clive-meta.json.
#
# Inputs (env):
#   ACTION_PATH               - clive action root
#   OUT_DIR                   - where to deposit JUnit XML + raw stdout
#   CL_SOURCE_REPO            - e.g. Consensys/teku
#   CL_SOURCE_REF             - tag/branch/commit
#   CONSENSUS_SPEC_TESTS_REF  - currently informational (Teku pins via gradle)
#   NETWORK                   - devnet label
#   CLIVE_TEST_SCOPE          - smoke | full (default: smoke)
#                                 smoke: a single category for fast feedback
#                                 full:  the entire reference-tests task
#
# Outputs ($GITHUB_OUTPUT):
#   client_version, consensus_spec_tests_ref

mkdir -p "${OUT_DIR}/junit"
SRC_DIR="${ACTION_PATH}/.cache/teku"
LOG_FILE="${OUT_DIR}/teku.log"
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
TEKU_VERSION=$(grep -E '^version ' build.gradle 2>/dev/null \
  | head -1 | sed -E "s/^version *= *'(.+)'.*/\1/" || true)
[[ -z "${TEKU_VERSION}" ]] && TEKU_VERSION="${CL_SOURCE_REF}"
CLIENT_VERSION="${TEKU_VERSION}-${RESOLVED_SHA:0:8}"
echo "client_version=${CLIENT_VERSION}"
echo "::endgroup::"

echo "::group::Read & override pinned refTestVersion"
PINNED_REF=$(grep -E '^def refTestVersion ' build.gradle 2>/dev/null \
  | sed -E 's/.*"([^"]+)".*/\1/' | tail -1)
echo "pinned refTestVersion: ${PINNED_REF}"
if [[ -n "${CONSENSUS_SPEC_TESTS_REF}" && "${CONSENSUS_SPEC_TESTS_REF}" != "${PINNED_REF}" ]]; then
  echo "::warning::overriding teku's refTestVersion: ${PINNED_REF} -> ${CONSENSUS_SPEC_TESTS_REF}"
  # build.gradle has: def refTestVersion = nightly ? "nightly" : "v1.7.0-alpha.10"
  # Replace just the non-nightly literal.
  sed -i.bak -E \
    "s|(def refTestVersion = nightly \\? \"nightly\" : \")[^\"]+(\")|\\1${CONSENSUS_SPEC_TESTS_REF}\\2|" \
    build.gradle
  diff build.gradle build.gradle.bak | head -10 || true
fi
EFFECTIVE_REF="${CONSENSUS_SPEC_TESTS_REF:-$PINNED_REF}"
echo "effective refTestVersion: ${EFFECTIVE_REF}"
echo "::endgroup::"

echo "::group::Run gradle reference-tests (scope=${SCOPE})"
# Teku's build.gradle declares an aggregate `expandRefTests` task that depends
# on per-category download+extract tasks (general / minimal / mainnet / bls /
# slashing-protection-interchange). The reference test source generator
# (`generateReferenceTestClasses`) reads from
# eth-reference-tests/src/referenceTest/resources/consensus-spec-tests/tests/
# which only exists after that aggregate task has run. We must invoke it
# explicitly before the test task.
#
# Teku's `downloadFile` helper sets an `Authorization: token <T>` header on
# the GitHub release downloads to dodge anonymous rate limits. The smoke
# workflow forwards github.token; if missing we still try, github usually
# tolerates a few unauthenticated tarball pulls.
GRADLE_TASK=":eth-reference-tests:referenceTest"
GRADLE_FILTER=()
case "${SCOPE}" in
  smoke)
    # `BlsTests` in src/ is a registry class with no @Test methods.
    # Real BLS test classes are generated at build time under packages
    # `tech.pegasys.teku.reference.bls_*` (e.g. bls_sign, bls_aggregate,
    # bls_verify, ...). Match the entire package family.
    GRADLE_FILTER+=(--tests "tech.pegasys.teku.reference.bls_*")
    ;;
  full)
    : # no filter — run everything reference-tests defines
    ;;
  *)
    echo "::error::unknown CLIVE_TEST_SCOPE: ${SCOPE}"; exit 1 ;;
esac

# Gradle 9 validates implicit cross-task dependencies and fails the build when
# generateReferenceTestClasses reads files that another task produces without a
# declared dependsOn. Teku's build.gradle wires that dependency by side effect,
# which gradle 8 accepted. Splitting into two invocations sidesteps the validator
# entirely: expandRefTests fully completes (the producer side), then referenceTest
# runs in a separate gradle session that just sees the on-disk inputs.
set +e
./gradlew --no-daemon --console=plain expandRefTests 2>&1 | tee -a "${LOG_FILE}"
RC=$?
if [[ ${RC} -ne 0 ]]; then
  echo "::error::expandRefTests failed (gradle exit: ${RC})"
  set -e
  echo "::endgroup::"
else
  ./gradlew --no-daemon --console=plain "${GRADLE_TASK}" "${GRADLE_FILTER[@]}" 2>&1 | tee -a "${LOG_FILE}"
  RC=$?
fi
set -e
echo "gradle exit: ${RC}"
echo "::endgroup::"

echo "::group::Harvest JUnit XML"
HARVEST_DIR="${OUT_DIR}/junit"
# gradle writes per-test-class XML files. Concat names with the leaf basename
# so they don't collide across modules.
SUITES_JSON='[]'
shopt -s globstar nullglob
COUNT=0
# Match both singular and plural variants since the task name has flipped
# between branches/forks.
for xml in "${SRC_DIR}"/**/build/test-results/referenceTest*/TEST-*.xml; do
  rel="${xml#${SRC_DIR}/}"
  flat=$(echo "${rel}" | tr '/' '_')
  cp "${xml}" "${HARVEST_DIR}/${flat}"
  COUNT=$((COUNT+1))
done
echo "harvested ${COUNT} JUnit file(s) -> ${HARVEST_DIR}"
ls -lah "${HARVEST_DIR}" | tee -a "${LOG_FILE}"

# Roll the harvested files into one suite entry. We declare category=bls for
# the smoke scope since we filtered to BlsTests; for the full scope we leave
# the suite-level category empty and let junit-to-hive.py classify per-case.
if [[ "${SCOPE}" == "smoke" ]]; then
  SUITE_CATEGORY="bls"
  SUITE_PRESET=""
  SUITE_FORK=""
else
  SUITE_CATEGORY=""
  SUITE_PRESET=""
  SUITE_FORK=""
fi

# `shopt -s nullglob` (set above) makes the loop skip cleanly when no .xml is
# present, instead of iterating with the literal string '*.xml' as we saw on
# the first run.
for f in "${HARVEST_DIR}"/*.xml; do
  base=$(basename "${f}")
  SUITES_JSON=$(jq --arg jf "${base}" \
                  --arg category "${SUITE_CATEGORY}" \
                  --arg preset "${SUITE_PRESET}" \
                  --arg fork "${SUITE_FORK}" \
    '. + [{junit_file:$jf, project:"eth-reference-tests:referenceTest",
           preset:$preset, fork:$fork, category:$category, subcategory:null}]' \
    <<<"${SUITES_JSON}")
done
shopt -u globstar nullglob
echo "::endgroup::"

echo "::group::Write clive-meta.json"
jq -n \
  --arg client teku \
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
