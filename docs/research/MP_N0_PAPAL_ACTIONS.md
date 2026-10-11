# Papal transitions and nickname RNG ordering

Issue: #69
Scope: N0 confirmed Lua errors and N3 native Papal callback discipline
Evidence: **REPO-OBSERVED** implementation; production-Lua fixture prepared for the final N4 validation pass. Real Attila two-peer delivery is **NOT RUNTIME-PROVEN**.

## Changes and their purpose

`mechanics/pope/mechanics_pope_favour.lua` now resolves automatic excommunication removal from `context:character():faction()`. Both automatic and manual removal use a validated, one-shot transition. Dynamic faction rank is read from the `FACTIONS_DFN_LEVEL` table; a missing rank uses the ordinary faction localization key. Updating favour/effect bundles finishes before optional notifications, and a notification exception cannot abort a valid model transition.

The non-Catholic capture of Rome resolves its faction collection before applying Catholic dejection. The previous branch referenced an undefined `faction_list` after showing a message. Faction lookup failures no longer select a substitute target. Pope decision enable/disable/remove operations carry the explicit owner faction.

`Decision_Pope_Money(actor)` is an executor. `MKMP_Papal_Validate_Loan(actor)` checks a live human Catholic faction, active Papacy, no excommunication and favour 8–10 before any treasury command. Its result is `(allowed, reason, amount)`. The executor returns `true` after requesting treasury/favour effects, or `false, reason` before mutation. The generic action registry owns intent acceptance, the execution claim and the no-retry response to an exception after partial effects. A successful Lua return does not confirm replicated engine state.

Pope initializers own their registrations once. Reactivating the favour system can restore listeners after explicit deactivation without registering the active set twice.

## Postbattle lifecycle

The old global one-second latch is removed from gameplay. A previously queued `Postbattle_Decision_Pope` timer cannot reopen a decision and schedules no replacement.

One `PendingBattle` observation captures the two primary participants' faction keys, character CQIs, force CQIs and Catholic status. Repeated pending callbacks while that lifecycle is pending do not create a new record. A completed/decision callback must match the captured participants and round, and present valid non-retreat results. Missing participants fail closed; no unchecked `pending_battle:attacker()` or `:defender()` access is used.

The decision handler can observe valid results itself when it precedes `CharacterCompletedBattle`. It claims one decision per captured faction before changing favour or issuing an engine command. Reinforcement callbacks from the same faction cannot duplicate the claim. The two human factions have independent claims. An error leaves an `unknown` claim; a retry, conflicting choice, timer or save/reload cannot automatically repeat it. Completed callbacks only observe results.

The sequence number is named an **observer lifecycle ordinal**, not a network battle ID. A new observed `PendingBattle` can open a second lifecycle for the same actors in the same round. Attila's exact event delivery/order must still be measured on both peers. In particular, the repository cannot distinguish an arbitrarily delayed duplicate old `PendingBattle` from a genuinely new battle solely from reused actors and results. Allied reinforcement factions outside the two captured primary factions are rejected instead of guessing an enemy side. A missing `PendingBattle` cannot be synthesized from the turn and general. These are explicit proof limits, not silent fallbacks.

Diagnostic `papal_action` records use `domain=shared_candidate`, `shared_delivery=unproven` and actual callback phases. The `papal` state provider returns copied maps and lifecycle state. Modifying a returned snapshot cannot change gameplay.

## Persistence and rollback

| Owned field | Format and budget | Migration and failure behavior |
| --- | --- | --- |
| `MKMP_PAPAL_BATTLE_STATE` | Single value beginning `MKMP_PAPAL_BATTLE_V1;`; one active lifecycle, two primary participants, at most two faction decisions; 4,096 bytes. Ordinal and CQIs are nonnegative integers no larger than 16,777,215. | Missing legacy field means no captured battle; wait for a fresh `PendingBattle`. No action runs during loading. Valid claims survive load; a saved `claimed` entry becomes `unknown`. Invalid/future/oversized frames are preserved verbatim and disable postbattle processing. |
| `MKMP_NICKNAME_TURNS` | Single value beginning `MKMP_NICKNAME_TURNS_V1;`; at most 4,096 faction/round records and 262,144 bytes. | Missing legacy field means an empty completed-turn ledger, without executing a turn during load. Invalid/future fields are preserved verbatim and stop nickname turn processing. |

The existing Papal favour and excommunication formats remain owned by the common save codec. Their whole loaded snapshot is read and checked before either map is replaced. Favour values remain integer values in the established 0–10 range. Nickname labels and stats retain their existing formats; both are read before replacement.

The new metadata uses a version prefix inside the same engine save value, avoiding an independently written version sidecar. Attila owns the outer save transaction; the code does not claim to make engine model changes and script saves an atomic transaction. Keeping a pre-update campaign save remains the rollback method. Old scripts ignore the added metadata and cannot enforce its duplicate suppression if used again.

## Nickname processing

`nicknames/nicknames_tracking.lua` traverses initial factions by bytewise faction key, characters by validated CQI and trait candidates by bytewise trait key. A low-level eligible trait still draws once from `[1, 10]`; a high-level trait still consumes no draw. The wrapper records each draw without drawing diagnostic randomness. The original equal-priority rule keeps the existing nickname; the ordered trait traversal makes candidate precedence explicit. Assigning the same pseudorandom sequence to a different trait order is an intentional behavior change.

Faction turn processing claims its faction/round before the first random draw or nickname stat increment. A repeated callback or reload cannot add another `turns_without_revolt` increment or consume the next shared draw. The historical/new-game pass remains distinct from the first faction-turn pass, retaining the upstream two-phase initialization behavior. Initializers are idempotent. No new timers are introduced.

The initializer registers a separate `nicknames` diagnostic provider. `MKMP_Nicknames_Get_State()` returns copied nickname labels, counters and the private faction-turn ledger; an invalid phase save reports an incomplete component rather than an empty successful snapshot.

One-argument campaign RNG calls elsewhere in the Papal subsystem remain an explicitly incomplete coverage area. This change only wraps calls whose supplied lower and upper bounds are already known; it does not infer a default lower bound or remove existing draws from Pope selection.

## Consolidated validation after N4

`scripts/ci/test_mp_n0_papal.py` runs the actual production modules in one Lua 5.1 fixture, minimizing repeated process/build work. The fixture covers:

- character-only leader contexts, missing/ranked localization, two human factions, repeated removal and optional UI exceptions;
- non-Catholic Rome capture and completion of all intended Catholic effect changes;
- duplicate listeners, pending/completed/decision callback orders, same-faction reinforcement duplication, independent faction claims and two observed battles in one round;
- missing actors/participants, stale rounds, no fabricated lifecycle, no timer reopening, partial failures, save/reload, future schema retention and immutable snapshots;
- Papal loan thresholds, amounts, eligibility, dead/missing actors and UI failure after a valid loan;
- opposite trait construction and character enumeration order, exact RNG draw count/range, the next shared draw, duplicate turns, persistence and separate new-game/first-turn processing.

These are repository regressions with mocked Attila interfaces. They do not certify actual callback equality, transport delivery, command queue behavior or absence of an Attila desync. The campaign test is intentionally consolidated with the N4 two-PC run, rather than asking the user to run a campaign at every intermediate stage.
