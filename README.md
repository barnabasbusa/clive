# Clive

A reusable GitHub Action that runs a consensus-layer client's spec-test
suite against the canonical
[`ethereum/consensus-spec-tests`](https://github.com/ethereum/consensus-spec-tests)
fixtures and ships the results in
[hive-ui](https://github.com/ethpandaops/hive-ui)-compatible format.

`clive` is to `hive-ui`'s **CL** view what
[`ethpandaops/hive-github-action`](https://github.com/ethpandaops/hive-github-action)
is to its **EL** view: same `listing.jsonl` + `results/*.json` schema, same
S3 bucket, same CloudFront host, different data path.

## v0 scope

- One client: **Lodestar**.
- One toolchain step: `git clone` → `yarn install` → `yarn build` →
  `yarn download-spec-tests` → `yarn test:spec`.
- Output: hive-ui `listing.jsonl` + `results/*.json`, optionally uploaded to
  S3.
- Optional gate: job exits non-zero when any test in the configured
  `fail_on` categories fails.

Multi-client support (`lighthouse`, `teku`, `prysm`, `nimbus`, `grandine`)
lands in subsequent PRs.

## Usage

```yaml
jobs:
  lodestar:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v6
      - uses: ethpandaops/clive@master         # ← swap to barnabasbusa/clive@master while still on the fork
        with:
          cl_client: lodestar
          cl_source_ref: v1.43.0
          # consensus_spec_tests_ref: v1.7.0-alpha.10  # leave empty to use lodestar's pin (v0)
          network: glamsterdam-devnet-5
          fail_on: sanity,operations,epoch_processing,transition,random,finality
          s3_upload: true
          s3_path: spec-glamsterdam-devnet-5
          s3_public_url: https://hive.ethpandaops.io/spec-glamsterdam-devnet-5/
          rclone_config: ${{ secrets.HIVE_RCLONE_CONFIG }}
```

A complete reference workflow lives in
[`.github/workflows/example-clive-devnet.yaml`](.github/workflows/example-clive-devnet.yaml).

## Inputs

| name | default | required | description |
| --- | --- | --- | --- |
| `cl_client` | `lodestar` | yes | Client to test. v0 accepts only `lodestar`. |
| `cl_source_repo` | _(per-client default)_ | no | Override the source repo (e.g. fork or hard-pinned org). |
| `cl_source_ref` | — | yes | Tag, branch or commit to clone and build. |
| `consensus_spec_tests_ref` | _(client's pin)_ | no | `ethereum/consensus-spec-tests` release tag. Empty = use the version pinned in the client source. v0 errors if this disagrees with the pin. |
| `network` | — | yes | Devnet/network label used in result naming and S3 path. |
| `fail_on` | `sanity,operations,epoch_processing,transition,random,finality` | no | Categories that hard-fail the job when at least one of their tests fails. |
| `s3_upload` | `false` | no | Push `results/`, `listing.jsonl` and the run log to S3 via rclone. |
| `s3_bucket` | `hive-results` | no | Bucket name. Default matches hive-ui's CDN already pointed at this bucket. |
| `s3_path` | _(empty)_ | no | Path under the bucket. Defaults to `spec-<network>`. |
| `s3_public_url` | _(derived)_ | no | Public URL prefix the path is exposed at. Defaults to `https://hive.ethpandaops.io/<s3_path>/`. |
| `rclone_config` | — | conditional | rclone config contents. Required when `s3_upload=true`. |
| `rclone_version` | `v1.68.2` | no | Pinned rclone version. |
| `workflow_artifact_upload` | `true` | no | Also upload `out/` as a workflow artifact. |

## Outputs

| name | description |
| --- | --- |
| `ntests` | Total tests executed across all categories/presets/forks. |
| `passes` | Total passing. |
| `fails` | Total failing. |
| `result_url` | Public URL of the manifest (empty when `s3_upload=false`). |

## Output schema

Two artefacts land under the action's `out/` directory and are uploaded
verbatim:

```
out/
├── lodestar.log                 # raw build + test stdout
├── junit/lodestar-spec.xml      # vitest JUnit emission
├── results/
│   ├── 1780910000-<sha>.json   # one TestDetail per (category, preset, fork)
│   └── ...
└── listing-fragment.jsonl       # one TestRun row per file above
```

The shape of `TestRun` and `TestDetail` matches
[`ethpandaops/hive-ui` `src/types/index.ts`](https://github.com/ethpandaops/hive-ui/blob/main/src/types/index.ts);
clive adds three additive optional fields per row (`category`, `preset`,
`fork`) that hive-ui's planned `/cl` summary view uses to render the
client × category × fork matrix.

## Architecture

```
┌────────────────────────────────────────────────────────────────────────────┐
│  devnet repo (e.g. ethpandaops/glamsterdam-devnets)                        │
│  .github/workflows/clive-devnet-5.yaml  ── matrix: cl-client × source-ref  │
└──────────────────────────────────┬─────────────────────────────────────────┘
                                   │ uses: ethpandaops/clive@master
                                   ▼
┌────────────────────────────────────────────────────────────────────────────┐
│  ethpandaops/clive (this repo)                                              │
│    action.yml ── lib/resolve.sh → adapters/lodestar.sh                      │
│                                         └── git clone, yarn build/test     │
│                                         └── emit JUnit XML                  │
│                  lib/junit-to-hive.py ── JUnit → listing.jsonl + results/   │
│                  lib/upload-s3.sh    ── rclone push                          │
│                  lib/gate.sh         ── exit !=0 if a gated category failed │
└──────────────────────────────────┬─────────────────────────────────────────┘
                                   ▼
                          s3://hive-results/spec-<network>/
                                   │ (existing CloudFront)
                                   ▼
                  https://hive.ethpandaops.io/spec-<network>/
                                   │
                          discovery.json entry
                                   ▼
                          ethpandaops/hive-ui  (/cl view)
```

## Roadmap

- v0 (this): Lodestar only, JUnit → hive schema, S3 upload, gate.
- v0.1: Override Lodestar's pinned `consensus_spec_tests_ref` from the
  workflow.
- v0.2: Lighthouse adapter (cargo + `Swatinem/rust-cache`).
- v0.3: Teku, Prysm, Nimbus, Grandine adapters.
- v0.4: Aggregated index workflow, hive-ui `/cl` matrix summary view.

## License

GPL-3.0
