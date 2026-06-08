#!/usr/bin/env python3
"""
Normalise per-suite JUnit XML emitted by a clive adapter into
hive-ui-compatible artefacts:

  ${OUT_DIR}/results/<fileName>.json   - one TestDetail per suite
  ${OUT_DIR}/listing-fragment.jsonl    - one TestRun row per suite

Reads ${OUT_DIR}/clive-meta.json (see lib/clive-meta.schema.json) as the
authoritative description of what each JUnit file contains. Per-testcase
classification (preset/fork/category) inherits the suite-level declaration
in clive-meta; falls back to substring heuristics on classname+name only if
the meta is missing the relevant field for a suite.

The output TestRun and TestDetail shapes match
``ethpandaops/hive-ui`` `src/types/index.ts`.
"""

from __future__ import annotations

import hashlib
import json
import os
import sys
import time
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

FORKS = (
    "phase0", "altair", "bellatrix", "capella", "deneb",
    "electra", "fulu", "gloas", "heze",
)


def _scan(haystack: str, candidates: tuple[str, ...]) -> str:
    haystack = haystack.lower()
    for c in candidates:
        if c in haystack:
            return c
    return ""


def env(name: str, default: str = "") -> str:
    return os.environ.get(name, default) or default


def count_results(test_cases: list[dict]) -> tuple[int, int, int, int]:
    ntests = len(test_cases)
    passes = sum(1 for t in test_cases if t["passed"])
    fails = sum(1 for t in test_cases if t["failed"])
    skipped = sum(1 for t in test_cases if t["skipped"])
    return ntests, passes, fails, skipped


def parse_junit(path: Path) -> list[dict]:
    """Return a flat list of testcase dicts across all testsuites in `path`."""
    try:
        tree = ElementTree.parse(path)
    except ElementTree.ParseError as e:
        print(f"::warning::failed to parse {path}: {e}", file=sys.stderr)
        return []

    cases = []
    for tc in tree.iter("testcase"):
        name = tc.get("name", "")
        classname = tc.get("classname", "")
        failure_el = tc.find("failure") if tc.find("failure") is not None else tc.find("error")
        failed = failure_el is not None
        skipped = tc.find("skipped") is not None
        failure_message = ""
        if failed:
            failure_message = (failure_el.text or "").strip() or (failure_el.get("message", "") or "")
        # `passed` is whether the case is *not* a failure. Skipped cases are not
        # failures — they're tests that intentionally didn't execute (typically
        # because the client doesn't yet support the fork/preset for that
        # fixture). Treating skips as failures, as hive-ui's `summaryResult.pass`
        # default does, would surface every skipped fixture as red even when
        # the listing row already correctly reports 0 fails and N skipped.
        cases.append({
            "name": f"{classname}::{name}" if classname else name,
            "classname": classname,
            "passed": not failed,
            "skipped": skipped,
            "failed": failed,
            "time": float(tc.get("time") or 0.0),
            "failure_message": failure_message,
        })
    return cases


def main() -> int:
    out_dir = Path(env("OUT_DIR")).resolve()
    if not out_dir.exists():
        print(f"::error::OUT_DIR does not exist: {out_dir}", file=sys.stderr)
        return 1

    meta_path = out_dir / "clive-meta.json"
    if not meta_path.exists():
        print(f"::error::clive-meta.json missing at {meta_path}; adapters must write it.", file=sys.stderr)
        return 1
    meta = json.loads(meta_path.read_text())

    junit_dir = out_dir / "junit"
    results_dir = out_dir / "results"
    results_dir.mkdir(parents=True, exist_ok=True)
    listing_path = out_dir / "listing-fragment.jsonl"

    cl_client = meta["client"]
    source_ref = meta["source_ref"]
    client_label = f"{cl_client}_{source_ref}"
    client_version = meta["client_version"]
    cst_ref = meta["consensus_spec_tests_ref"]
    network = meta["network"]

    suites = meta.get("suites") or []
    if not suites:
        print(f"::warning::clive-meta.json declares zero suites; nothing to normalise", file=sys.stderr)

    total_ntests = total_passes = total_fails = 0
    now_iso = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    timestamp_prefix = int(time.time())

    total_rows = 0

    def emit_row(fork: str, preset: str, category: str, subcategory: str, cases: list[dict]):
        """Emit one TestRun row + one TestDetail for a group of cases."""
        nonlocal total_ntests, total_passes, total_fails, total_rows
        ntests, passes, fails, skipped_count = count_results(cases)
        total_ntests += ntests
        total_passes += passes
        total_fails += fails
        total_rows += 1
        slug = f"{cl_client}-{category}-{preset}-{fork}-{subcategory}".strip("-")
        digest = hashlib.sha1(slug.encode()).hexdigest()[:12]
        file_name = f"{timestamp_prefix}-{digest}.json"

        test_cases = {}
        for i, tc in enumerate(cases, start=1):
            case_fork = fork or _scan(f"{tc['classname']}.{tc['name']}", FORKS)
            case_preset = preset or _scan(f"{tc['classname']}.{tc['name']}", PRESETS)
            case_category = category or _scan(f"{tc['classname']}.{tc['name']}", CATEGORIES)
            test_cases[str(i)] = {
                "name": tc["name"],
                "description": "",
                "start": now_iso,
                "end": now_iso,
                "summaryResult": {
                    "pass": tc["passed"],
                    "skipped": tc["skipped"],
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
                "failureMessage": tc["failure_message"] if tc["failed"] else "",
                "skipped": tc["skipped"],
                "durationSeconds": tc["time"],
                "fork": case_fork,
                "preset": case_preset,
                "category": case_category,
            }

        detail = {
            "id": 0,
            "name": _suite_label(fork, category, preset, subcategory),
            "description": (
                f"Consensus spec tests for {category or '?'}"
                f"{' / ' + subcategory if subcategory else ''}"
                f" ({preset or '–'}, {fork or '–'})"
                f" on {cl_client} {client_version}, fixtures {cst_ref}."
            ),
            "clientVersions": {client_label: client_version},
            "testCases": test_cases,
            "simLog": f"{cl_client}.log",
            "testDetailsLog": "",
            "runMetadata": {
                "clive": {
                    "client": cl_client,
                    "source_ref": source_ref,
                    "source_sha": meta.get("source_sha", ""),
                    "client_version": client_version,
                    "consensus_spec_tests_ref": cst_ref,
                    "network": network,
                    "category": category,
                    "subcategory": subcategory,
                    "preset": preset,
                    "fork": fork,
                },
            },
        }
        (results_dir / file_name).write_text(json.dumps(detail))

        row = {
            "name": _suite_label(fork, category, preset, subcategory),
            "ntests": ntests,
            "passes": passes,
            "fails": fails,
            "timeout": False,
            "clients": [client_label],
            "versions": {client_label: client_version},
            "start": now_iso,
            "fileName": file_name,
            "size": (results_dir / file_name).stat().st_size,
            "simLog": f"{cl_client}.log",
            "category": category,
            "subcategory": subcategory,
            "preset": preset,
            "fork": fork,
            "skipped": skipped_count,
            "consensus_spec_tests_ref": cst_ref,
            "network": network,
        }
        listing_fp.write(json.dumps(row) + "\n")

    with listing_path.open("w") as listing_fp:
        for suite in suites:
            junit_file = suite["junit_file"]
            xml_path = junit_dir / junit_file
            if not xml_path.exists():
                print(f"::warning::clive-meta references missing JUnit file: {xml_path}", file=sys.stderr)
                continue

            cases = parse_junit(xml_path)
            if not cases:
                continue

            suite_preset = suite.get("preset", "")
            suite_fork = suite.get("fork", "")
            suite_category = suite.get("category", "")
            suite_subcategory = suite.get("subcategory") or ""

            # Auto-split mode: when the adapter doesn't declare a category at
            # the suite level (Nimbus's consensus_spec_tests_minimal binary,
            # Prysm's //testing/spectest/general/..., etc.), partition the
            # testcases by their per-case (category, preset, fork) inferred
            # from the test path and emit one row per group. This turns a
            # single 7227-case Nimbus run into ~10 rows like
            # `spec/capella/fork_choice/minimal`, `spec/altair/sanity/minimal`
            # rather than one opaque `spec/*/sanity/minimal` row.
            if not suite_category:
                groups: dict[tuple[str, str, str], list[dict]] = {}
                for tc in cases:
                    haystack = f"{tc['classname']}.{tc['name']}"
                    case_category = _scan(haystack, CATEGORIES) or ""
                    case_preset = suite_preset or _scan(haystack, PRESETS) or ""
                    case_fork = suite_fork or _scan(haystack, FORKS) or ""
                    key = (case_fork, case_preset, case_category)
                    groups.setdefault(key, []).append(tc)
                for (fork, preset, category), group_cases in sorted(groups.items()):
                    emit_row(fork, preset, category, suite_subcategory, group_cases)
            else:
                emit_row(suite_fork, suite_preset, suite_category, suite_subcategory, cases)

    gh_output = os.environ.get("GITHUB_OUTPUT")
    if gh_output:
        with open(gh_output, "a") as fp:
            fp.write(f"ntests={total_ntests}\n")
            fp.write(f"passes={total_passes}\n")
            fp.write(f"fails={total_fails}\n")

    print(f"clive: wrote {total_rows} TestRun row(s) from {len(suites)} suite(s) "
          f"({total_passes}/{total_ntests} passing, {total_fails} fail) "
          f"to {listing_path}")
    return 0


def _suite_label(fork: str, category: str, preset: str, subcategory: str) -> str:
    parts = ["spec", fork or "any", category or "uncategorised"]
    if subcategory:
        parts.append(subcategory)
    if preset:
        parts.append(preset)
    return "/".join(parts)


if __name__ == "__main__":
    sys.exit(main())
