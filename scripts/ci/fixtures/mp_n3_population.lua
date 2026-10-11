-- Production action/accounting modules with fake engine interfaces. This fixture
-- does not certify native unit identity, event replication or MP command phases.
local function expect(value, label) if not value then error(label or "expectation failed", 2) end end
local function equal(a, b, label) expect(a == b, (label or "values differ")..": "..tostring(a).." / "..tostring(b)) end
local function list(items) return {num_items = function() return #items end, item_at = function(_, i) return items[i + 1] end} end
local function copy(value)
    if type(value) ~= "table" then return value end
    local out = {} for key, item in pairs(value) do out[key] = copy(item) end return out
end
local function canonical(value)
    if type(value) ~= "table" then return type(value)..":"..tostring(value) end
    local keys, rows = {}, {} for key in pairs(value) do keys[#keys + 1] = key end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    for _, key in ipairs(keys) do rows[#rows + 1] = canonical(key).."="..canonical(value[key]) end
    return "{"..table.concat(rows, ";").."}"
end

local function peer(multiplayer)
    local p = {turn = 10, saves = {}, loads = {}, timers = {}, diagnostics = {}, force_present = true}
    local env = setmetatable({}, {__index = _G}) env._G, p.env = env, env
    p.null = {is_null_interface = function() return true end}
    p.region = {name = function() return "region_a" end, is_null_interface = function() return false end}
    p.faction = {name = function() return "mk_fact_a" end, is_human = function() return true end,
        is_horde = function() return false end, is_null_interface = function() return false end}
    p.units = {
        {key = "general", strength = 100, general = true},
        {key = "troop", strength = 100}, {key = "troop", strength = 50}
    }
    local function unit(row)
        return {has_unit_commander = function() return row.general == true end,
            is_null_interface = function() return false end,
            has_force_commander = function() return p.general ~= nil end,
            force_commander = function() return p.general end,
            faction = function() return p.faction end,
            unit_key = function() return row.key end,
            percentage_proportion_of_full_strength = function() return row.strength end}
    end
    p.force = {
        command_queue_index = function() return 1001 end,
        has_general = function() return p.general ~= nil end,
        general_character = function() return p.general end,
        unit_list = function() local units = {} for i = 1, #p.units do units[i] = unit(p.units[i]) end return list(units) end
    }
    function p.faction:military_force_list() return list(p.force_present and {p.force} or {}) end
    local function character(cqi)
        return {is_null_interface = function() return false end,
            has_military_force = function() return p.general and p.general:cqi() == cqi end,
            faction = function() return p.faction end, cqi = function() return cqi end,
            has_region = function() return true end, region = function() return p.region end,
            military_force = function() return p.force end}
    end
    p.original, p.replacement = character(101), character(201)
    p.general = p.original
    local model = {
        turn_number = function() return p.turn end,
        character_for_command_queue_index = function(_, cqi)
            if cqi == 101 then return p.original end if cqi == 201 then return p.replacement end return p.null
        end,
        world = function() return {faction_by_key = function(_, name) return name == "mk_fact_a" and p.faction or p.null end} end
    }
    local cm = {} env.cm = cm
    function cm:model() return model end
    function cm:is_multiplayer() return multiplayer == true end
    function cm:is_new_game() return false end
    function cm:get_local_faction() return "mk_fact_a" end
    function cm:register_saving_game_callback(fn) p.saves[#p.saves + 1] = fn end
    function cm:register_loading_game_callback(fn) p.loads[#p.loads + 1] = fn end
    function cm:save_value(key, value, context) context[key] = value end
    function cm:load_value(key, default, context) if context[key] == nil then return default end return context[key] end
    function cm:add_time_trigger(name) p.timers[#p.timers + 1] = name end
    env.MKMP_Diagnostic_Copy = copy
    env.MKMP_Debug_Trace = function(domain, event, values) p.diagnostics[#p.diagnostics + 1] = {domain, event, copy(values)} end
    local loaded = {}
    env.require = function(path)
        if not loaded[path] then
            local chunk = assert(loadfile("campaigns/main_attila/"..path..".lua"))
            setfenv(chunk, env) loaded[path] = chunk() or true
        end
        return loaded[path]
    end
    env.require("common/mk1212_common")
    env.require("common/mkmp_actions")
    p.action_save, p.action_load = p.saves[#p.saves], p.loads[#p.loads]
    env.require("mechanics/population/mechanics_population")
    p.population_save, p.population_load = p.saves[#p.saves], p.loads[#p.loads]
    env.FACTION_TURN = "mk_fact_a"
    env.POPULATION_UNITS_TO_POPULATION = {troop = {100, 3}, other = {80, 2}}
    env.POPULATION_REGIONS_POPULATIONS = {region_a = {1000, 1000, 1000, 1000, 1000}, region_b = {2000, 2000, 2000, 2000, 2000}}
    env.POPULATION_REGIONS_MANPOWER = {region_a = {500, 500, 500, 500, 500}, region_b = {800, 800, 800, 800, 800}}
    env.MKMP_Population_Actions_Initialize()
    function p:submit(kind, payload) return self.env.MKMP_Actions_Submit_Local(kind, "mk_fact_a", payload) end
    function p:recruit() return self:submit("population_recruit", self.env.MKMP_Population_Capture_Recruit(self.original, "troop")) end
    function p:population() return self.env.POPULATION_REGIONS_POPULATIONS.region_a[3] end
    function p:manpower() return self.env.POPULATION_REGIONS_MANPOWER.region_a[3] end
    function p:save() local saved = {} self.action_save(saved) self.population_save(saved) return saved end
    function p:load(saved) self.action_load(saved) self.population_load(saved) end
    function p:observe() return self.env.MKMP_Population_Observe_Timer({string = self.timers[#self.timers]}) end
    function p:trained() return self.env.UnitTrained_Population({unit = function() return unit({key = "troop", strength = 100}) end}) end
    return p
end

local function reservations_and_load()
    local p = peer()
    local first_payload = p.env.MKMP_Population_Capture_Recruit(p.original, "troop")
    expect(p:submit("population_recruit", first_payload))
    expect(not p:submit("population_recruit", first_payload), "exact repeated capture is a duplicate")
    expect(p:recruit(), "same type can be recruited twice with a fresh reservation")
    equal(p:population(), 800) equal(p:manpower(), 300)
    local first = p.env.MKMP_Population_Capture_Cancel(p.original, 1)
    local stale_second = p.env.MKMP_Population_Capture_Cancel(p.original, 2)
    expect(first.reservation ~= stale_second.reservation, "identical types need independent reservation IDs")
    p.env.LAST_CHARACTER_SELECTED = p.replacement
    expect(p:submit("population_cancel", first), "refund uses captured commander, not selected UI character")
    equal(p:population(), 900) equal(p:manpower(), 400)
    expect(not p:submit("population_cancel", stale_second), "slot/revision changed after the first cancellation")
    equal(p:population(), 900)
    local remaining = p.env.MKMP_Population_Capture_Cancel(p.original, 1)
    equal(remaining.reservation, stale_second.reservation, "remaining identical unit preserves its identity")
    local saved = p:save()
    local loaded = peer() loaded:load(saved)
    local after_load = loaded.env.MKMP_Population_Capture_Cancel(loaded.original, 1)
    equal(after_load.reservation, remaining.reservation)
    expect(loaded:submit("population_cancel", after_load))
    equal(loaded:population(), 1000) equal(loaded:manpower(), 500)
    equal(loaded.env.POPULATION_REGIONS_MANPOWER.region_b[3], 800, "unrelated region unchanged")

    local legacy = copy(saved)
    legacy.MKMP_POPULATION_RESERVATIONS, legacy.MKMP_POPULATION_RESERVATIONS__schema = nil, nil
    local migrated = peer() migrated:load(legacy)
    equal(#migrated.env.POPULATION_UNITS_IN_RECRUITMENT["101"], 1, "legacy queue preserved")
    local unsafe_refund = migrated.env.MKMP_Population_Capture_Cancel(migrated.original, 1)
    expect(unsafe_refund and not migrated:submit("population_cancel", unsafe_refund), "legacy debit origin is not invented")
    equal(migrated:population(), 900)

    local wrong = peer()
    local forged = wrong.env.MKMP_Population_Capture_Recruit(wrong.original, "troop") forged.horde = true
    expect(not wrong:submit("population_recruit", forged), "horde flag must agree with captured current faction")
    equal(wrong:manpower(), 500)
    local moved = wrong.env.MKMP_Population_Capture_Recruit(wrong.original, "troop")
    wrong.region = {name = function() return "region_b" end, is_null_interface = function() return false end}
    expect(not wrong:submit("population_recruit", moved), "region change invalidates capture")

    local exhausted = copy(saved)
    local payload, row_count = p.env.MKMP_Population_Prepare_Actions()
    local replaced
    payload, replaced = string.gsub(payload, "queue,101,%d+,%d+,;", "queue,101,1000000,10,;")
    equal(replaced, 1, "fixture must modify an actual serialized revision row")
    p.env.MK1212_SaveCommitString(exhausted, "MKMP_POPULATION_RESERVATIONS", payload, row_count)
    local refused = peer()
    local load_ok = pcall(function() refused:load(exhausted) end)
    expect(load_ok, "last representable queue revision remains loadable")
    local before_refusal = refused:population()
    expect(not refused:recruit(), "exhausted revision is refused before accounting")
    equal(refused:population(), before_refusal)
    expect(not refused.env.MKMP_Population_Queue_Cleared("101"), "exhausted revision cannot half-clear a queue")
    equal(#refused.env.POPULATION_UNITS_IN_RECRUITMENT["101"], 1)
    equal(#refused.env.MKMP_Population_Actions_Get_State().reservations["101"], 1)
    local valid_payload, valid_rows = p.env.MKMP_Population_Prepare_Actions()
    for _, replacement in ipairs({
        {string.gsub(valid_payload, "queue,101,%d+,%d+,;", "queue,101,3,11,;"), valid_rows},
        {valid_payload.."phase,character_start:101,11,;", valid_rows + 1}
    }) do
        local future = copy(saved)
        p.env.MK1212_SaveCommitString(future, "MKMP_POPULATION_RESERVATIONS", replacement[1], replacement[2])
        local before = canonical(p.env.MKMP_Population_Actions_Get_State())
        expect(not pcall(function() p.population_load(future) end), "future revision/phase metadata fails closed")
        equal(canonical(p.env.MKMP_Population_Actions_Get_State()), before, "future metadata cannot partially replace accounting")
    end
    local oversized = copy(legacy)
    local queue = {} for i = 1, 65 do queue[i] = "troop" end
    p.env.SaveKeyPairTables(oversized, {["101"] = queue}, "POPULATION_UNITS_IN_RECRUITMENT")
    expect(not pcall(function() peer():load(oversized) end), "legacy queue obeys the same per-commander budget")
    local unknown = copy(saved)
    unknown.MKMP_POPULATION_RESERVATIONS = "MK1212_SAVE_V3|meta,99,;"
    local before = canonical(p.env.MKMP_Population_Actions_Get_State())
    expect(not pcall(function() p.population_load(unknown) end), "unknown reservation schema fails closed")
    equal(canonical(p.env.MKMP_Population_Actions_Get_State()), before, "failed load preserves previous accounting state")

    local partial = peer()
    local change = partial.env.Change_Manpower_Region
    partial.env.Change_Manpower_Region = function(...)
        change(...)
        error("injected error after accounting effect")
    end
    expect(not partial:recruit(), "partial effect leaves an uncertain action claim")
    equal(partial:population(), 900)
    partial.env.Change_Manpower_Region = change
    expect(not partial:recruit(), "uncertain accounting is never automatically retried")
    equal(partial:population(), 900)
    local partial_reload = peer() partial_reload:load(partial:save())
    expect(not partial_reload:recruit(), "partial claim survives save/load")
    equal(partial_reload:population(), 900)
end

local function force_observations()
    local p = peer()
    local capture = p.env.MKMP_Population_Capture_Force(p.original, "disband")
    expect(p:submit("population_force", capture))
    p.env.LAST_CHARACTER_SELECTED = p.replacement
    table.remove(p.units, 2)
    expect(p:observe()) equal(p:population(), 1100) equal(p:manpower(), 600)
    expect(not p:observe(), "duplicate timer cannot repeat the refund") equal(p:population(), 1100)

    local merge = peer()
    expect(merge:submit("population_force", merge.env.MKMP_Population_Capture_Force(merge.original, "merge")))
    merge.units = {{key = "general", strength = 100, general = true}, {key = "troop", strength = 100}, {key = "troop", strength = 50}}
    expect(merge:observe()) equal(merge:population(), 1000, "merge does not mint a disband refund")

    local commander = peer() expect(commander:recruit())
    local reservation = commander.env.MKMP_Population_Capture_Cancel(commander.original, 1).reservation
    expect(commander:submit("population_force", commander.env.MKMP_Population_Capture_Force(commander.original, "commander")))
    commander.general = commander.replacement
    expect(commander:observe())
    equal(commander.env.POPULATION_UNITS_IN_RECRUITMENT["101"], nil)
    equal(commander.env.MKMP_Population_Capture_Cancel(commander.replacement, 1).reservation, reservation, "commander replacement retains reservations")

    local invalid = peer() expect(invalid:recruit())
    expect(invalid:submit("population_force", invalid.env.MKMP_Population_Capture_Force(invalid.original, "commander")))
    invalid.general = copy(invalid.replacement)
    invalid.general.cqi = function() return 16777216 end
    expect(invalid:observe())
    equal(#invalid.env.POPULATION_UNITS_IN_RECRUITMENT["101"], 1, "unrepresentable replacement CQI cannot move bookkeeping")
    equal(invalid.env.POPULATION_UNITS_IN_RECRUITMENT["16777216"], nil)

    local missing = peer()
    expect(missing:submit("population_force", missing.env.MKMP_Population_Capture_Force(missing.original, "disband")))
    missing.force_present = false
    expect(missing:observe()) equal(missing:population(), 1000, "whole missing force is uncertain, not guessed disband evidence")
    equal(missing.env.MKMP_Actions_Get_State().records[1].status, "uncertain")
    local interrupted = peer()
    expect(interrupted:submit("population_force", interrupted.env.MKMP_Population_Capture_Force(interrupted.original, "disband")))
    local restored = peer() restored:load(interrupted:save())
    equal(#restored.timers, 0, "load does not recreate an interrupted timer")
    expect(not restored.env.MKMP_Population_Observe_Timer({string = interrupted.timers[1]}))
    equal(restored:population(), 1000)
    equal(restored.env.MKMP_Actions_Get_State().records[1].status, "uncertain")
end

local function ambiguous_training_preserves_debits()
    local source = peer() expect(source:recruit()) expect(source:recruit())
    local save = source:save()
    for _, multiplayer in ipairs({false, true}) do
        local p = peer(multiplayer) p:load(save)
        local before = canonical(p.env.MKMP_Population_Actions_Get_State().reservations)
        expect(not p:trained(), "native UnitTrained supplies no proved reservation identity")
        expect(not p:trained(), "duplicate training callback cannot consume another identical reservation")
        local state, status = p.env.MKMP_Population_Actions_Get_State()
        equal(status, "incomplete")
        equal(state.uncertain["101"].reason, "native_training_identity_unproven")
        equal(canonical(state.reservations), before, "both original debits are preserved")
        equal(#p.env.POPULATION_UNITS_IN_RECRUITMENT["101"], 2)
        expect(not p.env.MKMP_Population_Queue_Cleared("101"), "unproved queue clear cannot discard uncertain debit evidence")
        equal(p:population(), 800)
        local loaded = peer() loaded:load(p:save())
        local cancel = loaded.env.MKMP_Population_Capture_Cancel(loaded.original, 1)
        expect(cancel and not loaded:submit("population_cancel", cancel), "uncertain stale slot is not refundable after load")
        expect(not loaded:recruit(), "uncertain commander cannot append fresh paid records")
        equal(loaded:population(), 800)
        expect(loaded:submit("population_force", loaded.env.MKMP_Population_Capture_Force(loaded.original, "commander")))
        loaded.general = loaded.replacement
        expect(loaded:observe())
        local moved = loaded.env.MKMP_Population_Actions_Get_State()
        equal(moved.uncertain["101"], nil)
        equal(moved.uncertain["201"].reason, "native_training_identity_unproven", "new commander inherits uncertainty")
        local next_cancel = loaded.env.MKMP_Population_Capture_Cancel(loaded.replacement, 1)
        expect(next_cancel and not loaded:submit("population_cancel", next_cancel))
        equal(loaded:population(), 800)
    end
end

local function mp_has_no_local_authority()
    local p = peer(true)
    local before = canonical(p.env.MKMP_Population_Actions_Get_State())
    local accepted, reason = p:recruit()
    expect(not accepted) equal(reason, "native_delivery_and_command_semantics_unproven")
    expect(not p:submit("population_force", p.env.MKMP_Population_Capture_Force(p.original, "disband")))
    equal(p:population(), 1000) equal(p:manpower(), 500) equal(#p.timers, 0)
    equal(canonical(p.env.MKMP_Population_Actions_Get_State()), before, "MP local capture cannot change shared pending state")
end

reservations_and_load()
force_observations()
ambiguous_training_preserves_debits()
mp_has_no_local_authority()
print("PASS production Lua population reservation and observation regressions")
