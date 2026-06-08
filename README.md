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

## Supported clients

| Client     | Source repo                  | Toolchain        | Test target                                    |
|------------|------------------------------|------------------|------------------------------------------------|
| lodestar   | `ChainSafe/lodestar`         | Node 24 + pnpm   | `pnpm exec vitest run` per scope               |
| lighthouse | `sigp/lighthouse`            | Rust + nextest   | `cargo nextest run --profile clive -p ef_tests`|
| nimbus     | `status-im/nimbus-eth2`      | nim (bootstrapped) | `consensus_spec_tests_<preset> --xml:...`    |
| teku       | `Consensys/teku`             | JDK 25 + Gradle  | `:eth-reference-tests:referenceTest`           |
| prysm      | `prysmaticlabs/prysm`        | Go + Bazel       | `bazel test //testing/spectest/...`            |
| grandine   | `grandinetech/grandine`      | Rust + nextest   | `cargo nextest run` filtered by package        |

## Usage

```yaml
jobs:
  lodestar:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v6
      - uses: ethpandaops/clive@master          # or barnabasbusa/clive@master on the fork
        with:
          cl_client: lodestar
          cl_source_ref: glamsterdam-devnet-5   # tag, branch, sha; empty = latest release
          consensus_spec_tests_ref: v1.7.0-alpha.10  # empty = use client's pin
          network: glamsterdam-devnet-5
          scope: bls                            # adapter-specific; empty = adapter default
          fail_on: sanity,operations,epoch_processing,transition,random,finality
          s3_upload: 'true'
          s3_path: spec-glamsterdam-devnet-5
          rclone_config: ${{ secrets.HIVE_RCLONE_CONFIG }}
```

A complete reference workflow lives in
[`.github/workflows/example-clive-devnet.yaml`](.github/workflows/example-clive-devnet.yaml).
The internal smoke workflow at
[`.github/workflows/smoke.yml`](.github/workflows/smoke.yml) is the canonical
example of calling `clive` against any single client.

## Inputs

Required:

| name            | description                                |
|-----------------|--------------------------------------------|
| `cl_client`     | lodestar/lighthouse/nimbus/teku/prysm/grandine |
| `network`       | devnet label used in result naming + S3 path   |

Source:

| name                       | default                  | description                       |
|----------------------------|--------------------------|-----------------------------------|
| `cl_source_repo`           | per-client default       | override the source GitHub repo   |
| `cl_source_ref`            | latest non-pre release   | tag, branch, or commit SHA        |
| `consensus_spec_tests_ref` | client's own pin         | force a specific fixtures version |
| `scope`                    | adapter default          | which suites to run (see below)   |

Gate:

| name      | default                                                       | description |
|-----------|---------------------------------------------------------------|-------------|
| `fail_on` | `sanity,operations,epoch_processing,transition,random,finality` | categories whose failures hard-fail the job |

S3 upload (matches `ethpandaops/hive-github-action`):

| name                       | default        | description                                |
|----------------------------|----------------|--------------------------------------------|
| `s3_upload`                | `false`        | push results + listing.jsonl + log to S3   |
| `s3_bucket`                | `hive-results` | reuses hive-ui's existing CDN-fronted bucket |
| `s3_path`                  | `spec-<network>` | path under the bucket                    |
| `s3_public_url`            | derived        | public URL prefix used in result manifests |
| `rclone_config`            | —              | required when `s3_upload=true`             |
| `rclone_version`           | `v1.68.2`      | pinned rclone version                      |
| `workflow_artifact_upload` | `true`         | also upload `out/` as a workflow artifact  |

### Per-adapter `scope` values

| Client     | Accepted scopes                                                | Default  |
|------------|----------------------------------------------------------------|----------|
| lodestar   | `bls`, `general`, `minimal`, `mainnet`, `full`                 | `full`   |
| lighthouse | `smoke` (bls only), `full`                                     | `full`   |
| nimbus     | `minimal`, `mainnet`, `full`                                   | `minimal`|
| teku       | `smoke` (BlsTests only), `full`                                | `smoke`  |
| prysm      | `smoke` (general/...), `full` (all spectest packages)          | `smoke`  |
| grandine   | `smoke` (fork_choice_control only), `full` (workspace)         | `smoke`  |

## Outputs

| name         | description                                         |
|--------------|-----------------------------------------------------|
| `ntests`     | total tests executed across all suites              |
| `passes`     | total passing                                       |
| `fails`      | total failing                                       |
| `result_url` | public URL of the manifest (empty without S3 upload)|

## Output schema

Every adapter writes the same shape into `${{ runner.temp }}/clive-out/`:

```
clive-out/
├── <client>.log                  # raw build + test stdout
├── junit/
│   ├── <suite>.xml               # one or more JUnit XML files
│   └── ...
├── clive-meta.json               # adapter-declared classification (schema: lib/clive-meta.schema.json)
├── results/
│   └── <ts>-<sha>.json           # one TestDetail per suite (hive-ui-compatible)
└── listing-fragment.jsonl        # one TestRun row per suite (hive-ui-compatible)
```

`TestRun` and `TestDetail` match
[`ethpandaops/hive-ui` `src/types/index.ts`](https://github.com/ethpandaops/hive-ui/blob/main/src/types/index.ts).
Clive adds optional fields per row (`category`, `preset`, `fork`,
`subcategory`, `consensus_spec_tests_ref`, `network`) for the planned
`/cl` matrix view.

### `clive-meta.json`

Authoritative declaration of what the adapter just ran. Read by
`lib/junit-to-hive.py` so per-suite preset/fork/category come from the
adapter (not heuristic name parsing). See
[`lib/clive-meta.schema.json`](lib/clive-meta.schema.json) for the
contract.

## Ref resolution

`cl_source_ref` accepts:

- An explicit **tag** (e.g. `v1.43.0`).
- An explicit **branch** (e.g. `glamsterdam-devnet-5`).
- An explicit **commit SHA** (any length git accepts).
- **Empty** → latest non-prerelease GitHub release of `cl_source_repo`
  via the GH API. The action's `gh` invocation uses `${{ github.token }}`,
  so no extra secret is required.

`consensus_spec_tests_ref` accepts the same forms (any tag of
`ethereum/consensus-spec-tests`). Empty falls back to whatever the
client source tree pins. Setting a different value:

- **Lodestar** — patches `spec-tests-version.json` in-place
- **Teku** — patches `def refTestVersion` in `build.gradle` in-place
- **Lighthouse** — forwards via `CONSENSUS_SPECS_TEST_VERSION` env
- **Grandine** — forwards via `SPEC_VERSION` env to `download_spec_tests.sh`
- **Nimbus** — forwards via `CONSENSUS_TEST_VECTOR_VERSIONS` env
- **Prysm** — *not* honoured: `WORKSPACE` SHA-pins per flavor; override
  would require recomputing SHAs. clive-meta records the effective ref
  accurately so the mismatch is surfaced.

## Architecture

```
┌──────────────────────────────────────────────────────────┐
│ devnet repo (e.g. ethpandaops/glamsterdam-devnets)       │
│ .github/workflows/clive-devnet-N.yaml                    │
│   matrix: cl_client × cl_source_ref × scope              │
└──────────────────────────┬───────────────────────────────┘
                           │ uses: ethpandaops/clive@master
                           ▼
┌──────────────────────────────────────────────────────────┐
│ ethpandaops/clive (this repo)                            │
│ action.yml ── lib/resolve.sh → adapters/<client>.sh      │
│   per-client toolchain step (Node / Rust / nim / JDK /   │
│   Go+Bazel) gated on cl_client                           │
│ lib/junit-to-hive.py — JUnit + clive-meta → hive schema  │
│ lib/upload-s3.sh    — AnimMouse/setup-rclone + push      │
│ lib/regen-listing.py — regen listing.jsonl from results  │
│ lib/gate.sh         — exit !=0 on gated category fails   │
└──────────────────────────┬───────────────────────────────┘
                           ▼
            s3://hive-results/spec-<network>/
                           │ (existing CloudFront)
                           ▼
            https://hive.ethpandaops.io/spec-<network>/
                           │
                  discovery.json entry
                           ▼
            ethpandaops/hive-ui (/cl view, planned)
```

## License

GPL-3.0
