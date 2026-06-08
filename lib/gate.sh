#!/usr/bin/env bash
set -euo pipefail

# Exits non-zero if any test in a fail_on category failed. Reads the fragment
# emitted by junit-to-hive.py.
#
# Inputs (env):
#   OUT_DIR  - dir containing listing-fragment.jsonl
#   FAIL_ON  - comma-separated list of categories that hard-fail the job

FRAGMENT="${OUT_DIR}/listing-fragment.jsonl"
if [[ ! -f "${FRAGMENT}" ]]; then
  echo "::error::no listing-fragment.jsonl at ${FRAGMENT}; junit-to-hive.py did not run?"
  exit 1
fi

IFS=',' read -ra GATE_CATS <<< "${FAIL_ON}"

GATE_FAIL=0
echo "Gate categories: ${GATE_CATS[*]}"
echo

while IFS= read -r line; do
  [[ -z "${line}" ]] && continue
  category=$(echo "${line}" | python3 -c "import sys, json; print(json.loads(sys.stdin.read()).get('category', ''))")
  fails=$(echo "${line}" | python3 -c "import sys, json; print(json.loads(sys.stdin.read()).get('fails', 0))")
  fork=$(echo "${line}" | python3 -c "import sys, json; print(json.loads(sys.stdin.read()).get('fork', ''))")
  preset=$(echo "${line}" | python3 -c "import sys, json; print(json.loads(sys.stdin.read()).get('preset', ''))")

  status="OK"
  for gc in "${GATE_CATS[@]}"; do
    if [[ "${category}" == "${gc}" && "${fails}" -gt 0 ]]; then
      status="FAIL"
      GATE_FAIL=1
      break
    fi
  done
  printf "  %-6s  %-20s  %-8s  %-10s  fails=%s\n" "${status}" "${category}" "${preset}" "${fork}" "${fails}"
done < "${FRAGMENT}"

echo
if [[ "${GATE_FAIL}" -ne 0 ]]; then
  echo "::error::clive gate FAILED — at least one gated category has failing tests."
  exit 1
fi
echo "clive gate PASSED."
