-- One consolidated production-Lua regression run. Attila interfaces are fakes;
-- none of these assertions establish real two-PC event delivery semantics.
local function expect(value, message)
    if not value then error(message or "expectation failed", 2) end
end
local function equal(a, b, message)
    expect(a == b, (message or "values differ")..": "..tostring(a).." / "..tostring(b))
end
local function list(items)
    return {num_items = function() return #items end, item_at = function(_, i) return items[i + 1] end}
end
local function canonical(value)
    if type(value) ~= "table" then return type(value)..":"..tostring(value) end
    local keys, rows = {}, {}
    for key in pairs(value) do keys[#keys + 1] = key end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    for _, key in ipairs(keys) do rows[#rows + 1] = canonical(key).."="..canonical(value[key]) end
    return "{"..table.concat(rows, ";").."}"
end

local function peer(options)
    options = options or {}
    local p = {turn = 20, mutations = {}, messages = {}, diagnostics = {}, decisions = {},
        saves = {}, loads = {}, listeners = {}, listener_order = {}, effects = {}, draw_count = 0}
    local env = setmetatable({}, {__index = _G})
    env._G, p.env = env, env
    p.null = {is_null_interface = function() return true end}
    local function faction(name, human)
        local f = {_name = name, _human = human, _religion = "att_rel_chr_catholic", _alive = true, _characters = {}}
        function f:name() return self._name end
        function f:is_null_interface() return false end
        function f:is_human() return self._human end
        function f:state_religion() return self._religion end
        function f:at_war_with() return false end
        function f:has_home_region() return self._alive end
        function f:region_list() return list({1, 2, 3, 4, 5}) end
        function f:military_force_list() return list({}) end
        function f:character_list() return list(self._characters) end
        function f:faction_leader() return self._leader end
        return f
    end
    local function character(f, cqi, force_cqi)
        local force = {is_null_interface = function() return false end, command_queue_index = function() return force_cqi end}
        local c = {_traits = {}, _cqi = cqi}
        function c:cqi() return self._cqi end
        function c:is_null_interface() return false end
        function c:faction() return f end
        function c:has_military_force() return true end
        function c:military_force() return force end
        function c:logical_position_x() return 1 end
        function c:logical_position_y() return 1 end
        function c:character_type(kind) return kind == "general" end
        function c:age() return 40 end
        function c:has_trait(trait) return self._traits[trait] ~= nil end
        function c:trait_points(trait) return self._traits[trait] or 0 end
        function c:is_faction_leader() return f._leader == self end
        function c:offensive_ambush_battles_won() return 0 end
        function c:battles_won() return 0 end
        function c:battles_fought() return 0 end
        f._characters[#f._characters + 1] = c
        if not f._leader then f._leader = c end
        return c
    end
    p.a, p.b, p.pope = faction("mk_fact_a", true), faction("mk_fact_b", true), faction("mk_fact_papacy", false)
    p.ac, p.bc = character(p.a, 101, 1001), character(p.b, 102, 1002)
    p.extra = character(p.a, 201, 2001)
    character(p.pope, 103, 1003)
    p.factions = {mk_fact_a = p.a, mk_fact_b = p.b, mk_fact_papacy = p.pope}
    p.faction_items = {p.b, p.pope, p.a}
    p.attacker_result, p.defender_result = "decisive_victory", "decisive_defeat"
    p.has_attacker, p.has_defender = true, true
    local pending_battle = {
        has_attacker = function() return p.has_attacker end,
        has_defender = function() return p.has_defender end,
        attacker = function() expect(p.has_attacker, "unguarded attacker read") return p.ac end,
        defender = function() expect(p.has_defender, "unguarded defender read") return p.bc end,
        attacker_battle_result = function() return p.attacker_result end,
        defender_battle_result = function() return p.defender_result end
    }
    local world = {
        faction_by_key = function(_, key) return p.factions[key] or p.null end,
        faction_list = function() return list(p.faction_items) end
    }
    local model = {world = function() return world end, turn_number = function() return p.turn end,
        pending_battle = function() return pending_battle end,
        campaign_ai = function() return {strategic_stance_between_factions = function() return 0 end} end}
    local cm = {}
    env.cm = cm
    function cm:model() return model end
    function cm:is_new_game() return options.new_game == true end
    function cm:is_multiplayer() return options.multiplayer ~= false end
    function cm:get_local_faction() return options.local_faction or "mk_fact_a" end
    function cm:register_saving_game_callback(fn) p.saves[#p.saves + 1] = fn end
    function cm:register_loading_game_callback(fn) p.loads[#p.loads + 1] = fn end
    function cm:save_value(key, value, context) context[key] = value end
    function cm:load_value(key, default, context) if context[key] == nil then return default end return context[key] end
    function cm:add_listener(id, event, condition, fn)
        expect(p.listeners[id] == nil, "duplicate listener "..id)
        p.listeners[id] = {event = event, condition = condition, fn = fn}
        p.listener_order[#p.listener_order + 1] = id
    end
    function cm:remove_listener(id) p.listeners[id] = nil end
    function cm:apply_effect_bundle(key, actor, duration)
        p.effects[actor..":"..key] = true
        p.mutations[#p.mutations + 1] = {"apply", key, actor, duration}
        if p.mutation_hook then p.mutation_hook() end
    end
    function cm:remove_effect_bundle(key, actor)
        p.effects[actor..":"..key] = nil
        p.mutations[#p.mutations + 1] = {"remove", key, actor}
        if p.mutation_hook then p.mutation_hook() end
    end
    function cm:show_message_event(...)
        if p.ui_failure then error("injected UI failure") end
        p.messages[#p.messages + 1] = {...}
    end
    function cm:treasury_mod(actor, amount)
        p.treasury = (p.treasury or 0) + amount
        p.mutations[#p.mutations + 1] = {"treasury", actor, amount}
        if p.mutation_hook then p.mutation_hook() end
    end
    function cm:random_number(maximum, minimum)
        p.draw_count = p.draw_count + 1
        return (p.draw_count % 2 == 1) and (minimum or 1) or math.min(maximum, (minimum or 1) + 1)
    end
    function cm:add_time_trigger() error("Papal model path must not schedule timers") end
    function cm:trigger_dilemma(actor, key) p.mutations[#p.mutations + 1] = {"dilemma", actor, key} end
    function cm:pending_battle_cache_get_defender() return 102, 1002, p.b:name() end
    env.MKMP_Debug_Log = function(event, payload) p.diagnostics[#p.diagnostics + 1] = {event, payload} end
    env.MKMP_Debug_Register_State_Provider = function(name, getter) p.provider = getter end
    env.MKMP_SP_Parity_Enabled = function() return true end
    env.Register_Decision = function(...) end
    env.Add_Decision = function(key, actor) expect(actor, "decision must have an owner") end
    for _, method in ipairs({"Enable_Decision", "Disable_Decision", "Remove_Decision"}) do
        env[method] = function(key, actor) expect(actor, "decision must have an owner") p.decisions[#p.decisions + 1] = {method, key, actor} end
    end
    env.FACTIONS_DFN_LEVEL, env.POPE_CONTROLLING_FACTION = {}, "mk_fact_papacy"
    env.SackExploitCheck_Pope = function() return true end
    env.Increase_Character_Nickname_Stat = function() end
    local loaded = {}
    local function load(path)
        local chunk = assert(loadfile("campaigns/main_attila/"..path..".lua"))
        setfenv(chunk, env)
        return chunk()
    end
    env.require = function(path)
        if loaded[path] == nil then loaded[path] = load(path) or true end
        return loaded[path]
    end
    env.require("common/mk1212_common")
    env.require("mechanics/pope/mechanics_pope_favour")
    p.papal_save, p.papal_load = p.saves[#p.saves], p.loads[#p.loads]
    env.FACTION_POPE_FAVOUR = {mk_fact_a = 5, mk_fact_b = 5}
    p.roma = {name = function() return "att_reg_italia_roma" end, is_null_interface = function() return false end,
        owning_faction = function() return p.pope end}
    env.FindClosestRegion = function() return p.roma end
    function p:context(c) return {character = function() return c or self.ac end} end
    function p:save() local state = {} self.papal_save(state) return state end
    function p:load(state) self.papal_load(state) end
    function p:init() self.env.Add_Pope_Favour_Listeners() end
    function p:nicknames(reverse)
        env.require("nicknames/main")
        p.nickname_save, p.nickname_load = p.saves[#p.saves], p.loads[#p.loads]
        env.NICKNAMES = {a_name = {priority = 1}, z_name = {priority = 1}}
        env.TRAITS_TO_NICKNAMES = {}
        if reverse then env.TRAITS_TO_NICKNAMES.z_trait = "z_name" env.TRAITS_TO_NICKNAMES.a_trait = "a_name"
        else env.TRAITS_TO_NICKNAMES.a_trait = "a_name" env.TRAITS_TO_NICKNAMES.z_trait = "z_name" end
        env.HISTORICAL_CHARACTERS_TO_NICKNAMES = {}
        p.ac._traits, p.extra._traits = {a_trait = 2, z_trait = 2}, {a_trait = 2, z_trait = 2}
        p.a._characters = reverse and {p.extra, p.ac} or {p.ac, p.extra}
        env.Add_Nicknames_Tracking_Listeners()
    end
    return p
end

local function excommunication_regressions()
    local p = peer()
    p:init()
    p.env.Add_Pope_Favour_Listeners() -- listener ownership is idempotent.
    p.env.FACTION_EXCOMMUNICATED.mk_fact_a = true
    p.env.FACTION_POPE_FAVOUR.mk_fact_a = 0
    expect(p.env.Remove_Excommunication(p:context()), "character-context automatic removal")
    equal(p.env.FACTION_POPE_FAVOUR.mk_fact_a, 2)
    expect(p.effects["mk_fact_a:mk_bundle_pope_favour_2"], "effect bundle refreshed")
    equal(p.messages[#p.messages][3], "factions_screen_name_mk_fact_a", "missing dynamic rank fallback")
    local count = #p.mutations
    expect(not p.env.Remove_Excommunication(p:context()), "duplicate removal is a no-op")
    equal(#p.mutations, count)
    p.env.FACTION_EXCOMMUNICATED.mk_fact_a = true
    p.env.FACTIONS_DFN_LEVEL.mk_fact_a = 2
    expect(p.env.Remove_Excommunication_Manual("mk_fact_a"))
    equal(p.messages[#p.messages][3], "campaign_localised_strings_string_mk_fact_a_lvl2", "rank is a table lookup")
    p.env.FACTION_EXCOMMUNICATED.mk_fact_a = true
    p.ui_failure = true
    expect(p.env.Remove_Excommunication_Manual("mk_fact_a"), "UI failure must not abort model steps")
    expect(p.effects["mk_fact_a:mk_bundle_pope_favour_2"])
    expect(not p.env.Remove_Excommunication_Manual("missing"), "missing faction")

    local rome = peer()
    rome:init()
    rome.a._religion = "mk_rel_sunni_islam"
    rome.ui_failure = true
    rome.env.Check_If_Catholic_Attacked(rome:context(), "OCCUPY")
    expect(rome.effects["mk_fact_b:mk_bundle_christian_dejection"], "all Catholic targets must receive the Rome effect")
    expect(rome.effects["mk_fact_papacy:mk_bundle_christian_dejection"])
    equal(rome.env.PAPAL_FAVOUR_SYSTEM_ACTIVE, false, "non-Catholic Rome transition must finish")
end

local function battle_regressions()
    local p = peer()
    p:init()
    p.env.PendingBattle_Pope_Favour({})
    p.env.PendingBattle_Pope_Favour({})
    equal(p.env.MKMP_Papal_Get_State().postbattle.ordinal, 1, "duplicate pending callback")
    expect(p.env.CharacterPostBattle_Favour(p:context(), "RELEASE"), "decision before character-completed")
    p.env.CharacterCompletedBattle_Pope_Favour(p:context())
    p.env.CharacterCompletedBattle_Pope_Favour(p:context())
    equal(p.env.FACTION_POPE_FAVOUR.mk_fact_a, 6)
    local count = #p.mutations
    p.env.TimeTrigger_Pope({string = "Postbattle_Decision_Pope"})
    expect(not p.env.CharacterPostBattle_Favour(p:context(p.extra), "RELEASE"), "same faction reinforcing general cannot duplicate")
    expect(not p.env.CharacterPostBattle_Favour(p:context(), "SLAUGHTER"), "conflicting choice cannot reopen claim")
    equal(#p.mutations, count)
    expect(p.env.CharacterPostBattle_Favour(p:context(p.bc), "SLAUGHTER"), "second human faction has its own claim")
    equal(p.env.FACTION_POPE_FAVOUR.mk_fact_b, 4)
    local snapshot = p.env.MKMP_Papal_Get_State()
    snapshot.favour.mk_fact_a = 99
    snapshot.postbattle.current.decisions.mk_fact_a.kind = "ENSLAVE"
    equal(p.env.FACTION_POPE_FAVOUR.mk_fact_a, 6, "snapshot must not expose mutable state")
    equal(p.env.MKMP_Papal_Get_State().postbattle.current.decisions.mk_fact_a.kind, "RELEASE")
    local saved = p:save()
    local reloaded = peer()
    reloaded:load(saved)
    expect(not reloaded.env.CharacterPostBattle_Favour(reloaded:context(), "RELEASE"), "save/load must preserve claimed decision")
    equal(#reloaded.mutations, 0)
    p.env.PendingBattle_Pope_Favour({}) -- a second observed battle with the same actors in the same round.
    equal(p.env.MKMP_Papal_Get_State().postbattle.ordinal, 2)
    expect(p.env.CharacterPostBattle_Favour(p:context(), "RELEASE"))
    equal(p.env.FACTION_POPE_FAVOUR.mk_fact_a, 7)
    p.turn = p.turn + 1
    expect(not p.env.CharacterPostBattle_Favour(p:context(p.bc), "RELEASE"), "stale round is not a valid phase")

    local missing = peer()
    missing.env.CharacterCompletedBattle_Pope_Favour(missing:context())
    expect(not missing.env.CharacterPostBattle_Favour(missing:context(), "RELEASE"), "no invented battle ID")
    missing.env.PendingBattle_Pope_Favour({})
    missing.has_defender = false
    missing.env.CharacterCompletedBattle_Pope_Favour(missing:context())
    expect(not missing.env.CharacterPostBattle_Favour(missing:context(), "RELEASE"), "missing pending participant")
    equal(missing.env.FACTION_POPE_FAVOUR.mk_fact_a, 5)
    missing.env.CharacterCompletedBattle_Pope_Favour({})

    local partial = peer()
    partial.env.PendingBattle_Pope_Favour({})
    partial.mutation_hook = function() error("injected partial engine command failure") end
    expect(not partial.env.CharacterPostBattle_Favour(partial:context(), "RELEASE"))
    equal(partial.env.MKMP_Papal_Get_State().postbattle.current.decisions.mk_fact_a.status, "unknown")
    local after_error = peer()
    after_error:load(partial:save())
    expect(not after_error.env.CharacterPostBattle_Favour(after_error:context(), "RELEASE"), "unknown partial effect is not retried after load")
    equal(#after_error.mutations, 0)
    local unknown = p:save()
    unknown.MKMP_PAPAL_BATTLE_STATE = "MKMP_PAPAL_BATTLE_V99;opaque;"
    after_error:load(unknown)
    expect(not after_error.env.MKMP_Papal_Get_State().complete)
    after_error.env.PendingBattle_Pope_Favour({})
    equal(after_error:save().MKMP_PAPAL_BATTLE_STATE, unknown.MKMP_PAPAL_BATTLE_STATE, "future schema is preserved")
end

local function loan_regressions()
    local p = peer()
    for favour, amount in pairs({[8] = 5000, [9] = 7500, [10] = 10000}) do
        p.env.FACTION_POPE_FAVOUR.mk_fact_a = favour
        local valid, _, expected = p.env.MKMP_Papal_Validate_Loan("mk_fact_a")
        expect(valid)
        equal(expected, amount)
    end
    p.env.FACTION_POPE_FAVOUR.mk_fact_a = 9
    p.ui_failure = true
    expect(p.env.Decision_Pope_Money("mk_fact_a"))
    equal(p.treasury, 7500)
    equal(p.env.FACTION_POPE_FAVOUR.mk_fact_a, 6)
    expect(not p.env.Decision_Pope_Money("mk_fact_a"), "threshold revalidated before any command")
    equal(p.treasury, 7500)
    p.env.FACTION_POPE_FAVOUR.mk_fact_a = 9
    p.env.FACTION_EXCOMMUNICATED.mk_fact_a = true
    expect(not p.env.MKMP_Papal_Validate_Loan("mk_fact_a"))
    p.env.FACTION_EXCOMMUNICATED.mk_fact_a = false
    p.a._alive = false
    expect(not p.env.MKMP_Papal_Validate_Loan("mk_fact_a"))
    expect(not p.env.MKMP_Papal_Validate_Loan("missing"))
end

local function nickname_regressions()
    local host, client = peer({local_faction = "mk_fact_a"}), peer({local_faction = "mk_fact_b"})
    host:nicknames(false)
    client:nicknames(true)
    for _, p in ipairs({host, client}) do
        p.env.Add_Nicknames_Tracking_Listeners()
        p.env.FactionTurnStart_Nicknames({faction = function() return p.a end})
        p.env.FactionTurnStart_Nicknames({faction = function() return p.a end})
        equal(p.draw_count, 4, "one draw per eligible trait; duplicate faction callback adds none")
        equal(p.env.CHARACTERS_TO_NICKNAMES["101"], "a_name", "stable trait tie precedence")
        equal(p.env.CHARACTERS_TO_NICKNAME_STATS["101"].turns_without_revolt, 1)
    end
    equal(canonical(host.env.CHARACTERS_TO_NICKNAMES), canonical(client.env.CHARACTERS_TO_NICKNAMES))
    equal(canonical(host.env.CHARACTERS_TO_NICKNAME_STATS), canonical(client.env.CHARACTERS_TO_NICKNAME_STATS))
    equal(host.env.MK1212_Random_Int(1, 10, "after_nicknames"), client.env.MK1212_Random_Int(1, 10, "after_nicknames"))
    local saved = {}
    host.nickname_save(saved)
    local loaded = peer()
    loaded:nicknames(true)
    loaded.nickname_load(saved)
    loaded.env.FactionTurnStart_Nicknames({faction = function() return loaded.a end})
    equal(loaded.draw_count, 0, "reload preserves completed nickname phase")
    equal(loaded.env.CHARACTERS_TO_NICKNAME_STATS["101"].turns_without_revolt, 1)
    saved.MKMP_NICKNAME_TURNS = "MKMP_NICKNAME_TURNS_V99;opaque;"
    loaded.nickname_load(saved)
    loaded.turn = loaded.turn + 1
    loaded.env.FactionTurnStart_Nicknames({faction = function() return loaded.a end})
    equal(loaded.draw_count, 0, "future phase schema fails closed")
    local preserved = {}
    loaded.nickname_save(preserved)
    equal(preserved.MKMP_NICKNAME_TURNS, saved.MKMP_NICKNAME_TURNS)

    local fresh = peer({new_game = true})
    fresh:nicknames(false)
    equal(fresh.env.CHARACTERS_TO_NICKNAME_STATS["101"].turns_without_revolt, 1, "new-game historical pass retained")
    fresh.env.FactionTurnStart_Nicknames({faction = function() return fresh.a end})
    equal(fresh.env.CHARACTERS_TO_NICKNAME_STATS["101"].turns_without_revolt, 2, "first turn remains a distinct upstream pass")
end

excommunication_regressions()
battle_regressions()
loan_regressions()
nickname_regressions()
print("PASS production Lua Papal and nickname regressions")
