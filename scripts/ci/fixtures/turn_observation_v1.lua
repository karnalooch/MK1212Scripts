-- Isolated Lua 5.1-compatible runtime fixture: no Attila instance or native DLL.
local source = assert(arg[1], "expected runtime file");
local chunk = assert(loadfile(source));
chunk();
local observe = MKMP_Runtime_Get_Turn_Observation_V1;
local event = MKMP_Runtime_Get_Turn_Observation_Event_V1;
local function eq(actual, expected, note)
    if actual ~= expected then error((note or "mismatch")..": "..tostring(actual).." != "..tostring(expected)); end
end

cm = nil;
local missing = observe();
eq(missing.available, false, "missing cm");
eq(missing.reason, "model_unavailable");
eq(missing.active_faction, "unknown");
eq(missing.phase, "unknown");

cm = {model = function() error("unavailable model") end};
eq(observe().available, false, "throwing model");

cm = {model = function() return {turn_number = function() error("failed") end} end};
eq(observe().reason, "turn_number_unavailable");

cm = {model = function() return {turn_number = function() return -1 end} end};
eq(observe().turn_number, "unknown", "negative turn");

cm = {model = function() return {turn_number = function() return 3.5 end} end};
eq(observe().turn_number, "unknown", "fractional turn");

cm = {
    model = function() return {turn_number = function() return 42 end} end,
    is_multiplayer = function() return false end
};
local sp = observe();
eq(sp.available, true, "SP");
eq(sp.turn_number, 42);
eq(sp.multiplayer, false);
eq(sp.active_faction, "unknown", "SP cannot infer active turn owner");
eq(sp.local_faction, "unknown");
eq(sp.input_enabled, "unknown");

cm.is_multiplayer = function() return true end;
local mp = event("FactionTurnStart");
eq(mp.multiplayer, true, "MP");
eq(mp.event, "FactionTurnStart");
eq(mp.phase, "unknown", "callback does not establish phase");
eq(mp.event_source, "lua_callback_label_unverified");

cm.model = function() return {turn_number = function() return 43 end} end;
eq(observe().turn_number, 43, "next turn");
eq(sp.turn_number, 42, "snapshot immutability");
eq(observe().turn_number, observe().turn_number, "repeat callback");

cm.model = function() return {turn_number = function() return 1 end} end;
eq(observe().turn_number, 1, "save/load recreation resets observed turn");
eq(event(123).event, "unknown", "invalid event");
print("TurnObservationV1 Lua fixtures: PASS");

-- V2 Attila surface mocked independently of WH APIs.
FACTION_TURN = "mk_fact_poland";
local function makef(key, human)
    return { name = function() return key end, is_human = function() return human end };
end
local factions = {makef("mk_fact_poland", true), makef("mk_fact_france", false)};
cm = {
    model = function() return {
        turn_number = function() return 2 end,
        is_player_turn = function() return true end,
        faction_is_local = function(self, key) return key == "mk_fact_poland" end,
        world = function() return {faction_list = function() return {
            num_items = function() return 2 end,
            item_at = function(self, i) return factions[i+1] end
        } end} end
    } end,
    is_multiplayer = function() return false end
};
local v2 = MKMP_Runtime_Get_Turn_Observation_V2();
eq(v2.schema, 2);
eq(v2.player_turn, true);
eq(v2.local_factions_state, "complete");
eq(v2.human_factions_state, "complete");
eq(v2.local_factions[1], "mk_fact_poland");
eq(v2.human_factions[1], "mk_fact_poland");
eq(v2.script_faction_turn, "mk_fact_poland");
eq(v2.active_faction, "unknown");
eq(v2.faction_count_parity, "not_comparable");
cm.model = function() return {turn_number = function() return 4 end, world = function() error("no world") end} end;
local unavailable = MKMP_Runtime_Get_Turn_Observation_V2();
eq(unavailable.active_faction, "unknown");
eq(unavailable.local_factions_state, "unknown");
eq(unavailable.player_turn, "unknown");
print("TurnObservationV2 Lua fixtures: PASS");
