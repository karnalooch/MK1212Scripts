# Native diplomacy payment path: source audit and passive probe target

Issue: #69
Source audited: `MK1212Scripts@3c2ae49265fe0abad140c7f8b1091b3c08d69ca5`, canonical `native/twdll/`
Status: **REPO-OBSERVED bindings; original payment call graph BLOCKED by missing dump; proposed hook HYPOTHESIS**
Scope: the user's requested investigation of original Attila diplomacy, money transfers, turn notifications and dilemmas as potential shared delivery mechanisms. This pass makes no native C++/layout/hook edits.

## Finding

The original accepted diplomatic payment is a useful target because the engine already has to express that transaction in its own multiplayer model. The current twdll treasury setter does not reveal or reuse that transaction. It writes a faction field directly. The native command identity, acceptance-to-application order and script-notification boundary are still unproven.

This distinction matters operationally: using a treasury setter as a message carrier would mutate a balance without reproducing the original accepted proposal, matching debit/credit, validation, command sequencing or replay handling. Observing a balance change cannot identify its cause: recruitment, construction, income, upkeep, scripted rewards and several diplomatic transfers can change the same state.

## Exact source anchors

All native links below are pinned to the audited source commit, not a moving branch. None is a proof of an address in the user's current game binary.

| Source | Observed implementation | Consequence |
| --- | --- | --- |
| [faction.cpp](https://github.com/karnalooch/MK1212Scripts/blob/3c2ae49265fe0abad140c7f8b1091b3c08d69ca5/native/twdll/src/attila/faction.cpp#L31) (`Props::Treasury`; getters/setters at 49/61; registrations at 524–525) | `GetTreasury` and `SetTreasury` use generic `Property` accessors | A balance observation/write, not an exposed accepted-deal operation |
| [tw.h](https://github.com/karnalooch/MK1212Scripts/blob/3c2ae49265fe0abad140c7f8b1091b3c08d69ca5/native/twdll/src/common/tw.h#L110) (`tw_set`, `Property::set`) | Converts Lua input, assigns the typed field and returns zero Lua results | No native diplomacy call, no queued-command handle, no transaction acknowledgment. The existing setter's boolean-success documentation does not match this implementation |
| [tw_types.h](https://github.com/karnalooch/MK1212Scripts/blob/3c2ae49265fe0abad140c7f8b1091b3c08d69ca5/native/twdll/src/attila/tw_types.h#L208) (`TW_Faction::treasury`; assertion at 764) | A 32-bit integer field with a compile-time layout assertion | An existing source/layout anchor; the assertion cannot establish current-binary semantic correctness |
| [game_sigs.cpp](https://github.com/karnalooch/MK1212Scripts/blob/3c2ae49265fe0abad140c7f8b1091b3c08d69ca5/native/twdll/src/attila/game_sigs.cpp#L135) and [game_api.h](https://github.com/karnalooch/MK1212Scripts/blob/3c2ae49265fe0abad140c7f8b1091b3c08d69ca5/native/twdll/src/attila/game_api.h) | No diplomacy/payment/accepted-deal/command-dispatch signature or callable API in the reviewed registry | There is no source-backed function pointer or command/event ID ready to expose for this purpose |
| [character.cpp](https://github.com/karnalooch/MK1212Scripts/blob/3c2ae49265fe0abad140c7f8b1091b3c08d69ca5/native/twdll/src/attila/character.cpp#L303) (`AddTrait`) | Comment describes native command queue use; implementation invokes resolved `CHARACTER::add_trait` | This is one specific engine call, not a generic custom-message queue or diplomacy replication proof |
| [model.cpp](https://github.com/karnalooch/MK1212Scripts/blob/3c2ae49265fe0abad140c7f8b1091b3c08d69ca5/native/twdll/src/attila/model.cpp#L21) and [main.cpp](https://github.com/karnalooch/MK1212Scripts/blob/3c2ae49265fe0abad140c7f8b1091b3c08d69ca5/native/twdll/src/main.cpp#L104) | The model module registers `DisbandUnits`; the module registry supplies no diplomacy or network transport API | Native mutation availability alone does not establish shared delivery |
| [campaign_var_table.inc](https://github.com/karnalooch/MK1212Scripts/blob/3c2ae49265fe0abad140c7f8b1091b3c08d69ca5/native/twdll/src/attila/campaign_var_table.inc#L667) | Contains the name `diplomacy_smallest_payment`, mapped to campaign-variable index 664 | A search anchor for payment validation. **664 is a variable index, not a discovered command or packet ID** |
| [campaign_model.cpp](https://github.com/karnalooch/MK1212Scripts/blob/3c2ae49265fe0abad140c7f8b1091b3c08d69ca5/native/twdll/src/attila/campaign_model.cpp) | Captures the model singleton at a load constructor | This is not an end-turn or per-command synchronization barrier |

## What the official script surface exposes

The [official Attila event reference](https://wiki.totalwar.com/w/Total_War:_ATTILA_KIT_-_Extra_Scripting_Guides) documents proposer/recipient and treaty flags for `PositiveDiplomaticEvent`; `DiplomaticOfferRejected` exposes participants. Its documented context does not contain a payment amount or deal identifier. Whether a money-only proposal emits the positive event, and whether that callback occurs before or after the debit/credit, require an observed run.

The same reference supplies faction/key/choice context for dilemma events and faction context for round/turn-phase events. These can support passive phase correlation. An event name alone does not establish a global sequence, an arbitrary payload channel or identical callbacks on both peers.

The [official command reference](https://wiki.totalwar.com/w/Total_War:_ATTILA_KIT_-_Campaign_Script_Interface) lists treasury modification, dilemma, custom dilemma, incident and message commands. It explicitly mentions command-queue arguments for some other commands. That does not document equivalent replication semantics for every command. The N2/N4 passive Lua probe records the documented event fields and marks missing amount/transaction identity as unavailable; it does not synthesize those fields from treasury differences.

## Dump availability and the narrow search that was completed

The available workspace was searched for native dumps and executable/disassembly artifacts; no original Attila/`empire.retail.dll` dump was found. Connected GitHub repository-name searches for `Attila` and `dump` exhausted their returned pages without locating a reference repository. The accessible `karnalooch` repository list did not expose a separate native RE/dump project. Targeted code searches in the historical twdll repository also did not supply this call graph.

This is an access/evidence boundary, not evidence that the engine lacks such a path. The twdll agent conventions mention a separate 64-bit DWARF reference and a 32-bit IDA project, but they do not provide either corpus or an accessible locator here. No offsets, class names, method signatures or numeric command IDs have been guessed to bridge that gap.

The remaining artifact requirement is the original research corpus or its exact repository/file locator, together with the reference binary's platform/build/hash. A 64-bit reference can supply names and relationships; its addresses, calling convention and layouts cannot be transplanted into the Windows 32-bit target. An exact current Windows `empire.retail.dll`/Attila identity is needed for final mapping.

## Next native pass: one payment path, three observation points

The next pass should follow one ordinary diplomatic payment from proposal acceptance through native model application to notification. Search terms below are target concepts, not claimed discovered native symbol names.

1. **Accepted proposal and command creation.** Locate payment terms, proposer/recipient, validation and the boundary where acceptance becomes an engine command. `diplomacy_smallest_payment` is a known string anchor for validation; the native context fields behind `PositiveDiplomaticEvent` are another semantic target. Determine whether the accepted command is enqueued or applied immediately, and where the same command is received on the other peer.
2. **Debit/credit application.** Follow the accepted-payment path to both faction balances and its success/rejection/rollback branches. Use the existing treasury field only as a corroborating source anchor after matching the exact binary. A general balance store is too broad to identify diplomacy on its own. Record whether the transaction has an engine operation ID, sequence, term index or other reusable identity.
3. **Notification dispatch.** Locate the payment-related script/event dispatch and compare its ordering with application. Determine whether that notification appears once, once per recipient, once per peer, or only for local UI. Perform the same correlation for the ordinary turn-phase event and a dilemma choice, without assuming all three use one dispatcher.

The desired result is an evidence-backed graph with exact function addresses/signatures, input structures, command ID if one exists, callers/callees and disassembly showing the order. “No ID found” and “callback is local-only” are useful outcomes. They must not be replaced with a fabricated shared token.

## Concrete passive hook proposal, pending that mapping

If the dump identifies an accepted-payment application function with a verified signature and calling convention, instrument that narrow function first. An entry/exit observation should capture:

- source and target faction keys, amount/term kind from the validated native input;
- any real command/deal identity, with its scope and lifetime documented;
- actual treasury values before/after, native result and observed dispatch phase;
- exact source/native build identity, capture schema and completeness/overflow flags.

If an ID or amount is wider than the exact integer range of Attila's Lua number, expose a canonical decimal/hex **string** from native code. A local diagnostic ordinal may correlate entry and exit on one peer, but must be labeled local until both-peer identity is proven. A pointer is never a shared identity.

The detour must preserve the original call exactly once and must not alter proposals, balances, commands or event delivery. It should copy bounded scalar data into a fixed-capacity native observation buffer, with no Lua calls, network sends or file replay from the hook. Drain that buffer from a known campaign callback through a proposed diagnostic API only after the native layout has been mapped. An overflow marks evidence incomplete; it does not block or retry the game operation.

Implementation ownership would follow the existing [campaign hook lifecycle](https://github.com/karnalooch/MK1212Scripts/blob/3c2ae49265fe0abad140c7f8b1091b3c08d69ca5/native/twdll/src/attila/campaign_hooks.cpp): unique signature resolution, typed fields/assertions, symmetric install/uninstall, and cleanup on the [final Lua state teardown](https://github.com/karnalooch/MK1212Scripts/blob/3c2ae49265fe0abad140c7f8b1091b3c08d69ca5/native/twdll/src/main.cpp#L39). Unresolved/multiple signature matches disable only that observer. No native hook is implemented or presented as currently callable in this tranche.

## Minimal final runtime sequence

Keep the user's requested consolidated testing after N4. In one paired session, collect an accepted money-only proposal, a rejected/cancelled offer, a second accepted transfer with the same participants and amount, one reverse-direction transfer, one ordinary turn notification, and one dilemma choice; preserve a save/load boundary. Include a non-diplomatic treasury change as the negative control for any amount inference. The exact amounts should satisfy the current game's normal UI validation.

Both peers' native observations and the Lua event probe must show whether the same accepted operation exists on both sides, its order relative to payment and notification, and its identity across repeated identical transactions and reload. A successful TCP echo, equal balances at one later moment, or a successful direct `SetTreasury` call cannot establish these properties.

**Decision until that evidence exists:** keep native diplomacy as the preferred focused research target for an engine-owned command channel. Keep N4 sidecar transport observational. Do not implement money-as-message encoding, a guessed engine RPC, or automatic balance correction from logs.
