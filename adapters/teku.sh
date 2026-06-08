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

echo "::group::Run gradle reference-tests (scope=${SCOPE})"
# gradle writes JUnit XML to <module>/build/test-results/<task>/TEST-*.xml by
# default. For a smoke we narrow to a single category via --tests so we don't
# pay the cost of the full reference-tests sweep on every smoke.
GRADLE_TASK=":eth-reference-tests:referenceTests"
GRADLE_FILTER=()
case "${SCOPE}" in
  smoke)
    GRADLE_FILTER+=(--tests "*BlsTests*")
    ;;
  full)
    : # no filter — run everything reference-tests defines
    ;;
  *)
    echo "::error::unknown CLIVE_TEST_SCOPE: ${SCOPE}"; exit 1 ;;
esac

set +e
./gradlew --no-daemon --console=plain "${GRADLE_TASK}" "${GRADLE_FILTER[@]}" 2>&1 | tee -a "${LOG_FILE}"
RC=$?
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
for xml in "${SRC_DIR}"/**/build/test-results/referenceTests/TEST-*.xml; do
  rel="${xml#${SRC_DIR}/}"
  flat=$(echo "${rel}" | tr '/' '_')
  cp "${xml}" "${HARVEST_DIR}/${flat}"
  COUNT=$((COUNT+1))
done
shopt -u globstar nullglob
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

for f in "${HARVEST_DIR}"/*.xml; do
  base=$(basename "${f}")
  SUITES_JSON=$(jq --arg jf "${base}" \
                  --arg category "${SUITE_CATEGORY}" \
                  --arg preset "${SUITE_PRESET}" \
                  --arg fork "${SUITE_FORK}" \
    '. + [{junit_file:$jf, project:"eth-reference-tests:referenceTests",
           preset:$preset, fork:$fork, category:$category, subcategory:null}]' \
    <<<"${SUITES_JSON}")
done
echo "::endgroup::"

EFFECTIVE_REF="${CONSENSUS_SPEC_TESTS_REF:-unknown}"

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
