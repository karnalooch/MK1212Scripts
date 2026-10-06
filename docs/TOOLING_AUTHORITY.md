# Tooling authority contract

Status: **ACTIVE / AUTHORITATIVE**

## Purpose

Gumball standardizes how repositories choose, admit, version and validate engineering tools without turning one project's preferred vendor or editor into a platform dependency.

The repository is the authority for accepted engineering artifacts and tool contracts. External tools may edit, inspect or generate those artifacts, but a private workspace or SaaS state must not silently become the only source of truth.

## Admission order

Before building a custom tool, evaluate options in this order:

1. a proven public production pattern or already-reviewed tool that solves the same class of problem;
2. the target platform's native capability;
3. proven open-source or DCC tooling with acceptable provenance and licensing;
4. the smallest project-owned custom tool that closes the remaining gap.

This is a decision order, not a vendor mandate. A consumer may choose a different implementation when its constraints justify it, but the reason should be explicit.

## Repository return path

A tool may become part of an authoritative engineering workflow only when at least one is true:

- it is repository-native; or
- it has a deterministic CLI/API/export/sync path back to versionable repository artifacts that can be reviewed in pull requests and validated in CI.

A workspace with no deterministic repository return path is **research/convenience only** and cannot be the sole authority for accepted output.

Generated bridges must be checked by content equality or another deterministic digest/semantic comparison. File modification times are not a valid freshness contract.

## Provenance and supply chain

Production engineering tools and vendored helpers must record, as applicable:

- exact upstream revision or immutable package version;
- license/provenance evidence;
- repository-local lockfile or equivalent dependency graph lock;
- reproducible installation command;
- whether dependency install scripts execute;
- any security override or patched transitive dependency and why it exists.

Prefer non-executing/reduced-side-effect installation modes when the ecosystem supports them. If install scripts are required, make that exception explicit and reviewable.

Public references must be described as public evidence. Do not present an external public repository as proof of a company's complete proprietary internal pipeline.

## Lifecycle boundary

Developer, DCC, editor and proof tooling are excluded from shipping/runtime artifacts by default.

A tool crosses into a shipping surface only through an explicit product decision, dependency/provenance review and runtime proof. Profiles may strengthen this rule, for example by requiring Unreal editor plugins to remain editor-only unless deliberately promoted.

## Agent/API shape

Prefer high-level domain operations with bounded inputs and outputs over exposing a broad low-level agent API. Raw editor/filesystem/runtime primitives remain escape hatches, not the preferred contract.

## Drift guards

Repositories should contract-test the boundaries that matter to their toolchain, including:

- admission/authority metadata;
- editor/dev-only versus shipping lifecycle;
- exact upstream pins and lockfiles;
- repository return-path requirements;
- provenance/license markers;
- deterministic generated-artifact freshness.

A missing or ambiguous required boundary fails closed.

## Downstream evidence

This contract generalizes patterns proven in YACS PRs #281/#283 and 4VELO PRs #400/#402/#403/#407. Product-specific vendors, maps, routes, assets and runtime implementations remain downstream.
