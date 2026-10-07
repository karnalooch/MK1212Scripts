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

The imported twdll source matches the pinned source snapshot byte-for-byte except for deliberate monorepo integration differences:

- twdll root GitHub workflow files are not installed as active MK1212 workflows;
- the MinHook gitlink is replaced by the pinned vendored source snapshot;
- monorepo-specific provenance and CI documentation may be added around the imported source.

Do not silently resync from either external repository. Any future upstream sync must be an explicit, reviewed change that records the old and new source SHAs.
