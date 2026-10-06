# MK1212Scripts documentation

This is the documentation router and authority map for this fork.

## Start here

- [Architecture](ARCHITECTURE.md) — repository layout, runtime boundaries and authoritative surfaces.
- [Gumball adoption](GUMBALL_ADOPTION.md) — repository-platform baseline, current immutable platform pin and deferred items.
- [Diagram style](DIAGRAM_STYLE.md) — required Blueprint-style diagram conventions.
- [Tooling authority](TOOLING_AUTHORITY.md) — rules for selecting and admitting engineering tools.
- [Proof Broker](PROOF_BROKER.md) — exact-SHA heavyweight proof contract. No MK1212 heavyweight proof is enabled yet.
- [Security policy](../SECURITY.md) — reporting and repository security boundaries.

## Authority map

| Subject | Authority |
| --- | --- |
| Game/mod behavior | Lua/TSV/content under `campaigns/`, `lua_scripts/`, `script/`, `db/`, `text/`, `ui/` |
| Agent workflow | `AGENTS.md` |
| Gumball adoption | `gumball.yaml` + `docs/GUMBALL_ADOPTION.md` |
| Repository lifecycle / labels / CI cost | `.gumball/repository-os.json` |
| Heavy proof routing | `.gumball/proof-broker.json` |
| Tool admission | `tools/capabilities.yaml` + `tools/authority-policy.json` |
| Security reporting | `SECURITY.md` |
| CI truth | `.github/workflows/ci.yml` and its caller-local `Aggregate CI gate` |

Do not create a second document for a subject already owned by one of these surfaces.
