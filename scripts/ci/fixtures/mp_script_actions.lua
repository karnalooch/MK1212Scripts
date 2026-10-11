-- Runs the actual production modules in isolated Lua 5.1 environments. Only
-- Attila's interface objects/events are faked; gameplay code is not copied.
local function expect(value, message)
    if not value then error(message or "expectation failed", 2) end
end

local function same(a, b, label)
    expect(a == b, (label or "values differ")..": "..tostring(a).." / "..tostring(b))
end

local function list(items)
    return {
        num_items = function() return #items end,
        item_at = function(_, index) return items[index + 1] end
    }
end

local function canonical(value)
    if type(value) ~= "table" then return type(value)..":"..tostring(value) end
    local keys, result = {}, {}
    for key in pairs(value) do keys[#keys + 1] = key end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    for _, key in ipairs(keys) do
        result[#result + 1] = canonical(key).."="..canonical(value[key])
    end
    return "{"..table.concat(result, ";").."}"
end

local function peer(options)
    options = options or {}
    local p = {
        mutations = {}, messages = {}, diagnostics = {}, save_callbacks = {},
        load_callbacks = {}, listeners = {}, listener_order = {}, effects = {},
        turn = options.turn or 10, difficulty = options.difficulty or -2,
        new_game = options.new_game == true, local_faction = options.local_faction or "mk_fact_a",
        null = {is_null_interface = function() return true end}
    }
    local env = setmetatable({}, {__index = _G})
    env._G = env
    p.env = env
    local function faction(name, human, religion)
        local f = {_name = name, _human = human, _religion = religion, _war = true}
        function f:name() return self._name end
        function f:is_null_interface() return false end
        function f:is_human() return self._human end
        function f:state_religion() return self._religion end
        function f:at_war() return self._war end
        function f:is_horde() return false end
        function f:military_force_list() return list({}) end
        return f
    end
    p.a = faction("mk_fact_a", true, "att_rel_chr_catholic")
    p.b = faction("mk_fact_b", true, "mk_rel_shia_islam")
    p.rebels = faction("rebels", false, "att_rel_other")
    p.factions = {mk_fact_a = p.a, mk_fact_b = p.b, rebels = p.rebels}
    p.faction_items = {p.a, p.b, p.rebels}
    p.mecca_owner = options.razed and p.rebels or p.a
    p.mecca = {
        name = function() return "att_reg_arabia_magna_yathrib" end,
        is_null_interface = function() return false end,
        owning_faction = function() return p.mecca_owner end
    }
    local region_manager = {region_by_key = function() return p.mecca end}
    local world = {
        faction_by_key = function(_, key)
            expect(type(key) == "string", "faction lookup must use a stable key")
            return p.factions[key] or p.null
        end,
        faction_list = function() return list(p.faction_items) end,
        region_manager = function() return region_manager end
    }
    p.attacker_result, p.defender_result = "decisive_victory", "decisive_defeat"
    p.attacker_name, p.defender_name = "mk_fact_a", "mk_fact_b"
    local model = {
        world = function() return world end,
        turn_number = function() return p.turn end,
        difficulty_level = function() return p.difficulty end,
        pending_battle = function()
            return {
                attacker_battle_result = function() return p.attacker_result end,
                defender_battle_result = function() return p.defender_result end
            }
        end
    }
    local cm = {}
    env.cm = cm
    function cm:model() return model end
    function cm:is_multiplayer() return options.multiplayer ~= false end
    function cm:is_new_game() return p.new_game end
    function cm:get_local_faction() return p.local_faction end
    function cm:register_saving_game_callback(fn) p.save_callbacks[#p.save_callbacks + 1] = fn end
    function cm:register_loading_game_callback(fn) p.load_callbacks[#p.load_callbacks + 1] = fn end
    function cm:save_value(key, value, context) context[key] = value end
    function cm:load_value(key, default, context)
        if context[key] == nil then return default end
        return context[key]
    end
    function cm:add_listener(id, event, condition, callback, persistent)
        expect(not p.listeners[id], "duplicate listener ID "..id)
        p.listeners[id] = {event = event, condition = condition, callback = callback}
        p.listener_order[#p.listener_order + 1] = id
    end
    function cm:apply_effect_bundle(key, name, duration)
        p.mutations[#p.mutations + 1] = {"apply", key, name, duration}
        p.effects[name.."|"..key] = true
        if p.mutation_hook then p.mutation_hook() end
    end
    function cm:remove_effect_bundle(key, name)
        p.mutations[#p.mutations + 1] = {"remove", key, name}
        p.effects[name.."|"..key] = nil
        if p.mutation_hook then p.mutation_hook() end
    end
    function cm:show_message_event(...) p.messages[#p.messages + 1] = {...} end
    function cm:pending_battle_cache_get_attacker() return 101, 1001, p.attacker_name end
    function cm:pending_battle_cache_get_defender() return 102, 1002, p.defender_name end
    env.MKMP_Debug_Log = function(event, data)
        p.diagnostics[#p.diagnostics + 1] = {event, data}
    end
    local function load(path)
        local code = assert(loadfile("campaigns/main_attila/"..path))
        setfenv(code, env)
        return code()
    end
    local loaded = {}
    env.require = function(name)
        if loaded[name] == nil then loaded[name] = load(name..".lua") or true end
        return loaded[name]
    end
    load("common/mk1212_common.lua")
    load("mechanics/mechanics_war_weariness.lua")
    p.ww_save = p.save_callbacks[#p.save_callbacks]
    p.ww_load = p.load_callbacks[#p.load_callbacks]
    load("mechanics/islam/mechanics_islam_mecca.lua")
    p.mecca_save = p.save_callbacks[#p.save_callbacks]
    p.mecca_load = p.load_callbacks[#p.load_callbacks]
    env.FindClosestRegion = function() return p.closest_region or p.mecca end
    env.SackExploitCheck_Pope = function() return true end
    p.character = {
        is_null_interface = function() return false end,
        faction = function() return p.a end,
        logical_position_x = function() return 0 end,
        logical_position_y = function() return 0 end
    }
    p.character_context = {character = function() return p.character end}
    function p:context(f) return {faction = function() return f end} end
    function p:emit(event, context)
        for _, id in ipairs(self.listener_order) do
            local listener = self.listeners[id]
            if listener.event == event and (listener.condition == true or listener.condition(context)) then
                listener.callback(context)
            end
        end
    end
    function p:clear_output()
        self.mutations, self.messages, self.diagnostics = {}, {}, {}
    end
    function p:seed_ww()
        self.env.PLAYER_WAR_WEARINESS = {mk_fact_a = 10, mk_fact_b = 10}
        self.env.PLAYER_WAR_WEARINESS_TURNS_AT_WAR = {mk_fact_a = 4, mk_fact_b = 4}
    end
    function p:save()
        local storage = {}
        self.ww_save(storage)
        self.mecca_save(storage)
        return storage
    end
    function p:restore(storage)
        self.ww_load(storage)
        self.mecca_load(storage)
    end
    return p
end

local tests = {}

function tests.initializer_once()
    for _, multiplayer in ipairs({false, true}) do
        local p = peer({new_game = true, multiplayer = multiplayer})
        p.env.Add_War_Weariness_Listeners()
        local expected_rate = multiplayer and 1 or 2
        same(p.env.TURN_AT_WAR, expected_rate, "difficulty applied once")
        local count, messages = #p.mutations, #p.messages
        p.env.PLAYER_WAR_WEARINESS.mk_fact_a = 27
        p.env.Add_War_Weariness_Listeners()
        same(p.env.TURN_AT_WAR, expected_rate, "initializer must not compound difficulty")
        same(p.env.PLAYER_WAR_WEARINESS.mk_fact_a, 27, "initializer must not reset gameplay")
        same(#p.mutations, count, "initializer repeated model commands")
        same(#p.messages, messages, "initializer repeated popup")
        same(#p.listener_order, 3, "listener ownership")
    end
end

function tests.local_difficulty_is_not_shared_authority()
    local host, client = peer({difficulty = 1}), peer({difficulty = -3})
    for _, p in ipairs({host, client}) do
        p.env.Add_War_Weariness_Listeners()
        p:seed_ww()
        p.env.FactionTurnStart_WW(p:context(p.a))
        same(p.env.PLAYER_WAR_WEARINESS.mk_fact_a, 11, "MP uses the content baseline")
    end
    same(canonical(host.mutations), canonical(client.mutations), "local difficulty cannot diverge peers")
    for _, case in ipairs({{1, 10.5}, {-3, 12}}) do
        local p = peer({multiplayer = false, difficulty = case[1]})
        p.env.Add_War_Weariness_Listeners()
        p:seed_ww()
        p.env.FactionTurnStart_WW(p:context(p.a))
        same(p.env.PLAYER_WAR_WEARINESS.mk_fact_a, case[2], "SP difficulty remains effective")
    end
end

function tests.dual_peer_turns_and_save()
    local host = peer({local_faction = "mk_fact_a"})
    local client = peer({local_faction = "mk_fact_b"})
    for _, p in ipairs({host, client}) do
        p.env.Add_War_Weariness_Listeners()
        p:seed_ww()
        p.b._war = false
    end
    host.env.Add_War_Weariness_Listeners()
    -- Only HOST receives redundant callbacks. Peer-local UI selections differ.
    host.env.REGION_SELECTED, client.env.REGION_SELECTED = "local_a", "local_b"
    host:emit("FactionTurnStart", host:context(host.a))
    host:emit("FactionTurnStart", host:context(host.a))
    host:emit("FactionTurnStart", host:context(host.b))
    host:emit("FactionTurnStart", host:context(host.b))
    client:emit("FactionTurnStart", client:context(client.a))
    client:emit("FactionTurnStart", client:context(client.b))
    same(canonical(host.mutations), canonical(client.mutations), "peer turn mutation parity")
    same(host.env.PLAYER_WAR_WEARINESS.mk_fact_a, 11, "war delta")
    same(host.env.PLAYER_WAR_WEARINESS.mk_fact_b, 7, "peace delta")
    local saved_host, saved_client = host:save(), client:save()
    same(canonical(saved_host), canonical(saved_client), "canonical persisted peer state")
    same(saved_host.MKMP_WW_TURN_SCHEMA, 1, "turn ledger version")
    same(saved_host.MKMP_WW_LAST_TURN, "mk_fact_a,10,;mk_fact_b,10,;", "bounded per-faction ledger")
    local restored_host, restored_client = peer(), peer({local_faction = "mk_fact_b"})
    restored_host:restore(saved_host)
    restored_client:restore(saved_client)
    restored_host.env.FactionTurnStart_WW(restored_host:context(restored_host.a))
    same(#restored_host.mutations, 0, "restored completed phase must not replay")
    for _, p in ipairs({restored_host, restored_client}) do
        p.env.Add_War_Weariness_Listeners()
        p.turn = 11
        p:emit("FactionTurnStart", p:context(p.a))
        same(p.env.PLAYER_WAR_WEARINESS.mk_fact_a, 12, "next turn still executes")
    end
    same(canonical(restored_host.mutations), canonical(restored_client.mutations), "peer post-load parity")
end

function tests.old_save_migration()
    local p = peer()
    p:restore({
        PLAYER_WAR_WEARINESS = "mk_fact_a,10,;",
        PLAYER_WAR_WEARINESS_TURNS_AT_WAR = "mk_fact_a,4,;"
    })
    same(#p.mutations, 0, "loading an old save does not replay any turn")
    p.env.FactionTurnStart_WW(p:context(p.a))
    same(p.env.PLAYER_WAR_WEARINESS.mk_fact_a, 11, "old save retains prior gameplay state")
    local count = #p.mutations
    p.env.FactionTurnStart_WW(p:context(p.a))
    same(#p.mutations, count, "migrated save records completion")
    same(p:save().MKMP_WW_TURN_SCHEMA, 1, "migration writes new isolated metadata only")
end

function tests.reentry_and_partial_failure()
    local p = peer()
    p:seed_ww()
    local nested = 0
    p.mutation_hook = function()
        nested = nested + 1
        p.env.FactionTurnStart_WW(p:context(p.a))
    end
    p.env.FactionTurnStart_WW(p:context(p.a))
    same(nested, 102, "nested callback does not emit another bundle sweep")
    same(p.env.PLAYER_WAR_WEARINESS.mk_fact_a, 11, "reentrant callback is not additive")
    local failed = peer()
    failed:seed_ww()
    failed.mutation_hook = function() error("injected partial model failure") end
    local ok = pcall(failed.env.FactionTurnStart_WW, failed:context(failed.a))
    expect(not ok, "fixture must actually inject a mutation failure")
    same(failed.env.PLAYER_WAR_WEARINESS.mk_fact_a, 11, "first additive state change occurred")
    failed.mutation_hook = nil
    failed.env.FactionTurnStart_WW(failed:context(failed.a))
    same(#failed.mutations, 1, "partially applied work is not blindly retried")
    local restored = peer()
    restored:restore(failed:save())
    restored.env.FactionTurnStart_WW(restored:context(restored.a))
    same(#restored.mutations, 0, "partial operation claim survives reload")
end

function tests.invalid_turn_metadata()
    local cases = {
        {2, "future-schema-metadata"},
        {1, "mk_fact_a,10,;mk_fact_a,10,;"},
        {1, "mk_fact_a,11,;"},
        {1, "mk_fact_a,-1,;"},
        {1, "mk_fact_a,1.5,;"},
        {1, "mk_fact_absent,10,;"},
        {1, "mk_fact_a,10,;trailing-garbage"},
        {1, false},
        {1, string.rep("x", 262145)}
    }
    for _, case in ipairs(cases) do
        local p = peer()
        p:restore({
            MKMP_WW_TURN_SCHEMA = case[1], MKMP_WW_LAST_TURN = case[2],
            PLAYER_WAR_WEARINESS = "mk_fact_a,10,;",
            PLAYER_WAR_WEARINESS_TURNS_AT_WAR = "mk_fact_a,4,;"
        })
        p.env.FactionTurnStart_WW(p:context(p.a))
        same(#p.mutations, 0, "invalid metadata must not guess phase completion")
        same(p.env.PLAYER_WAR_WEARINESS.mk_fact_a, 10, "invalid metadata retains gameplay values")
        local saved = p:save()
        same(saved.MKMP_WW_TURN_SCHEMA, case[1], "retain unknown schema")
        same(saved.MKMP_WW_LAST_TURN, case[2], "retain opaque invalid payload")
    end
end

function tests.battle_result_validation()
    local p = peer()
    p:seed_ww()
    p.defender_result = "unknown-result"
    p.env.BattleCompleted_WW({})
    same(#p.mutations, 0, "unknown defender must not leave an attacker-only update")
    same(p.env.PLAYER_WAR_WEARINESS.mk_fact_a, 10, "unknown result leaves shared state intact")
    p.defender_result, p.defender_name = "decisive_defeat", nil
    p.env.BattleCompleted_WW({})
    same(#p.mutations, 0, "missing participant key fails before mutation")
    p.defender_name = "mk_fact_b"
    p.env.BattleCompleted_WW({})
    same(p.env.PLAYER_WAR_WEARINESS.mk_fact_a, 5, "ordinary victory delta preserved")
    same(p.env.PLAYER_WAR_WEARINESS.mk_fact_b, 18, "ordinary defeat delta preserved")
    p.env.FactionTurnStart_WW({faction = function() return p.null end})
    p.env.MKMP_Debug_Log = function() error("logger unavailable") end
    p.env.FactionTurnStart_WW(p:context(p.a))
    same(p.env.PLAYER_WAR_WEARINESS.mk_fact_a, 6, "logging failure does not cancel gameplay")
end

function tests.mecca_listener_and_raze_persistence()
    local p = peer()
    local population_calls = 0
    p.env.cm:add_listener("CharacterPerformsOccupationDecisionRaze_Population",
        "CharacterPerformsOccupationDecisionRaze", true, function() population_calls = population_calls + 1 end, true)
    p.env.Add_Islam_Mecca_Listeners()
    p.env.Add_Islam_Mecca_Listeners()
    same(#p.listener_order, 7, "Mecca has six uniquely owned listeners")
    p.env.MECCA_OCCUPIED = true
    p:emit("CharacterPerformsOccupationDecisionRaze", p.character_context)
    local mutations, messages = #p.mutations, #p.messages
    expect(mutations > 0, "raze fixture must execute real effects")
    expect(messages > 0, "initial raze emits its story message")
    p:emit("CharacterPerformsOccupationDecisionRaze", p.character_context)
    same(#p.mutations, mutations, "duplicate raze is not applied twice")
    same(#p.messages, messages, "duplicate raze does not repeat popup")
    same(population_calls, 2, "Mecca did not replace the Population listener")
    local storage = p:save()
    same(storage.MECCA_RAZER, "mk_fact_a", "razer persists as faction key")
    local restored = peer({razed = true})
    restored:restore(storage)
    restored.env.Check_Mecca_Owner()
    expect(restored.effects["mk_fact_a|mk_bundle_islams_outcry"], "restore resolves saved actor before effect")
    expect(restored.effects["mk_fact_b|mk_bundle_islamic_dejection"], "destroyed-Mecca consequence survives reload")
    same(#restored.messages, 0, "refresh is not another destruction event")
    -- A real recapture resets the destruction claim, allowing a later new raze.
    restored.mecca_owner = restored.b
    restored.env.Check_Mecca_Owner()
    same(restored.env.MECCA_RAZER, "nil", "recapture resets prior destruction actor")
    local before = #restored.mutations
    restored.env.CharacterPerformsOccupationDecision_Islam_Mecca(restored.character_context, "RAZE")
    expect(#restored.mutations > before, "a distinct later destruction still executes")
end

function tests.mecca_invalid_entities()
    local p = peer({razed = true})
    p.env.MECCA_RAZER = "missing-faction"
    p.env.Check_Mecca_Owner()
    same(#p.mutations, 0, "missing saved actor has no guessed replacement")
    p.character = p.null
    p.env.CharacterPerformsOccupationDecision_Islam_Mecca(p.character_context, "RAZE")
    same(#p.mutations, 0, "invalid event character fails closed")
    p.mecca = p.null
    p.env.Check_Mecca_Owner()
    same(#p.mutations, 0, "invalid Mecca region fails closed")
end

local selected = arg[1]
expect(tests[selected], "unknown fixture scenario "..tostring(selected))
tests[selected]()
print("PASS production Lua script actions: "..selected)
