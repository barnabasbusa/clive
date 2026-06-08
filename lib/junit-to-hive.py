#!/usr/bin/env python3
"""
Normalise JUnit XML emitted by a CL client's spec-test runner into
hive-ui-compatible artefacts:

  ${OUT_DIR}/results/<fileName>.json   - one TestDetail per (category, preset, fork)
  ${OUT_DIR}/listing-fragment.jsonl    - one TestRun row per file above

The schema matches what hive-ui reads via
``fetchTestRuns`` / ``fetchTestDetail`` in ``src/services/api.ts``.

Inputs (env):
  OUT_DIR                  - same dir adapters wrote junit/ + lodestar.log to
  CL_CLIENT                - e.g. ``lodestar``
  CL_SOURCE_REF            - source ref the client was built at
  CLIENT_VERSION           - resolved version string (incl. short SHA)
  CONSENSUS_SPEC_TESTS_REF - fixtures version the runner tested against
  NETWORK                  - devnet label

Outputs ($GITHUB_OUTPUT):
  ntests, passes, fails - aggregated totals across all files
"""

from __future__ import annotations

import hashlib
import json
import os
import re
import sys
import time
from collections import defaultdict
from pathlib import Path
from xml.etree import ElementTree

CATEGORIES = (
    "sanity",
    "operations",
    "epoch_processing",
    "transition",
    "random",
    "finality",
    "fork_choice",
    "rewards",
    "shuffling",
    "ssz_generic",
    "ssz_static",
    "bls",
    "kzg",
    "light_client",
    "merkle_proof",
    "genesis",
)

PRESETS = ("minimal", "mainnet", "general")
# Loose fork name list; matched best-effort against test names.
FORKS = (
    "phase0", "altair", "bellatrix", "capella", "deneb",
    "electra", "fulu", "gloas", "heze",
)


def env(name: str, default: str = "") -> str:
    return os.environ.get(name, default) or default


def classify(test_name: str, classname: str) -> tuple[str, str, str]:
    """Best-effort category/preset/fork extraction from JUnit identifiers.

    JUnit emitters vary across vitest/mocha/cargo-test; the most reliable
    signal we have is substring presence in the combined classname+name.
    """
    haystack = f"{classname}.{test_name}".lower()

    category = "unknown"
    for c in CATEGORIES:
        if c in haystack:
            category = c
            break

    preset = "unknown"
    for p in PRESETS:
        if p in haystack:
            preset = p
            break

    fork = "unknown"
    for f in FORKS:
        if f in haystack:
            fork = f
            break

    return category, preset, fork


def main() -> int:
    out_dir = Path(env("OUT_DIR")).resolve()
    if not out_dir.exists():
        print(f"::error::OUT_DIR does not exist: {out_dir}", file=sys.stderr)
        return 1

    junit_dir = out_dir / "junit"
    results_dir = out_dir / "results"
    results_dir.mkdir(parents=True, exist_ok=True)
    listing_path = out_dir / "listing-fragment.jsonl"

    cl_client = env("CL_CLIENT", "lodestar")
    cl_source_ref = env("CL_SOURCE_REF", "")
    client_version = env("CLIENT_VERSION", cl_source_ref)
    cst_ref = env("CONSENSUS_SPEC_TESTS_REF", "")
    network = env("NETWORK", "unknown")

    client_label = f"{cl_client}_{cl_source_ref}"

    # Group test cases by (category, preset, fork)
    buckets: dict[tuple[str, str, str], list[dict]] = defaultdict(list)

    xml_files = sorted(junit_dir.glob("*.xml")) if junit_dir.exists() else []
    if not xml_files:
        print(f"::warning::no JUnit XML files found under {junit_dir}", file=sys.stderr)

    for xml_path in xml_files:
        try:
            tree = ElementTree.parse(xml_path)
        except ElementTree.ParseError as e:
            print(f"::warning::failed to parse {xml_path}: {e}", file=sys.stderr)
            continue

        for tc in tree.iter("testcase"):
            name = tc.get("name", "")
            classname = tc.get("classname", "")
            failure = tc.find("failure") is not None or tc.find("error") is not None
            skipped = tc.find("skipped") is not None
            category, preset, fork = classify(name, classname)

            buckets[(category, preset, fork)].append({
                "name": f"{classname}::{name}" if classname else name,
                "classname": classname,
                "passed": (not failure) and (not skipped),
                "skipped": skipped,
                "failed": failure,
                "time": float(tc.get("time") or 0.0),
                "failure_message": (
                    (tc.find("failure").text or "") if tc.find("failure") is not None
                    else (tc.find("error").text or "") if tc.find("error") is not None
                    else ""
                ),
            })

    total_ntests = total_passes = total_fails = 0
    now_iso = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    timestamp_prefix = int(time.time())

    with listing_path.open("w") as listing_fp:
        for (category, preset, fork), tests in sorted(buckets.items()):
            ntests = len(tests)
            fails = sum(1 for t in tests if t["failed"])
            passes = sum(1 for t in tests if t["passed"])
            skipped = sum(1 for t in tests if t["skipped"])
            total_ntests += ntests
            total_passes += passes
            total_fails += fails

            slug = f"{cl_client}-{category}-{preset}-{fork}"
            digest = hashlib.sha1(slug.encode()).hexdigest()[:12]
            file_name = f"{timestamp_prefix}-{digest}.json"

            test_cases = {}
            for i, tc in enumerate(tests, start=1):
                test_cases[str(i)] = {
                    "name": tc["name"],
                    "description": "",
                    "start": now_iso,
                    "end": now_iso,
                    "summaryResult": {
                        "pass": tc["passed"],
                        "log": {"begin": 0, "end": 0},
                    },
                    "clientInfo": {
                        client_label: {
                            "id": client_label,
                            "ip": "",
                            "name": client_label,
                            "instantiatedAt": now_iso,
                            "logFile": "",
                        },
                    },
                    # Extra context for hive-ui's drill-in / CL matrix view.
                    "failureMessage": tc.get("failure_message", "") if tc["failed"] else "",
                    "skipped": tc["skipped"],
                    "durationSeconds": tc["time"],
                }

            detail = {
                "id": 0,
                "name": f"spec/{fork}/{category}/{preset}",
                "description": (
                    f"Consensus spec tests for {category} ({preset}, {fork}) "
                    f"on {cl_client} {client_version}, fixtures {cst_ref}."
                ),
                "clientVersions": {client_label: client_version},
                "testCases": test_cases,
                "simLog": "lodestar.log",
                "testDetailsLog": "",
                "runMetadata": {
                    "clive": {
                        "client": cl_client,
                        "source_ref": cl_source_ref,
                        "client_version": client_version,
                        "consensus_spec_tests_ref": cst_ref,
                        "network": network,
                        "category": category,
                        "preset": preset,
                        "fork": fork,
                    },
                },
            }

            (results_dir / file_name).write_text(json.dumps(detail))

            row = {
                "name": f"spec/{fork}/{category}",
                "ntests": ntests,
                "passes": passes,
                "fails": fails,
                "timeout": False,
                "clients": [client_label],
                "versions": {client_label: client_version},
                "start": now_iso,
                "fileName": file_name,
                "size": (results_dir / file_name).stat().st_size,
                "simLog": "lodestar.log",
                # Additive optional fields for hive-ui's CL view.
                "category": category,
                "preset": preset,
                "fork": fork,
                "skipped": skipped,
                "consensus_spec_tests_ref": cst_ref,
                "network": network,
            }
            listing_fp.write(json.dumps(row) + "\n")

    gh_output = os.environ.get("GITHUB_OUTPUT")
    if gh_output:
        with open(gh_output, "a") as fp:
            fp.write(f"ntests={total_ntests}\n")
            fp.write(f"passes={total_passes}\n")
            fp.write(f"fails={total_fails}\n")

    print(f"clive: wrote {len(buckets)} TestRun row(s) "
          f"({total_passes}/{total_ntests} passing, {total_fails} fail) "
          f"to {listing_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
