-- Actual common + action registry + buffer production Lua; only engine/UI
-- interfaces and the adjacent vassal tracker are doubles. SP lifecycle checks
-- and MP capture-only checks are not proof of native multiplayer delivery.
local KEY = "MKMP_BUFFER_ACTION_STATE"
local ACTION_KEY = "MKMP_ACTIONS"
local function equal(a, b, why)
    assert(a == b, (why or "not equal")..": "..tostring(a).." / "..tostring(b))
end
local function list(items)
    return {num_items = function() return #items end, item_at = function(_, i) return items[i + 1] end}
end

local function peer(options)
    options = options or {}
    local p = {turn = 10, local_faction = "master", commands = {}, timers = {}, spawns = {},
        saves = {}, loads = {}, listeners = {}, listener_order = {}, logs = {}, traces = {}, ui_creations = 0}
    local e = setmetatable({}, {__index = _G})
    e._G, p.env = e, e
    p.null = {is_null_interface = function() return true end}
    p.factions = {}
    for _, name in ipairs({"master", "vassal_a", "vassal_b", "foreign"}) do
        local f = {_name = name, alive = name == "master" or name == "foreign"}
        function f:name() return self._name end
        function f:is_null_interface() return false end
        function f:is_human() return self._name == "master" end
        function f:is_horde() return false end
        function f:at_war_with() return false end
        function f:has_home_region() return self.alive end
        function f:home_region() return {name = function() return "capital_"..self._name end} end
        function f:region_list()
            local regions = {}
            for _, region in pairs(p.regions) do
                if region.owner == self._name then regions[#regions + 1] = region end
            end
            table.sort(regions, function(a, b) return a:name() < b:name() end)
            return list(regions)
        end
        function f:military_force_list() return {num_items = function() return 0 end} end
        p.factions[name] = f
    end
    p.regions = {}
    for i, name in ipairs({"region_a", "region_b"}) do
        local settlement = {is_null_interface = function() return false end,
            logical_position_x = function() return 10 * i end,
            logical_position_y = function() return 20 * i end}
        local r = {_name = name, owner = "master", _settlement = settlement}
        function r:name() return self._name end
        function r:is_null_interface() return false end
        function r:owning_faction() return p.factions[self.owner] or p.null end
        function r:settlement() return self._settlement end
        function r:has_governor() return false end
        function r:adjacent_region_list() return list({}) end
        function r:garrison_residence()
            return {is_null_interface = function() return false end, is_under_siege = function() return false end,
                buildings = function() return list({{name = function() return "building_fixture" end}}) end}
        end
        p.regions[name] = r
    end
    local manager = {region_by_key = function(_, name)
        assert(type(name) == "string", "region lookup needs captured key")
        return p.regions[name] or p.null
    end}
    local world = {region_manager = function() return manager end,
        faction_by_key = function(_, name)
            assert(type(name) == "string", "faction lookup needs captured key")
            return p.factions[name] or p.null
        end}
    local model = {world = function() return world end,
        turn_number = function() return p.turn end,
        campaign_ai = function() return {strategic_stance_between_factions = function() return 0 end} end}
    local function ui_node(name)
        local n = {name = name, visible = true, children = {}, order = {}}
        function n:Find(key)
            if type(key) == "number" then return self.children[self.order[key + 1]] end
            return self.children[key]
        end
        function n:CreateComponent(id, path)
            assert(not self.children[id], "duplicate UI component "..id)
            local child = ui_node(id)
            self.children[id], self.order[#self.order + 1] = child, id
            if id == "Buffer_Warning" then
                p.ui_creations = p.ui_creations + 1
                for _, child_id in ipairs({"heading_txt", "dy_buffer_info", "txt", "scroll_frame"}) do
                    child:CreateComponent(child_id, "fixture-child")
                end
            end
            return child
        end
        function n:Visible() return self.visible end
        function n:SetVisible(value) self.visible = value end
        function n:SetState(value) self.state = value end
        function n:SetStateText(value) assert(type(value) == "string"); self.text = value end
        function n:SetTooltipText(value) self.tooltip = value end
        function n:DestroyChildren() self.children, self.order = {}, {} end
        function n:Position() return 0, 0 end
        function n:SetMoveable() end
        function n:MoveTo() end
        function n:SetInteractive() end
        return n
    end
    p.root = ui_node("root")
    p.root:CreateComponent("button_release_buffer_state", "fixture-button")
    e.UIComponent = function(node) assert(node, "missing UI node"); return node end
    local cm = {}
    e.cm = cm
    function cm:model() return model end
    function cm:is_multiplayer() return options.multiplayer == true end
    function cm:is_new_game() return false end
    function cm:get_local_faction() return p.local_faction end
    function cm:ui_root() return p.root end
    function cm:register_saving_game_callback(callback) p.saves[#p.saves + 1] = callback end
    function cm:register_loading_game_callback(callback) p.loads[#p.loads + 1] = callback end
    function cm:save_value(key, value, storage) storage[key] = value end
    function cm:load_value(key, default, storage)
        if storage[key] == nil then return default end
        return storage[key]
    end
    function cm:add_listener(id, event, condition, callback)
        assert(not p.listeners[id], "duplicate listener "..id)
        p.listeners[id] = {event = event, condition = condition, callback = callback}
        p.listener_order[#p.listener_order + 1] = id
    end
    function cm:add_time_trigger(name, seconds)
        p.timers[#p.timers + 1] = {name = name, seconds = seconds}
    end
    function cm:create_force(faction, units, region, x, y, id, command, callback)
        p.commands[#p.commands + 1] = {"create_force", faction, units, region, x, y, id, command}
        p.spawns[#p.spawns + 1] = {faction = faction, callback = callback}
        if p.create_hook then p.create_hook() end
    end
    function cm:force_make_vassal(master, vassal)
        p.commands[#p.commands + 1] = {"vassal", master, vassal}
        if p.vassal_hook then p.vassal_hook() end
    end
    function cm:transfer_region_to_faction(region, faction)
        p.commands[#p.commands + 1] = {"transfer", region, faction}
        if p.transfer_hook then p.transfer_hook() end
        if not p.defer_transfer then p.regions[region].owner = faction end
    end
    function cm:grant_faction_handover(actor, target)
        p.commands[#p.commands + 1] = {"handover", actor, target}
        if p.handover_hook then p.handover_hook(actor, target) end
        if not p.defer_handover then
            for _, region in pairs(p.regions) do if region.owner == target then region.owner = actor end end
            p.factions[target].alive = false
        end
    end
    function cm:apply_effect_bundle(name, faction) p.commands[#p.commands + 1] = {"bundle", name, faction} end
    function cm:remove_effect_bundle(name, faction) p.commands[#p.commands + 1] = {"unbundle", name, faction} end
    function cm:show_message_event() end
    e.MKMP_Debug_Log = function(name, data) p.logs[#p.logs + 1] = {name, data} end
    e.MKMP_Debug_Trace = function(domain, event, data)
        p.traces[#p.traces + 1] = {domain = domain, event = event, stage = data.stage, reason = data.reason}
    end
    local function load(path)
        local code = assert(loadfile("campaigns/main_attila/"..path..".lua"))
        setfenv(code, e)
        return code()
    end
    local loaded = {}
    e.require = function(path)
        if loaded[path] == nil then loaded[path] = load(path) or true end
        return loaded[path]
    end
    load("common/mk1212_common")
    load("common/mkmp_state_providers")
    load("common/mkmp_actions")
    load("mechanics/mechanics_buffer_states")
    e.REGIONS_LIBERATION_FACTIONS = {region_a = "vassal_a", region_b = "vassal_b"}
    e.BUFFER_STATE_SPEAR_UNITS = {vassal_a = "spear_a"}
    e.FACTIONS_WITH_IMAGES = {}
    e.REGIONS_NAMES_LOCALISATION = {region_a = "Region A", region_b = "Region B"}
    e.UI_LOCALISATION = {buffer_state_prompt_heading_text = "Release",
        buffer_state_prompt_description = "Description", buffer_state_prompt_info_pt1 = "Release ",
        buffer_state_prompt_info_pt2 = " in "}
    e.Get_DFN_Localisation = function(name) return name end
    e.FACTIONS_TO_FACTIONS_VASSALIZED = {}
    e.Faction_Vassalized = function(master, vassal, ...)
        p.commands[#p.commands + 1] = {"track", master, vassal, ...}
    end
    e.FACTION_TURN, e.REGION_SELECTED = "master", "region_a"
    function p:load_annex()
        load("mechanics/mechanics_annex_vassals")
        e.ANNEX_VASSALS_SIZES, e.FACTIONS_DFN_LEVEL = {"1"}, {}
        e.Add_Annex_Vassals_Listeners()
    end
    function p:load_region_trade()
        load("mechanics/mechanics_region_trading")
        e.REGION_TRADING_BUILDING_VALUES, e.REGION_TRADING_STANCE_MODIFIERS = {building_fixture = 2000}, {}
        e.Add_Region_Trading_Listeners()
    end
    function p:initialize()
        self.env.MKMP_Actions_Initialize()
        self.env.Add_Buffer_States_Listeners()
    end
    function p:emit(event, context)
        for _, id in ipairs(self.listener_order) do
            local l = self.listeners[id]
            if l.event == event and (l.condition == true or l.condition(context)) then l.callback(context) end
        end
    end
    function p:click(id)
        self:emit("ComponentLClickUp", {string = id, component = self.root:Find("button_release_buffer_state")})
    end
    function p:open(region)
        self.env.REGION_SELECTED = region or "region_a"
        self:click("button_release_buffer_state")
    end
    function p:confirm() self:click("button_buffer_confirm") end
    function p:select(region)
        self.env.REGION_SELECTED = region
        self:emit("SettlementSelected", {garrison_residence = function()
            return {is_null_interface = function() return false end,
                region = function() return self.regions[region] end}
        end})
    end
    function p:complete_spawn(index, cqi)
        local spawn = self.spawns[index or 1]
        self.factions[spawn.faction].alive = true
        spawn.callback(cqi == nil and 501 or cqi)
    end
    function p:timer(name) self:emit("TimeTrigger", {string = name or self.timers[#self.timers].name}) end
    function p:save()
        local storage = {}
        for _, callback in ipairs(self.saves) do callback(storage) end
        return storage
    end
    function p:restore(storage)
        for _, callback in ipairs(self.loads) do callback(storage) end
    end
    function p:record(storage) return self.env.LoadTable(storage or self:save(), KEY) end
    function p:actions() return self.env.MKMP_Actions_Get_State() end
    function p:action_status()
        local state = self:actions()
        return state.records[#state.records] and state.records[#state.records].status
    end
    function p:stored(record)
        local storage = self:save()
        self.env.SaveTable(storage, record, KEY)
        return storage
    end
    function p:count(kind)
        local count = 0
        for _, command in ipairs(self.commands) do if command[1] == kind then count = count + 1 end end
        return count
    end
    return p
end

local tests = {}

function tests.captured_target_and_duplicates()
    do
        local p = peer({multiplayer = false})
        p:initialize(); p:initialize()
        equal(#p.listener_order, 5); equal(p.ui_creations, 1)
        p:open("region_a")
        assert(string.find(p.root:Find("Buffer_Warning"):Find("dy_buffer_info").text, "Region A", 1, true))
        p:select("region_b") -- the visible confirmation still describes A
        p:confirm(); p:confirm()
        equal(p:count("create_force"), 1); equal(#p.timers, 0, "timer waits for successful spawn callback")
        equal(p:action_status(), "requested", "spawn request is not completed ownership")
        equal(#p:actions().records, 1, "real registry owns one captured action")
        equal(p.commands[1][4], "region_a"); equal(p.commands[1][2], "vassal_a")
        equal(p.commands[1][3], "spear_a,spear_a,spear_a,spear_a")
        p:open("region_b"); p:confirm() -- one pending action bounds local UI work
        p:complete_spawn(); p:complete_spawn()
        equal(p:count("create_force"), 1); equal(p:count("vassal"), 1); equal(p:count("track"), 1)
        equal(#p.timers, 1)
        p:timer("region_transfer") -- legacy ambiguous timer must not read selection B
        equal(p:count("transfer"), 0)
        p:timer(); p:timer()
        equal(p:count("transfer"), 1); equal(p.regions.region_a.owner, "vassal_a")
        equal(p.regions.region_b.owner, "master"); equal(p:record()[3], "idle")
        equal(p:record()[1], "2"); equal(p:action_status(), "confirmed")
    end
end

function tests.stale_timer_cannot_consume_next_action()
    local p = peer()
    p:initialize(); p:open(); p:confirm(); p:complete_spawn()
    local old_timer = p.timers[1].name
    p:timer(old_timer)
    p:open("region_b"); p:confirm(); p:complete_spawn(2)
    equal(p.commands[5][3], "att_rom_cohors", "existing fallback unit remains")
    local new_timer = p.timers[2].name
    assert(new_timer ~= old_timer, "no timer token reuse")
    p:timer(old_timer); p:timer("region_transfer")
    equal(p.regions.region_b.owner, "master")
    p:timer(new_timer); p:timer(new_timer)
    equal(p:count("transfer"), 2); equal(p.regions.region_b.owner, "vassal_b")
end

function tests.waiting_save_reload()
    local old = peer()
    old:initialize(); old:open(); old:confirm(); old:complete_spawn()
    local storage, old_timer = old:save(), old.timers[1].name
    equal(old:record(storage)[3], "waiting_transfer")
    local p = peer()
    p.factions.vassal_a.alive = true -- restored model already contains completed spawn/setup
    p.env.REGION_SELECTED, p.local_faction = "region_b", "foreign"
    p:restore(storage)
    equal(old:record(storage)[1], "2"); equal(old:record(storage)[8], "sp:master:1")
    equal(#p.commands, 0); equal(#p.timers, 0, "load callback issues no timer/model command")
    p:initialize(); p:initialize()
    equal(#p.timers, 1); equal(p.timers[1].name, old_timer)
    p:timer(old_timer); p:timer(old_timer)
    equal(p:count("transfer"), 1); equal(#p.commands, 1, "no replay of spawn/vassal setup")
    equal(p:action_status(), "confirmed", "restored action ID correlates completed ownership")
    equal(p.regions.region_a.owner, "vassal_a"); equal(p.regions.region_b.owner, "master")
    local done = p:save()
    local completed = peer()
    completed:restore(done); completed:initialize(); completed:timer(old_timer)
    equal(#completed.commands, 0); equal(#completed.timers, 0)
    equal(completed:record()[2], "1", "serial survives completed save")
end

local function assert_frozen(storage, phase)
    local p = peer()
    p:restore(storage); p:initialize(); p:initialize()
    p:open(); p:confirm(); p:timer("MK1212_Buffer_Transfer_1")
    equal(#p.commands, 0, "interrupted/unknown action cannot replay")
    equal(#p.timers, 0)
    local preserved = p:save()
    equal(preserved[KEY], storage[KEY], "raw action retained")
    equal(preserved[KEY.."__schema"], storage[KEY.."__schema"], "raw schema retained")
    if phase then equal(p:record(preserved)[3], phase) end
end

function tests.interrupted_setup_is_not_replayed()
    local p = peer()
    p:initialize(); p:open(); p:confirm()
    local started = p:save()
    equal(p:record(started)[3], "started")
    assert_frozen(started, "started")
    p.vassal_hook = function() error("engine partially made vassal") end
    local ok = pcall(function() p:complete_spawn() end)
    assert(ok, "asynchronous failure is retained without escaping callback")
    p.vassal_hook = nil
    p:complete_spawn(); p:confirm()
    equal(p:count("vassal"), 1, "duplicate spawn callback never repeats partial setup")
    equal(p:count("track"), 0); equal(#p.timers, 0)
    equal(p:action_status(), "uncertain")
    assert_frozen(p:save(), "blocked")
    -- Loading in the same Lua environment invalidates the old closure by identity.
    p:restore(started); p:complete_spawn(); p:initialize()
    equal(p:count("vassal"), 1); equal(#p.timers, 0)
end

function tests.transfer_failure_claims_once()
    for _, failure in ipairs({"false", "error", "reentry"}) do
        local p = peer()
        p:initialize(); p:open(); p:confirm(); p:complete_spawn()
        local attempts = 0
        if failure == "false" then
            -- Inject the adjacent helper's documented refusal contract, not a
            -- second implementation of the buffer state machine.
            p.env.Transfer_Region_To_Faction = function() attempts = attempts + 1; return false end
        else
            p.transfer_hook = function()
                attempts = attempts + 1
                p:timer() -- nested engine delivery cannot consume the action again
                if failure == "error" then error("partially transferred region") end
            end
        end
        local ok = pcall(function() p:timer() end)
        equal(ok, true, "transfer failure stays inside the claimed action")
        p:timer(); p:confirm()
        equal(attempts, 1)
        if failure == "reentry" then
            equal(p.regions.region_a.owner, "vassal_a"); equal(p:record()[3], "idle")
        else
            equal(p:action_status(), "uncertain")
            assert_frozen(p:save(), "blocked")
        end
    end
end

function tests.expected_owner_and_entities()
    for _, stage in ipairs({"confirmation", "spawn", "timer", "restore"}) do
        local p = peer()
        p:initialize(); p:open()
        if stage == "confirmation" then p.regions.region_a.owner = "foreign" end
        p:confirm()
        if stage ~= "confirmation" then
            if stage == "spawn" then p.regions.region_a.owner = "foreign" end
            p:complete_spawn()
            if stage == "timer" then p.regions.region_a.owner = "foreign"; p:timer() end
            if stage == "restore" then
                local storage = p:save()
                p = peer(); p.regions.region_a.owner = "foreign"
                p:restore(storage); p:initialize()
                equal(#p.timers, 0)
            end
        end
        equal(p:count("transfer"), 0, "foreign owner is never transferred at "..stage)
        p:open("region_b"); p:confirm()
        if stage ~= "confirmation" then equal(p:record()[3], "blocked") end
    end
    for _, invalid in ipairs({"region", "master", "vassal", "mapping", "future_turn", "settlement", "cqi"}) do
        local p = peer()
        p:initialize(); p:open()
        if invalid == "region" then p.regions.region_a = nil
        elseif invalid == "master" then p.factions.master = nil
        elseif invalid == "vassal" then p.factions.vassal_a = nil
        elseif invalid == "mapping" then p.env.REGIONS_LIBERATION_FACTIONS.region_a = "vassal_b"
        elseif invalid == "future_turn" then p.turn = 9
        elseif invalid == "settlement" then p.regions.region_a._settlement = p.null end
        p:confirm()
        if invalid == "cqi" then p:complete_spawn(1, "invalid"); p:complete_spawn() end
        equal(p:count("vassal"), 0); equal(p:count("transfer"), 0); equal(#p.timers, 0)
    end
    for _, invalid in ipairs({"garrison", "region", "owner", "mapping", "vassal"}) do
        local p = peer()
        p:initialize()
        local garrison = {is_null_interface = function() return false end,
            region = function() return p.regions.region_a end}
        if invalid == "garrison" then garrison = p.null
        elseif invalid == "region" then p.regions.region_a = p.null
        elseif invalid == "owner" then p.regions.region_a.owner = "missing"
        elseif invalid == "mapping" then p.env.REGIONS_LIBERATION_FACTIONS.region_a = nil
        elseif invalid == "vassal" then p.factions.vassal_a = nil end
        p:emit("SettlementSelected", {garrison_residence = function() return garrison end})
        equal(p.root:Find("button_release_buffer_state"):Visible(), false,
            "invalid selected "..invalid.." hides action")
        equal(#p.commands, 0)
    end
end

function tests.already_owned_and_revived_faction()
    for _, restored in ipairs({false, true}) do
        local p = peer()
        p:initialize(); p:open(); p:confirm(); p:complete_spawn()
        if restored then
            local storage = p:save()
            p = peer(); p.regions.region_a.owner = "vassal_a"
            p:restore(storage); p:initialize()
            equal(#p.timers, 0)
        else p.regions.region_a.owner = "vassal_a"; p:timer() end
        equal(p:count("transfer"), 0); equal(p:record()[3], "idle")
        equal(p:action_status(), "confirmed")
    end
    local p = peer({multiplayer = false})
    p:initialize(); p:open()
    p.factions.vassal_a.alive = true -- revived while modal was open: keep old direct-transfer behavior
    p:confirm(); p:confirm()
    equal(p:count("create_force"), 0); equal(p:count("vassal"), 0)
    equal(p:count("transfer"), 1); equal(#p.timers, 0)
end

function tests.legacy_and_unconfirmed_intent()
    local p = peer()
    p:initialize(); p:open()
    local storage = p:save()
    equal(p:record(storage)[3], "idle", "unconfirmed UI is not saved authority")
    p:restore(storage); p:confirm()
    equal(#p.commands, 0)
    p:restore({FACTION_TURN = "master"}); p:initialize(); p:timer("region_transfer")
    equal(#p.commands, 0, "no target guessed for legacy timer")
    p:click("root"); p:open(); p:click("button_buffer_cancel"); p:confirm()
    equal(#p.commands, 0, "cancel consumes local intent")
    p:open(); p:emit("SettlementDeselected", {}); p:confirm()
    equal(#p.commands, 0, "deselect consumes unconfirmed intent")
    p:open(); p:confirm(); p:complete_spawn(); p:emit("SettlementDeselected", {}); p:timer()
    equal(p:count("transfer"), 1, "deselect leaves confirmed action intact")
end

function tests.metadata_bounds_and_exhaustion()
    local writer = peer()
    local cases = {
        {"3", "1", "waiting_transfer", "master", "vassal_a", "region_a", "10"},
        {"2", "1", "waiting_transfer", "master", "vassal_a", "region_a", "10"},
        {"2", "1", "waiting_transfer", "master", "vassal_a", "region_a", "10", "sp:foreign:1"},
        {"1", "01", "idle"}, {"1", "1000001", "idle"}, {"1", "-1", "idle"},
        {"1", "1", "future_phase", "master", "vassal_a", "region_a", "10"},
        {"1", "0", "waiting_transfer", "master", "vassal_a", "region_a", "10"},
        {"1", "1", "waiting_transfer", "master", "vassal_a", "region_a", "0"},
        {"1", "1", "waiting_transfer", string.rep("m", 257), "vassal_a", "region_a", "10"},
        {"1", "1", "waiting_transfer", "master", "vassal_a", "region_a"},
    }
    for _, record in ipairs(cases) do assert_frozen(writer:stored(record)) end
    local future = writer:stored({"1", "1", "idle"})
    future[KEY.."__schema"] = 99
    assert_frozen(future)
    assert_frozen({[KEY] = "malformed", [KEY.."__schema"] = 3})
    assert_frozen({[KEY] = string.rep("x", 4097), [KEY.."__schema"] = 3})
    local p = peer()
    p:restore(writer:stored({"1", "999999", "idle"})); p:initialize()
    p:open(); p:confirm(); p:complete_spawn()
    equal(p.timers[1].name, "MK1212_Buffer_Transfer_1000000", "bounded serial remains exact in float Lua")
    p:timer(); p:open("region_b"); p:confirm()
    equal(p:count("create_force"), 1, "exhaustion refuses new action without wrap")
    equal(p:record()[2], "1000000")

    local other = peer()
    assert(other.env.MKMP_Actions_Register("other", {
        validate = function() return true end, execute = function() return true, "confirmed" end}))
    assert(other.env.MKMP_Actions_Submit_Local("other", "master", {}))
    assert_frozen(other:stored({"2", "1", "waiting_transfer", "master", "vassal_a", "region_a", "10", "sp:master:1"}))
end

function tests.legacy_v1_migration_and_mp_capture_only()
    local writer = peer()
    local old = writer:stored({"1", "1", "waiting_transfer", "master", "vassal_a", "region_a", "10"})
    local restored = peer()
    restored.factions.vassal_a.alive = true
    restored:restore(old); restored:initialize()
    equal(#restored.commands, 0); equal(#restored.timers, 1)
    equal(restored:record()[1], "2"); equal(restored:record()[8], "none", "migration never invents an action ID")
    restored:timer(); equal(restored:count("transfer"), 1)

    local host, client = peer({multiplayer = true}), peer({multiplayer = true})
    host:initialize(); client:initialize()
    host:open(); host:confirm(); host:confirm(); host:open("region_b"); host:confirm()
    host:timer("region_transfer"); host:timer("MK1212_Buffer_Transfer_1")
    equal(#host.commands, 0); equal(#host.timers, 0)
    equal(#host:actions().records, 0); equal(host:actions().sequence, 0)
    local host_save, client_save = host:save(), client:save()
    equal(host_save[KEY], client_save[KEY], "asymmetric MP UI cannot change shared buffer metadata")
    equal(host_save[ACTION_KEY], client_save[ACTION_KEY], "MP capture cannot allocate shared operation IDs")
    assert(#host.traces > 0, "blocked local intent remains diagnosable")
    for _, trace in ipairs(host.traces) do
        if trace.event == "action" then equal(trace.domain, "local") end
    end
    local accepted = host.env.MKMP_Actions_Observe_Native("buffer_state", {actor = "master", phase = "fixture_observation"})
    equal(accepted, false, "an observation cannot enable model execution")

    local loaded_mp = peer({multiplayer = true})
    loaded_mp.factions.vassal_a.alive = true
    loaded_mp:restore(old); loaded_mp:initialize(); loaded_mp:timer("MK1212_Buffer_Transfer_1")
    loaded_mp:emit("FactionTurnStart", {})
    equal(#loaded_mp.commands, 0); equal(#loaded_mp.timers, 0, "legacy metadata cannot rearm an MP local timer")
end

function tests.annex_handover_claim_survives_failure_turn_and_load()
    local p = peer()
    p:load_annex()
    p.regions.region_a.owner, p.factions.vassal_a.alive = "vassal_a", true
    p.env.FACTIONS_TO_FACTIONS_VASSALIZED.master = {"vassal_a"}
    p.env.FACTIONS_VASSALIZED_ANNEXING.vassal_a = true
    p.env.FACTIONS_VASSALIZED_ANNEXATION_TIME.vassal_a = 1
    p.env.FACTIONS_VASSALIZED_DELAYS.vassal_a = 0
    p.handover_hook = function() error("native handover may have partially executed") end
    local context = {faction = function() return p.factions.master end}
    p.env.FactionTurnStart_Annex(context); p.env.FactionTurnStart_Annex(context)
    equal(p:count("handover"), 1)
    equal(p.env.MKMP_Annex_Get_State().handovers.vassal_a.phase, "uncertain")
    p.turn = 11; p.env.FactionTurnStart_Annex(context)
    equal(p:count("handover"), 1, "a new turn cannot retry the claimed native handover")
    local storage = p:save()
    local q = peer()
    q.turn = 11; q:load_annex()
    q.regions.region_a.owner, q.factions.vassal_a.alive = "vassal_a", true
    q.env.FACTIONS_TO_FACTIONS_VASSALIZED.master = {"vassal_a"}
    q:restore(storage)
    equal(#q.commands, 0, "loading claims performs no command")
    q.turn = 12
    q.env.FactionTurnStart_Annex({faction = function() return q.factions.master end})
    equal(q:count("handover"), 0, "loading cannot forget a partial handover claim")
    q.regions.region_a.owner = "master"; q.turn = 13
    q.env.FactionTurnStart_Annex({faction = function() return q.factions.master end})
    equal(q:count("handover"), 0)
    equal(q.env.MKMP_Annex_Get_State().handovers.vassal_a.phase, "ownership_observed")

    local before = q.env.MKMP_Annex_Get_State().handovers.vassal_a.turn
    local bad = q:save(); bad.MKMP_ANNEX_HANDOVERS_VERSION = 99
    assert(not pcall(q.restore, q, bad), "unknown handover schema is refused")
    equal(q.env.MKMP_Annex_Get_State().handovers.vassal_a.turn, before, "annex snapshot swaps only after validation")
end

function tests.region_trade_observes_exact_payload_without_replay()
    local p = peer()
    p:load_region_trade(); p.defer_transfer = true
    local payload = {target = "foreign", giving = {"region_a"}, receiving = {}, turn = 10}
    local ok, status, id = p.env.MKMP_Actions_Submit_Local("region_trade", "master", payload)
    assert(ok); equal(status, "requested"); equal(p:count("transfer"), 1)
    payload.giving[1] = "region_b" -- caller mutation cannot retarget saved observations
    local storage = p:save()
    local q = peer()
    q:load_region_trade(); q:restore(storage)
    equal(#q.commands, 0); equal(q:action_status(), "uncertain")
    q.env.MKMP_Region_Trade_Observe(); equal(q:action_status(), "uncertain")
    q.regions.region_b.owner = "foreign"
    q.env.MKMP_Region_Trade_Observe(); equal(q:action_status(), "uncertain", "a different changed region is not completion")
    q.regions.region_a.owner = "foreign"
    q.env.MKMP_Region_Trade_Observe(); q.env.MKMP_Region_Trade_Observe()
    equal(q:action_status(), "confirmed"); equal(#q.commands, 0, "observer never reissues a transfer")
    equal(q.env.MKMP_Region_Trade_Get_State().pending[id], nil)
    local complete = q:save()
    q:restore(complete); equal(q:action_status(), "confirmed")

    local broken = peer()
    broken:load_region_trade()
    broken.transfer_hook = function() error("possible partial native transfer") end
    local accepted = broken.env.MKMP_Actions_Submit_Local("region_trade", "master",
        {target = "foreign", giving = {"region_a"}, receiving = {}, turn = 10})
    equal(accepted, false); equal(broken:action_status(), "uncertain")
    broken.transfer_hook = nil; broken.turn = 11
    broken.env.MKMP_Region_Trade_Observe()
    equal(broken:count("transfer"), 1, "failed trade observation cannot retry an issued call")

    local wrong = peer()
    wrong:load_region_trade()
    local mismatch = p:save()
    mismatch[ACTION_KEY], mismatch[ACTION_KEY.."__schema"] = "broken", 3
    wrong:restore(mismatch); wrong.regions.region_a.owner = "foreign"
    wrong.env.MKMP_Region_Trade_Observe()
    assert(wrong.env.MKMP_Region_Trade_Get_State().pending[id], "invalid action ledger cannot authorize confirmation")
    equal(#wrong.commands, 0)
end

local scenario = assert(arg[1], "scenario required")
if scenario == "all" then
    local names = {}
    for name, _ in pairs(tests) do names[#names + 1] = name end
    table.sort(names)
    for _, name in ipairs(names) do
        tests[name]()
        print("PASS production Lua buffer actions: "..name)
    end
    print("PASS production Lua action scenarios: "..#names)
else
    assert(tests[scenario], "unknown scenario "..scenario)()
    print("PASS production Lua buffer actions: "..scenario)
end
