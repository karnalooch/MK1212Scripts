# Gumball adoption

Status: **ACTIVE / BASELINE**

## Source

- Product: **Gumball**
- Profile: `standard`
- Adoption mode: `preserve-local`
- Platform version: `0.7.0`
- Immutable platform revision: `ddc458c223b8020c5f36482415d4405459bd373a`
- Baseline source repository: `karnalooch/engineering-platform`

## Audit

The fork started with the upstream MK1212 source tree and a minimal README. It had no `AGENTS.md`, `docs/`, `.github/`, Gumball policy, repository security policy or CI workflow.

The upstream gameplay/data directories are intentionally preserved.

## Adoption plan

| Classification | Surface | Decision |
| --- | --- | --- |
| ADD | Gumball config / Repository OS | Add standard baseline |
| ADD | Agent contract | Add project-specific `AGENTS.md` |
| ADD | Documentation router / architecture | Add local SSOT map |
| ADD | Caller-local Aggregate CI | Add cheap fail-closed validation |
| ADD | Governance / repository policy / security | Use immutable Gumball reusable workflows |
| ADD | Repository ops | Add canonical lifecycle/label reconciliation |
| ADD | Proof Broker contract | Install disabled/empty proof registry for future exact-SHA runtime proof |
| KEEP | Existing MK1212 Lua/TSV/UI/source | No bootstrap behavior changes |
| KEEP | Existing README attribution | Leave untouched |
| DEFER | GitHub Projects | Not enabled for this repository |
| DEFER | Heavy multiplayer/runtime proof | Define only when a reproducible harness exists |
| DEFER | Release lineage enforcement | Standard profile is not release-critical |
| CONFLICT | Issue-first workflow | GitHub Issues are disabled for this fork; GitHub API returned HTTP 410 |

## CI cost policy

Routine PR validation is intentionally cheap:

- Gumball repository policy;
- Gumball governance;
- lightweight security baseline;
- repository/static contract validation;
- caller-local `Aggregate CI gate`.

No Attila launch, game install, Windows runner, multiplayer session or visual proof is required on ordinary PRs.

## Follow-up

After this baseline is merged, multiplayer/desync work should start as a separate scoped change. The first product-level tranche should audit deterministic RNG and event/model mutation boundaries before changing gameplay.
