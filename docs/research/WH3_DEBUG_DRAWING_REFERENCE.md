# WH3 battle debug drawing — reference only

Authority class: **CROSS-TITLE-REFERENCE / Tier D**  
Primary source: https://chadvandy.github.io/tw_modding_resources/WH3/battle/battle_debug_drawing.html  
Last reviewed: 2026-10-06

## Why this source is useful

The modern WH3 battle scripting documentation provides a clear example of what a mature Total War battle instrumentation surface can look like.

It is useful for designing our **debugging vocabulary and desired observability** for Attila.

It is **not** proof that Attila exposes the same object, method names, parameters, colour type, or enablement path.

## Capabilities documented for WH3

The WH3 `debug_drawing` interface is obtained from the battle object and supports battlefield overlays when debug drawing is enabled.

The source documents these capability classes:

### Terrain primitives

- white circle;
- white line;
- white vertical peg;
- coloured circle;
- coloured line;
- coloured peg.

This gives us a useful pattern for visualizing:

- spawn zones;
- movement targets;
- disputed positions;
- synchronization checkpoints;
- battle trigger radii;
- scripted areas.

### Oriented rectangle / OBB

The source documents a terrain OBB/rectangle with:

- position;
- width;
- height;
- orientation;
- duration;
- colour.

For Attila research, this is a useful **design target** for drawing army footprints, trigger boxes or collision/zone boundaries if an equivalent supported mechanism can be found.

### Debug text

The source documents:

- 2D debug text;
- 3D debug text.

For our future MP instrumentation this suggests a desirable display vocabulary:

- peer ID / local faction;
- turn / round;
- event name;
- CQI;
- deterministic sequence number;
- state hash;
- battle transition state.

Again, these exact functions are not assumed to exist in Attila.

### Colour objects

WH3 documents an RGB colour object used by coloured debug primitives.

This is relevant as a visualization convention even if Attila ultimately requires a different implementation.

Suggested semantic colours for future tooling, if supported:

- green = shared/confirmed state;
- amber = pending/unconfirmed state;
- red = divergence/error;
- cyan = local-only observation;
- magenta = hypothesis/instrumentation.

Do not bake these semantics into game logic.

## Compatibility boundary

Never write Attila code such as:

```lua
battle:debug_drawing():draw_line_on_terrain(...)
```

solely because this WH3 page exists.

Before using any modern API concept in Attila:

1. search official ATTILA battle docs;
2. inspect Attila example battle scripts;
3. search the current game/mod scripts;
4. run an exact-build experiment;
5. record whether the equivalent is AVAILABLE, DIFFERENT, or ABSENT.

## Recommended adaptation pattern

Treat WH3 documentation as a product requirement for observability, not an implementation contract.

Example:

| Desired capability | WH3 reference | Attila action |
| --- | --- | --- |
| draw a line between two positions | `draw_line_on_terrain` | find documented Attila equivalent or mark unsupported |
| mark a spawn point | `draw_peg_on_terrain` | test official debug UI/battle scripting alternatives |
| show state text | `draw_2d_text` / `draw_3d_text` | prefer Lua logging first; add visual layer only if proven |
| show zone footprint | `draw_obb_on_terrain` | derive equivalent only after Attila capability proof |

## Research outcome states

For each WH3-derived idea record one of:

- **UNTESTED** — no Attila check performed;
- **ATTILA-DOCUMENTED** — official Attila equivalent found;
- **ATTILA-RUNTIME-PROVEN** — equivalent confirmed on exact build;
- **ATTILA-DIFFERENT** — capability exists but API/semantics differ;
- **ATTILA-ABSENT** — no supported equivalent found for tested scope;
- **REQUIRES-INSTRUMENTATION** — cannot achieve through supported API.

## Why this matters for AI agents

Modern Total War documentation is easier to search and often better structured than old Attila material. That makes accidental API hallucination especially likely.

Agents must therefore label any WH3-derived proposal as **CROSS-TITLE-REFERENCE** until Attila evidence upgrades it.
