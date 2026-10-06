# Gumball Proof Broker

Status: **ACTIVE / AUTHORITATIVE**

## Goal

Heavy proof workflows should not require routine clicking through GitHub Actions.

A trusted user should be able to request a configured proof directly from a pull request:

```text
/gumball proof <proof-id>
```

or by applying the configured `proof:<proof-id>` label.

The broker validates the request, exact proof revision, proof allow-list, workflow contract, duplicate state and CI-cost policy before dispatching anything. For an open PR the exact revision is its current head SHA; after merge, an explicit trusted request may target the immutable `merge_commit_sha` recorded by GitHub.

## Control flow

```mermaid
flowchart LR
    INTENT["INTENT<br/>PR label / comment"] --> AUTH["AUTHORIZE<br/>write+ permission"]
    AUTH --> PR["RESOLVE<br/>Open head SHA / merged result SHA"]
    PR --> POLICY["POLICY<br/>allow-listed proof"]
    POLICY --> COST["COST GOVERNOR<br/>light / standard / heavy"]

    COST -->|"artifact exists"| REUSE["REUSE<br/>Existing proof"]
    COST -->|"already running"| RUNNING["NO DUPLICATE<br/>Existing run"]
    COST -->|"auto + non-critical heavy"| DEFER["DEFER<br/>Manual / release / nightly"]
    COST -->|"explicit or critical"| CONTRACT["VERIFY<br/>Trusted workflow contract"]

    CONTRACT --> DISPATCH["DISPATCH<br/>workflow_dispatch"]
    DISPATCH --> STATUS["STATUS<br/>running / passed / failed"]

    classDef input fill:#303846,stroke:#8ea1b8,color:#f7f9fc,stroke-width:2px;
    classDef exec fill:#123f73,stroke:#49a2ff,color:#ffffff,stroke-width:3px;
    classDef tool fill:#4b2f69,stroke:#b77cff,color:#ffffff,stroke-width:2px;
    classDef decision fill:#69470e,stroke:#f0a72f,color:#ffffff,stroke-width:3px;
    classDef success fill:#1f5736,stroke:#63d889,color:#ffffff,stroke-width:3px;
    classDef danger fill:#6b2429,stroke:#ff6b73,color:#ffffff,stroke-width:3px;
    classDef evidence fill:#164d5c,stroke:#5bd6ef,color:#ffffff,stroke-width:2px;

    class INTENT input;
    class AUTH,PR,POLICY,CONTRACT,DISPATCH exec;
    class COST decision;
    class REUSE success;
    class RUNNING,STATUS evidence;
    class DEFER danger;

    linkStyle default stroke-width:2px;
```

## Trusted execution boundary

The broker workflow itself runs trusted default-branch code.

It never checks out the pull-request head while holding `actions: write`.

The default contract is:

1. broker definition/script comes from the repository default branch;
2. target proof workflow definition also comes from the default branch;
3. the selected source branch and exact 40-character SHA are passed as explicit workflow inputs; open PRs use the head revision, while explicit post-merge requests use the PR base branch plus GitHub's `merge_commit_sha`;
4. the proof workflow checks out the requested source SHA using read-only repository access;
5. the proof workflow's `run-name` includes the deterministic Gumball request id.

This separates **trusted orchestration** from **untrusted/changing source under test**.

Branch-local workflow definitions are disabled by default.

## Deterministic request id

A request is keyed by:

```text
proof-id + PR number + exact selected proof SHA
```

For an open PR, the selected proof SHA is the current head SHA. For an explicitly requested proof on a merged PR, it is GitHub's recorded `merge_commit_sha`. Closed-unmerged PRs are never eligible.

For example:

```text
gb-r4-1b3-geometry-pr239-b72f8927c4ad
```

The target workflow must accept the configured request-id input and include it in `run-name`.

That gives the broker a stable way to find queued/running/completed proof runs and prevents duplicate heavyweight work for the same revision.

## Proof policy

Consumers configure proofs in `.gumball/proof-broker.json`.

Example:

```json
{
  "schema_version": 1,
  "proofs": {
    "r4-1b3-geometry": {
      "enabled": true,
      "workflow": "passo-giau-r4-1b3-geometry.yml",
      "label": "proof:r4-1b3-geometry",
      "cost_class": "heavy",
      "merge_critical": false,
      "dispatch_ref": "default",
      "request_id_input": "gumball_request_id",
      "inputs": {
        "source_ref": "$branch",
        "exact_sha": "$sha",
        "pull_request": "$pr_number",
        "gumball_request_id": "$request_id"
      },
      "artifact_name": "proof-$proof-$sha",
      "allowed_write_permissions": [],
      "automatic": {
        "enabled": false,
        "require_ci_class": "heavy"
      }
    }
  }
}
```

Supported input tokens:

- `$branch` — PR head branch while open, or the PR base branch for an explicit merged-PR proof;
- `$sha` — exact PR head SHA while open, or GitHub's exact `merge_commit_sha` after merge;
- `$pr_number` — pull request number;
- `$request_id` — deterministic broker request id;
- `$proof` — proof id.

Other values are passed literally.

## Trigger modes

### Comment

```text
/gumball proof r4-1b3-geometry
```

The same explicit command is valid on a merged PR. In that case the broker binds the proof to the recorded merge result SHA rather than to the former feature-branch head. This supports the safe `merge -> exact-SHA runtime/visual proof` workflow without reopening the PR or creating synthetic commits. Because the hourly reconciler intentionally scans only open PRs, a comment-triggered post-merge proof is tracked by its deterministic request id, run and status result rather than by re-adding the request label after closure.

Explicit retry after a failed run:

```text
/gumball proof r4-1b3-geometry retry
```

Status-only query:

```text
/gumball proof r4-1b3-geometry status
```

### Label

Applying the configured proof label is an explicit request.

The broker verifies that the actor has one of the configured repository permissions before dispatching.

Automation/apps can be trusted explicitly through `defaults.trusted_actor_logins`. The default list is empty: Gumball never treats every bot as trusted. A consumer may add the exact login of its approved ChatGPT/Codex/GitHub App actor so an agent can request a proof without the human opening the Actions UI.

### Automatic

A proof may opt into automatic dispatch, but the broker does **not** wake up on every PR synchronize event.

A cheap trusted classifier emits a `repository_dispatch` event only when it believes a configured proof may be required:

```json
{
  "event_type": "gumball-proof-request",
  "client_payload": {
    "proof": "r4-1b3-geometry",
    "pr_number": 239
  }
}
```

The broker then independently re-evaluates the proof policy and current PR paths.

Automatic heavy proof is allowed only when:

- the proof policy marks it `merge_critical=true`;
- the change classification matches the configured CI class;
- no reusable artifact/successful run exists;
- no identical proof is queued/running.

Non-merge-critical heavy proof is **DEFERRED** rather than burned automatically.

This design avoids spending a runner merely to discover on every commit that no heavy proof is needed.

### Manual fallback

The target workflow keeps ordinary `workflow_dispatch` support as an emergency fallback.

The broker reduces routine clicking; it does not remove GitHub's manual recovery path.

## Artifact reuse

If `artifact_name` is configured, the broker looks for a non-expired exact artifact before dispatch.

A matching artifact produces `REUSE` rather than a new heavy run.

Artifact identity should include the exact proof id and source SHA or a stronger build/proof fingerprint.

## Existing runs

For the deterministic request id:

- queued/in-progress -> `ALREADY_RUNNING`;
- completed success -> `REUSE_RUN`;
- completed failure -> `FAILED_EXISTING` until explicit `retry`;
- explicit retry reruns the existing failed workflow rather than creating uncontrolled duplicate history.

## Status labels

The broker maintains status labels **per proof**, so multiple independent proofs can coexist on one PR:

- `proof-status:<proof-id>:requested`;
- `proof-status:<proof-id>:running`;
- `proof-status:<proof-id>:passed`;
- `proof-status:<proof-id>:failed`;
- `proof-status:<proof-id>:deferred`;
- `proof-status:<proof-id>:reused`.

For example, `proof-status:r4-1b3-geometry:passed` can coexist with `proof-status:visual:running`.

The proof request label remains separate, for example `proof:r4-1b3-geometry`. A comment-triggered request adds that request label automatically so the hourly reconciler can continue tracking the proof after dispatch.

## Consumer workflow contract

A broker-managed proof workflow must:

- exist on the default branch;
- support `workflow_dispatch`;
- accept the configured exact-SHA input;
- accept the configured request-id input;
- include that request id in `run-name`;
- use and reference the exact requested source-SHA input for the proof;
- run read-only by default; any `*: write` workflow permission must be explicitly allow-listed in the proof policy;
- never use `permissions: write-all`;
- produce the configured artifact name when artifact reuse is enabled.

Example shape:

```yaml
name: Heavy geometry proof
run-name: proof ${{ inputs.gumball_request_id }}

on:
  workflow_dispatch:
    inputs:
      source_ref:
        required: true
        type: string
      exact_sha:
        required: true
        type: string
      pull_request:
        required: true
        type: string
      gumball_request_id:
        required: true
        type: string

permissions:
  contents: read

jobs:
  proof:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout exact requested revision
        uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1
        with:
          ref: ${{ inputs.exact_sha }}
          persist-credentials: false

      - name: Verify exact SHA before expensive work
        shell: bash
        env:
          EXPECTED_SHA: ${{ inputs.exact_sha }}
        run: |
          set -euo pipefail
          test "$(git rev-parse HEAD)" = "${EXPECTED_SHA}"
```

The expensive proof starts only after the exact-revision assertion succeeds.

## Recovery

If broker configuration, workflow contract, requester permission, PR merge state or Projects/API access is ambiguous, the broker returns **BLOCKED** and does not dispatch. A closed PR that was not merged remains ineligible, and automatic dispatch is not allowed to wake up a merged PR.

No proof should be started merely because Gumball could not determine whether it was safe.

Status labels and result comments are bookkeeping rather than proof authority. Once the broker has authoritatively resolved an outcome from policy plus run/artifact state — for example `DISPATCH`, `ALREADY_RUNNING`, `REUSE`, `REUSE_RUN`, `FAILED_EXISTING`, `RERUN`, `DEFER`, or a status-only query — a later status-label/comment write failure preserves that outcome and is emitted as a diagnostic **WARN** with the failing GitHub API operation. Fresh `workflow_dispatch` and workflow rerun API calls themselves remain fail-closed: if those authoritative operations fail, the broker returns **BLOCKED**. Deterministic request ids remain the dedupe key, so repairing bookkeeping must never create a second heavyweight run for the same request.

