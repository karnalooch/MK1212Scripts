# Architecture

Status: **ACTIVE**

## Repository role

`MK1212Scripts` contains the scripting/data layer used by Medieval Kingdoms 1212 AD on Total War: Attila. This fork adds a repository-engineering layer around the existing upstream source without changing game behavior as part of the Gumball bootstrap.

## Runtime shape

```mermaid
flowchart LR
    A[Total War: Attila campaign runtime] --> B[campaigns/main_attila/scripting.lua]
    B --> C[mk1212_start.lua]
    C --> D[Common / mechanics / kingdoms / invasions / story]
    D --> E[Campaign model]
    D --> F[UI / incidents / dilemmas]
    G[db + text + ui data] --> A
```

The diagram describes ownership boundaries, not a network synchronization guarantee.

## Source layout

- `campaigns/main_attila/` — campaign bootstrap and gameplay systems.
- `lua_scripts/` — frontend/global helper scripts.
- `script/_lib/` — R2TR scripting toolkit code.
- `db/` — database table fragments.
- `text/` — localization data.
- `ui/` — UI assets/content.

## Repository-engineering layer

- `gumball.yaml` — adopted Gumball profile and policy entry point.
- `.gumball/` — lifecycle, CI-cost and Proof Broker policy.
- `.github/workflows/` — trusted CI and repository automation.
- `scripts/gumball.py` and `scripts/ops/` — repository contract tooling.
- `scripts/ci/` — cheap project-local validation.
- `docs/` — documentation router and engineering contracts.

## Multiplayer boundary

Attila multiplayer executes campaign logic on multiple peers. A model-changing script is safe only when equivalent inputs produce equivalent model mutations on every peer.

For future multiplayer changes, separately classify:

1. deterministic campaign/model operations;
2. local UI-only behavior;
3. random-number sources;
4. listener/event ordering;
5. save/load state;
6. battle-to-campaign transitions.

Runtime multiplayer proof is intentionally not part of routine Gumball PR CI. When introduced, it must be exact-SHA and explicitly brokered/manual rather than silently becoming an expensive per-PR lane.
