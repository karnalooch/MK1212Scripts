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
