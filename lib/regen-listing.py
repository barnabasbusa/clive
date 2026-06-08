#!/usr/bin/env python3
"""
Regenerate listing.jsonl from the full set of results/*.json TestDetail files.

Modelled on the pattern hive-github-action uses for its own listing.jsonl —
the source of truth is the results directory, not a long-lived append-only
fragment. Each pass writes the full listing from scratch so old rows for the
same `(client, source_ref, category, preset, fork)` are superseded cleanly.

Inputs:
  --results-dir PATH    directory containing results/*.json TestDetail files
  --output PATH         where to write the regenerated listing.jsonl
  --limit N             cap on rows (default 2000, matching hive's default)
"""

from __future__ import annotations

import argparse
import json
import sys
from collections import OrderedDict
from pathlib import Path


def count_test_cases(test_cases: dict) -> tuple[int, int, int, int]:
    """Return (ntests, passes, fails, skipped) for a `testCases` dict."""
    ntests = passes = fails = skipped = 0
    for tc in test_cases.values():
        ntests += 1
        if tc.get("skipped"):
            skipped += 1
            continue
        if tc.get("summaryResult", {}).get("pass"):
            passes += 1
        else:
            fails += 1
    return ntests, passes, fails, skipped


def row_from_detail(file_name: str, detail: dict, size: int) -> dict | None:
    meta = (detail.get("runMetadata") or {}).get("clive") or {}
    cl_client = meta.get("client") or ""
    source_ref = meta.get("source_ref") or ""
    client_label = f"{cl_client}_{source_ref}" if cl_client and source_ref else cl_client or "unknown"
    client_version = (detail.get("clientVersions") or {}).get(client_label, source_ref)

    ntests, passes, fails, skipped = count_test_cases(detail.get("testCases") or {})

    # `start` is best-effort — pyspec emits per-case start/end, not per-run.
    test_cases = detail.get("testCases") or {}
    if test_cases:
        first_case = next(iter(test_cases.values()))
        start = first_case.get("start") or ""
    else:
        start = ""

    fork = meta.get("fork") or ""
    category = meta.get("category") or ""

    return {
        "name": f"spec/{fork}/{category}" if fork and category else detail.get("name", file_name),
        "ntests": ntests,
        "passes": passes,
        "fails": fails,
        "timeout": False,
        "clients": [client_label],
        "versions": {client_label: client_version},
        "start": start,
        "fileName": file_name,
        "size": size,
        "simLog": detail.get("simLog", ""),
        "category": category,
        "preset": meta.get("preset", ""),
        "fork": fork,
        "skipped": skipped,
        "consensus_spec_tests_ref": meta.get("consensus_spec_tests_ref", ""),
        "network": meta.get("network", ""),
    }


def main(argv: list[str]) -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--results-dir", required=True, type=Path)
    p.add_argument("--output", required=True, type=Path)
    p.add_argument("--limit", type=int, default=2000)
    args = p.parse_args(argv)

    rows: list[tuple[str, dict]] = []  # (sort-key, row)

    if not args.results_dir.exists():
        print(f"::warning::results dir missing: {args.results_dir}", file=sys.stderr)
        args.output.write_text("")
        return 0

    for path in sorted(args.results_dir.glob("*.json")):
        try:
            detail = json.loads(path.read_text())
        except json.JSONDecodeError as e:
            print(f"::warning::skipping {path}: {e}", file=sys.stderr)
            continue
        row = row_from_detail(path.name, detail, path.stat().st_size)
        if row is None:
            continue
        # Sort by start desc, with filename as tiebreaker (timestamp-prefixed).
        sort_key = (row.get("start") or "", path.name)
        rows.append((sort_key, row))

    # Newest first; cap at limit.
    rows.sort(key=lambda r: r[0], reverse=True)
    rows = rows[: args.limit]

    # Within the cap, dedupe by (client, source_ref, category, preset, fork) so
    # the listing reflects the latest run per matrix cell only.
    deduped: "OrderedDict[tuple, dict]" = OrderedDict()
    for _, row in rows:
        key = (
            tuple(row.get("clients") or []),
            row.get("category", ""),
            row.get("preset", ""),
            row.get("fork", ""),
        )
        if key not in deduped:
            deduped[key] = row

    with args.output.open("w") as fp:
        for row in deduped.values():
            fp.write(json.dumps(row) + "\n")

    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
