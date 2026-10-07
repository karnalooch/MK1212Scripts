# twdll monorepo migration audit

Status: **REPO-OBSERVED**; repository/build proof PASS on the migration merge; Attila runtime proof pending  
Audit issue: #38  
Migration issue: #36  
Migration PR: #37  
Audit date: 2026-10-07

## Executive result

The monorepo migration is structurally sound.

The audit found **no content corruption** in the imported twdll snapshot or the vendored MinHook dependency. It did find one proof-semantics weakness: the pull-request CI run for PR #37 used GitHub's default synthetic merge ref rather than checking out the PR head directly. The merged master commit itself subsequently received a green push run, so the merged state is validated. Issue #38 hardens future caller-local jobs to assert the exact revision explicitly.

This document records repository evidence only. It does not claim current-build Attila runtime compatibility.

A separate follow-up audit now reviews the **implementation itself** rather than import fidelity: [TWDLL_RUNTIME_AUDIT.md](TWDLL_RUNTIME_AUDIT.md), tracked by issue #40. The migration audit remains the provenance/integrity baseline; post-import MK1212 maintenance changes are intentionally evaluated in the runtime audit instead of being misrepresented as byte-identical upstream content.

## Pinned inputs

| Component | Pinned source |
| --- | --- |
| MK1212 migration merge | `6c974969b66302acc203ed76868c437004f96fa9` |
| Imported twdll fork | `karnalooch/twdll@85c4db9836e3150df8ec5b38315de9940f8d624c` |
| Original twdll upstream | `bukowa/twdll` |
| Vendored MinHook | `TsudaKageyu/minhook@d94c64d32ea37bc4f5ee47d580709f70c6fb6080` |

## Import integrity audit

A recursive Git-tree comparison was performed against the pinned twdll source.

Deliberate monorepo differences are:

1. `native/twdll/.gitmodules` is absent;
2. the original `vendor/minhook` gitlink is replaced by the full pinned MinHook source tree;
3. MK1212 adds `native/twdll/UPSTREAM.md` and repository-level integration/CI documentation.

The upstream `.github/workflows/*` files are preserved below `native/twdll/.github/workflows/` as source provenance. They are **not active GitHub Actions workflows**, because GitHub only loads workflows from the repository-root `.github/workflows/` directory.

### twdll result

After accounting for the deliberate differences:

- missing imported paths: **0**;
- mismatched imported blobs: **0**;
- unexpected imported paths: **0**.

### MinHook result

The vendored `native/twdll/vendor/minhook/` tree was compared with the pinned MinHook commit:

- expected entries: **79**;
- missing entries: **0**;
- mismatched blobs: **0**;
- unexpected entries: **0**.

### Large test-save preservation

The large binary test saves retain the source Git blob identities:

- Attila: `17840d85fe5ca6300f2b251bdfe5a352e351d702`;
- Rome II: `d60dc6e3503358e9ca3fc414d3f7fadd2a8752c7`.

## CI evidence from the migration

PR #37 head was `0aeb79190b008ab7a3fcddc58d72b4ca1032bdc3`.

GitHub Actions run `37613915190` completed successfully. The default PR checkout resolved to the synthetic merge commit `c119dbfae2d46f5ec2ff76687948ca70d87f3db0`, combining the PR head with base `8eab4eefde94043f3dd49781067e5c19e9232d66`.

That run proved:

- repository static contract: PASS;
- governance: PASS;
- repository policy: PASS;
- Trivy filesystem scan: PASS;
- native Attila Win32 compile/link: PASS;
- caller-local Aggregate CI gate: PASS.

After PR #37 merged, push run `37614101529` executed on exact master commit `6c974969b66302acc203ed76868c437004f96fa9` and all required baseline jobs, including the native build and Aggregate gate, passed.

### Proof-semantics correction

A workflow associated with a PR head is not automatically an exact-head checkout. On `pull_request`, `actions/checkout` defaults to GitHub's merge ref.

Issue #38 therefore hardens caller-local CI to:

- checkout `${{ github.event.pull_request.head.sha || github.sha }}`;
- assert `git rev-parse HEAD` equals that expected SHA;
- keep push/workflow-dispatch behavior on the exact event SHA.

Reusable Gumball workflows remain separately governed by their own checkout semantics; the caller-local static/native evidence now has an explicit exact-revision contract.

## Native artifact contract

The Attila CI lane configures CMake with `-A Win32 -DTW_GAME=attila` and builds only the `twdll` target.

Issue #38 adds an artifact check that requires the resulting `twdll.dll` to:

- contain a valid PE signature;
- use `IMAGE_FILE_MACHINE_I386 (0x014c)`, proving a 32-bit/x86 artifact;
- contain the `luaopen_twdll` export marker required by Lua `package.loadlib`.

This remains a build-shape proof, not a runtime load proof.

## Build identity after moving into the monorepo

`native/twdll/CMakeLists.txt` derives `TWDLL_BUILD_SHA` with `git rev-parse HEAD`.

Before the migration that SHA identified the standalone twdll repository. After the migration it identifies the **MK1212Scripts commit** containing both the Lua/mod code and the native source.

Therefore:

> `twdll.core.GetBuildSha()` is the canonical MK1212 exact-source identity for native runtime evidence.

The imported twdll SHA remains a provenance anchor, not the identifier of future MK1212-native builds.

## Trivy exception audit

The imported file `native/twdll/docs/lua/ldoc/Dockerfile` triggers `AVD-DS-0002` because its final container starts as root. The file explains why: the entrypoint compares the mounted workdir ownership and uses `setpriv` to drop to the matching effective UID/GID when required.

The exception is acceptable for the current repository boundary because:

- it is docs-generation tooling, not game/runtime code;
- the exception applies to exactly one finding ID and exactly one path;
- a global `.trivyignore` is forbidden by the repository static guard;
- the path-scoped exception is itself checked by `scripts/ci/check_repository.py`.

Any attempt to broaden this ignore or reuse it for another path requires an explicit reviewed change.

## What this audit does not prove

The following remain **not runtime-proven**:

- loading the built DLL into the current 2026 Attila executable;
- signature compatibility with the current game binary;
- save/load reinitialization and cleanup;
- passive two-peer behavior;
- host/client equality of semantic snapshots;
- absence of gameplay side effects from loading native hooks.

Those remain part of the staged runtime validation plan in [TWDLL_OBSERVABILITY_BACKEND.md](TWDLL_OBSERVABILITY_BACKEND.md).

## Decision

The monorepo migration is accepted as the canonical repository structure:

- `native/twdll/` is the MK1212 native source of truth;
- the standalone `karnalooch/twdll` repository is historical/reference;
- MinHook remains vendored and pinned;
- security exceptions stay narrow and fail-closed;
- future runtime evidence uses the MK1212Scripts commit SHA as the native build identity.
