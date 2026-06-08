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
import html
import json
import os
import re
import sys
import time
import urllib.parse
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
        # Locate the file path that holds this test, in priority order:
        #   1. explicit `<testcase file="...">` attribute (rare)
        #   2. `classname` when it looks like a source-file path — vitest
        #      writes `classname="test/spec/bls/index.test.ts"`, which is
        #      exactly the repo-relative path we need.
        # Other runners (nextest, gradle, bazel, nim) leave both blank and
        # the description-builder falls back to a GitHub code-search URL.
        file_attr = tc.get("file", "")
        if not file_attr and _looks_like_source_path(classname):
            file_attr = classname
        cases.append({
            "name": f"{classname}::{name}" if classname else name,
            "classname": classname,
            "file": file_attr,
            "line": tc.get("line", ""),
            "passed": not failed,
            "skipped": skipped,
            "failed": failed,
            "time": float(tc.get("time") or 0.0),
            "failure_message": failure_message,
        })
    return cases


_SOURCE_PATH_RE = re.compile(
    r"^[A-Za-z0-9_./-]+\.(?:tsx?|jsx?|mjs|cjs|rs|go|py|nim|java|kt|scala|sol|cs)$"
)


def _looks_like_source_path(s: str) -> bool:
    """Heuristic: does this look like a repo-relative source file path?"""
    return bool(s) and "/" in s and bool(_SOURCE_PATH_RE.match(s))


def _strip_src_prefix(file_path: str, cl_client: str) -> str:
    """Make an absolute `file=` JUnit attribute relative to the cloned repo.

    Adapters all clone into `${ACTION_PATH}/.cache/<cl_client>/...`, so the
    distinctive marker is `/.cache/<cl_client>/`. If we can't find it (e.g.
    the runner already wrote a relative path), pass through unchanged.
    """
    if not file_path:
        return ""
    marker = f"/.cache/{cl_client}/"
    idx = file_path.find(marker)
    if idx >= 0:
        return file_path[idx + len(marker):]
    return file_path.lstrip("/")


def _build_description(
    *,
    tc: dict,
    cl_client: str,
    source_repo: str,
    source_sha: str,
    source_ref: str,
    source_subdir: str,
    cst_ref: str,
    preset: str,
    fork: str,
    category: str,
) -> str:
    """Render the per-testcase Description shown in hive-ui's TestDetail.

    hive-ui renders this through `sanitizeAndRenderHTML` with `pre-wrap`, so
    HTML anchors render as clickable links and newlines are preserved.
    """
    lines: list[str] = []

    # First line: the raw test name. Useful both for grep-by-eye and as a
    # fallback when neither link target resolves.
    lines.append(f"<strong>Test:</strong> {html.escape(tc['name'])}")

    # ── Link to the test case in the CL client repo ─────────────────────
    if source_repo:
        # Prefer the human-readable ref (branch/tag) for navigation; fall
        # back to the resolved SHA when the user dispatched empty (=latest
        # release) so we still emit a real URL.
        repo_ref = source_ref or source_sha or "master"
        rel_file = _strip_src_prefix(tc.get("file", ""), cl_client)
        # Vitest et al. report paths relative to the runner CWD (the
        # package dir), not the repo root. The adapter declares its CWD
        # via the suite's `source_subdir` so we can rebuild repo paths.
        if rel_file and source_subdir:
            rel_file = f"{source_subdir.strip('/')}/{rel_file}"
        if rel_file:
            line_suffix = f"#L{tc['line']}" if tc.get("line") else ""
            label = html.escape(f"{rel_file}{(':' + tc['line']) if tc.get('line') else ''}")
            url = (
                f"https://github.com/{source_repo}/blob/"
                f"{urllib.parse.quote(repo_ref, safe='/')}/{rel_file}{line_suffix}"
            )
            lines.append(
                f"<strong>Client test:</strong> "
                f'<a href="{html.escape(url, quote=True)}" target="_blank" rel="noopener noreferrer">{label}</a>'
            )
        else:
            # No `file=` attribute → fall back to GitHub code search for the
            # test name within the client repo. Less precise but always works.
            query = urllib.parse.quote_plus(tc["name"])
            url = f"https://github.com/{source_repo}/search?q={query}&type=code"
            lines.append(
                f"<strong>Client test:</strong> "
                f'<a href="{html.escape(url, quote=True)}" target="_blank" rel="noopener noreferrer">'
                f"search {html.escape(source_repo)}</a>"
            )

    # ── Link to the spec fixture in ethereum/consensus-spec-tests ───────
    if cst_ref:
        # Build the deepest tree path we can justify from suite metadata.
        path_parts = [p for p in ("tests", preset, fork, category) if p]
        path = "/".join(path_parts)
        url = (
            "https://github.com/ethereum/consensus-spec-tests/tree/"
            f"{urllib.parse.quote(cst_ref, safe='/')}"
            + (f"/{path}" if path != "tests" else "")
        )
        label_path = "/" + path if path else ""
        lines.append(
            f"<strong>Spec fixture:</strong> "
            f'<a href="{html.escape(url, quote=True)}" target="_blank" rel="noopener noreferrer">'
            f"consensus-spec-tests@{html.escape(cst_ref)}{html.escape(label_path)}</a>"
        )

    # ── Failure block (only on actual failures, not skips) ──────────────
    if tc["failed"] and tc.get("failure_message"):
        msg = html.escape(tc["failure_message"])
        lines.append(f"<strong>Failure:</strong>\n<pre>{msg}</pre>")

    return "\n".join(lines)


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
    source_repo = meta.get("source_repo", "")
    source_sha = meta.get("source_sha", "")
    # The hive-ui filter and card titles render `clients[]` verbatim; using
    # just the client name keeps the dropdown labels short ("prysm") instead
    # of "prysm_glamsterdam-devnet-5". The ref/network info is preserved on
    # the TestRun row itself (`versions`, `network`, `source_ref`).
    client_label = cl_client
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

    def emit_row(fork: str, preset: str, category: str, subcategory: str, cases: list[dict], source_subdir: str = ""):
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
                "description": _build_description(
                    tc=tc,
                    cl_client=cl_client,
                    source_repo=source_repo,
                    source_sha=source_sha,
                    source_ref=source_ref,
                    source_subdir=source_subdir,
                    cst_ref=cst_ref,
                    preset=case_preset,
                    fork=case_fork,
                    category=case_category,
                ),
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
                # Auto-split: group by (top-label, fork) so we end up with at
                # most 4 × (#forks + "any") rows per suite. Multiple
                # state-transition categories under the same preset/fork
                # collapse into one row labelled e.g. `minimal/altair`.
                groups: dict[tuple[str, str, str, str], list[dict]] = {}
                for tc in cases:
                    haystack = f"{tc['classname']}.{tc['name']}"
                    case_category = _scan(haystack, CATEGORIES) or ""
                    case_preset = suite_preset or _scan(haystack, PRESETS) or ""
                    case_fork = suite_fork or _scan(haystack, FORKS) or ""
                    # Key by the rendered top-label rather than the raw
                    # category so cases within the same bucket merge cleanly.
                    top = _top_label(case_category, case_preset)
                    key = (top, case_fork, case_preset, case_category)
                    groups.setdefault(key, []).append(tc)
                # Merge groups that share (top, fork) — multiple raw categories
                # within e.g. (minimal, altair) collapse into one row.
                merged: dict[tuple[str, str], dict] = {}
                for (top, fork, preset, category), group_cases in groups.items():
                    bucket_key = (top, fork)
                    bucket = merged.setdefault(bucket_key, {
                        "cases": [],
                        "preset": preset,
                        "category": category,
                    })
                    bucket["cases"].extend(group_cases)
                    # If multiple categories merge into the bucket, the row's
                    # per-case fields carry the truth; the suite-level
                    # `category` is informational only.
                suite_source_subdir = suite.get("source_subdir") or ""
                for (top, fork), bucket in sorted(merged.items()):
                    emit_row(fork, bucket["preset"], bucket["category"],
                             suite_subcategory, bucket["cases"],
                             source_subdir=suite_source_subdir)
            else:
                emit_row(suite_fork, suite_preset, suite_category,
                         suite_subcategory, cases,
                         source_subdir=suite.get("source_subdir") or "")

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


def _top_label(category: str, preset: str) -> str:
    """Collapse a (category, preset) pair to one of the four top-level buckets
    the dashboard renders: mainnet, minimal, forkchoice, other.

    Rationale: granular per-(fork, preset, category) rows produce 200+ entries
    which is more noise than signal. The collapse keeps the gate categories
    (state-transition at minimal/mainnet + fork-choice) immediately visible
    and lumps everything preset-irrelevant (bls, ssz_static, ssz_generic, kzg,
    light_client) into a single `other` bucket.
    """
    if category == "fork_choice":
        return "forkchoice"
    if preset == "mainnet":
        return "mainnet"
    if preset == "minimal":
        return "minimal"
    return "other"


def _suite_label(fork: str, category: str, preset: str, subcategory: str) -> str:
    # `<top>/<fork>` where top is one of mainnet/minimal/forkchoice/other and
    # fork is phase0..heze (or `any` for preset-irrelevant rows like BLS).
    # We intentionally drop preset from the label — it's already encoded in
    # the top-level bucket name.
    top = _top_label(category, preset)
    parts = [top, fork or "any"]
    if subcategory:
        parts.append(subcategory)
    return "/".join(parts)


if __name__ == "__main__":
    sys.exit(main())
