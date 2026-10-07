# twdll provenance in MK1212Scripts

`native/twdll/` is the canonical MK1212 native source of truth.

## Imported source

- MK1212 maintenance repository: `karnalooch/MK1212Scripts`
- Imported fork: `karnalooch/twdll`
- Exact imported twdll SHA: `85c4db9836e3150df8ec5b38315de9940f8d624c`
- Original upstream: `bukowa/twdll`
- Import date: 2026-10-07
- License: GPL-3.0, preserved in `LICENSE`

The old `karnalooch/twdll` repository is intentionally left untouched as historical/upstream reference. Future MK1212-specific native development belongs in this monorepo unless a later explicit decision changes that policy.

## MinHook vendoring

The former `vendor/minhook` git submodule is replaced by a self-contained vendored snapshot:

- upstream: `TsudaKageyu/minhook`
- exact commit: `d94c64d32ea37bc4f5ee47d580709f70c6fb6080`
- vendored path: `native/twdll/vendor/minhook/`
- license: preserved in `native/twdll/vendor/minhook/LICENSE.txt`

`native/twdll/.gitmodules` is intentionally absent. A single checkout of MK1212Scripts contains everything required for the native build.

## Import policy

At the migration boundary, the imported twdll source matched the pinned source snapshot byte-for-byte except for deliberate monorepo integration differences:

- upstream `.github/workflows/*` files remain preserved below `native/twdll/.github/workflows/` as inert provenance; GitHub only activates workflows from repository-root `.github/workflows/`;
- `native/twdll/.gitmodules` is intentionally removed;
- the MinHook gitlink is replaced by the pinned vendored source snapshot;
- `UPSTREAM.md` and monorepo CI/documentation are MK1212-owned additions.

## Verified migration evidence

Migration issue #36 was merged by PR #37 into master commit `6c974969b66302acc203ed76868c437004f96fa9`.

A recursive Git-tree audit against `karnalooch/twdll@85c4db9836e3150df8ec5b38315de9940f8d624c` found:

- 0 missing imported twdll paths;
- 0 mismatched imported twdll blobs;
- 0 unexpected twdll paths after accounting for the deliberate monorepo differences above;
- the vendored MinHook tree matches all 79 entries from `TsudaKageyu/minhook@d94c64d32ea37bc4f5ee47d580709f70c6fb6080`.

The large test-save Git blobs are preserved exactly:

- Attila: `17840d85fe5ca6300f2b251bdfe5a352e351d702`;
- Rome II: `d60dc6e3503358e9ca3fc414d3f7fadd2a8752c7`.

The detailed migration audit is recorded in `docs/research/TWDLL_MONOREPO_AUDIT.md`.

## Post-import MK1212 maintenance

The byte-identical statement above describes the **migration baseline**, not the forever state of the maintained monorepo copy.

Issue #40 performs the first MK1212-owned implementation audit and intentionally changes the active Attila source to harden:

- signature-scan bounds and malformed-pattern handling;
- Lua ABI fail-closed initialization;
- loader-lock safety;
- multi-Lua-state hook ownership;
- transactional MinHook rollback;
- selected Lua API edge cases and engine-state rollback;
- bounded native diagnostics;
- native scanner regression coverage in caller-local Windows CI.

Those post-import changes are documented in `docs/research/TWDLL_RUNTIME_AUDIT.md`. Future provenance checks must compare against the migration baseline when proving import fidelity and against the current MK1212 commit when proving maintained runtime behavior. Do not describe the maintained tree as byte-identical to the historical imported fork after issue #40.

## Runtime build identity

`twdll.core.GetBuildSha()` is compiled from `git rev-parse HEAD`. Because `native/twdll/` now lives inside MK1212Scripts, the returned SHA is the **MK1212Scripts repository commit** used for the build, not the historical standalone twdll commit. This is the canonical native build identity for future exact-build diagnostics.

## Security scan exception

Trivy finding `AVD-DS-0002` is ignored only for `native/twdll/docs/lua/ldoc/Dockerfile`. That imported docs-only container intentionally starts as root so its entrypoint can switch to the mounted workdir owner. The exception is path-scoped, guarded by `scripts/ci/check_repository.py`, and does not apply to MK1212 runtime/native build code.

Do not silently resync from either external repository. Any future upstream sync must be an explicit, reviewed change that records the old and new source SHAs.
