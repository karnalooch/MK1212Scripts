-- One consolidated production-Lua diagnostics regression. Only Attila objects
-- and file handles are doubles; WW, logger, codec and runtime adapter are real.
local function list(items)
	return {num_items = function() return #items end, item_at = function(_, i) return items[i + 1] end};
end

local function peer(options)
	options = options or {};
	local p = {lines = {}, callbacks = {}, saves = {}, turn = 1, mutations = 0, draws = 0};
	local e = setmetatable({}, {__index = _G}); e._G = e; p.env = e;
	local function faction(key)
		return {
			name = function() return key end, is_null_interface = function() return false end,
			is_human = function() return true end, is_horde = function() return false end,
			at_war = function() return true end, military_force_list = function() return list({}) end,
			state_religion = function() return "att_rel_chr_catholic" end
		};
	end
	p.a, p.b = faction("mk_fact_a"), faction("mk_fact_b");
	local owners = options.swapped and {p.b, p.a} or {p.a, p.b};
	p.region_items = {};
	for i, key in ipairs({"att_reg_a", "att_reg_b"}) do
		local owner = owners[i];
		p.region_items[i] = {name = function() return key end,
			is_null_interface = function() return false end, owning_faction = function() return owner end};
	end
	local world = {
		faction_list = function() return list({p.a, p.b}) end,
		faction_by_key = function(_, name) return name == "mk_fact_a" and p.a or p.b end,
		region_manager = function() return {region_list = function() return list(p.region_items) end} end
	};
	local model = {world = function() return world end, turn_number = function() return p.turn end,
		difficulty_level = function() error("MP must not read local difficulty") end};
	e.cm = {
		model = function() return model end, is_multiplayer = function() return true end,
		is_new_game = function() return true end,
		get_local_faction = function() return options.client and "mk_fact_b" or "mk_fact_a" end,
		register_loading_game_callback = function(_, fn) p.callbacks[#p.callbacks + 1] = fn end,
		register_saving_game_callback = function() end,
		load_value = function(_, key, default, context)
			if context and context[key] ~= nil then return context[key] end
			return default;
		end,
		save_value = function(_, key, value) p.saves[key] = value end,
		add_listener = function() end,
		show_message_event = function() end,
		apply_effect_bundle = function() p.mutations = p.mutations + 1 end,
		remove_effect_bundle = function() p.mutations = p.mutations + 1 end,
		random_number = function(_, maximum, minimum) p.draws = p.draws + 1; return minimum end
	};
	e.io = {open = function(_, mode)
		if mode == "rb" then return nil end
		if p.fail_io then error("injected open failure") end
		return {
			write = function(self, value) p.lines[#p.lines + 1] = value; return self end,
			flush = function() return true end, close = function() return true end
		};
	end};
	e.package = {loadlib = function()
		return function()
			return {core = {GameBuild = function() return "Attila" end, GetBuildSha = function() return string.rep("a", 40) end},
				world = {GetFactionCount = function() return options.native_count end}};
		end;
	end};
	local loaded = {};
	e.require = function(name)
		if not loaded[name] then
			loaded[name] = true;
			local source = assert(loadfile("campaigns/main_attila/"..name..".lua"));
			setfenv(source, e); source();
		end
		return true;
	end;
	for _, name in ipairs({"common/mk1212_common", "common/mkmp_fingerprint", "common/mkmp_debug",
		"common/mkmp_runtime", "mechanics/mechanics_war_weariness"}) do e.require(name); end
	e.MKMP_PACK_ID = {source = string.rep("a", 40), profile = "full-experimental"};
	assert(e.MKMP_Debug_Initialize());
	p.debug_load = p.callbacks[#p.callbacks];
	e.MKMP_Runtime_Initialize();
	assert(e.MKMP_RUNTIME.module_loaded);
	assert(e.MKMP_RUNTIME.game_name == "Attila" and e.MKMP_RUNTIME.game_build == "unknown");
	e.Add_War_Weariness_Listeners();
	assert(p.draws == 0, "diagnostics initialization consumed campaign RNG");
	p.context = {faction = function() return p.a end};
	function p:barrier(name)
		assert(e.MKMP_Debug_Barrier(name, {listener = "production_fixture", stage = "handler_exit"}));
	end
	function p:act()
		local draws_before = self.draws;
		self:barrier("before_ww");
		if options.client then
			e.MKMP_Debug_Trace("transport", "ack", {packet = "client_only"});
		else
			e.MKMP_Debug_Trace("local", "ui_click", {target = "host_selection"});
			e.MKMP_Debug_Trace("local", "ui_click", {target = "another_selection"});
		end
		e.MK1212_Random_Int(1, 10, "n1.wrapped_draw");
		e.FactionTurnStart_WW(self.context);
		local mutations = self.mutations;
		e.FactionTurnStart_WW(self.context);
		assert(self.mutations == mutations, "duplicate WW callback changed the model");
		self:barrier("after_ww");
		assert(self.draws == draws_before + 1, "diagnostics consumed campaign RNG");
	end
	function p:text() return table.concat(self.lines); end
	return p;
end

local function emit(name, text)
	print("N1_BEGIN:"..name); io.write(text); print("N1_END:"..name);
end

local host, client, swapped = peer(), peer({client = true}), peer({client = true, swapped = true});
for _, p in ipairs({host, client, swapped}) do p:act(); end
assert(not host.env.MKMP_RUNTIME.available, "nil native world value must not mean ready");
emit("HOST", host:text()); emit("CLIENT", client:text()); emit("SWAPPED", swapped:text());

local state = host.env.MKMP_War_Weariness_Get_State();
state.values.mk_fact_a, state.completed_phase.mk_fact_a = 100, 999;
assert(host.env.PLAYER_WAR_WEARINESS.mk_fact_a == 0, "snapshot aliased live WW values");
local mutations = host.mutations;
host.env.FactionTurnStart_WW(host.context);
assert(host.mutations == mutations, "snapshot aliased private completion ledger");

for _, p in ipairs({host, client}) do
	local draws_before = p.draws;
	p.debug_load();
	assert(p.draws == draws_before, "diagnostics segment entry consumed campaign RNG");
	p.turn = 2; p:act();
end
emit("HOST_LOAD", host:text()); emit("CLIENT_LOAD", client:text());

local missing = peer(); missing:act();
assert(missing.env.MKMP_Debug_Register_State_Provider("missing", function() return nil, "unavailable", "not_initialized" end));
missing:barrier("missing_provider"); emit("MISSING", missing:text());

local bad = peer();
bad.env.MKMP_Debug_Log("reserved_test", {v = 9, seq = 99, turn = 999, event = "runtime",
	trace_schema = 9, segment = 99, run_id = "forged"});
emit("RESERVED", bad:text());
bad.fail_io = true;
bad.env.FactionTurnStart_WW(bad.context);
assert(bad.env.PLAYER_WAR_WEARINESS_TURNS_AT_WAR.mk_fact_a == 1);
assert(not bad.env.MKMP_DEBUG.enabled, "log failure did not disable diagnostics");

local e = client.env;
local cycle = {}; cycle.self = cycle;
assert(e.MKMP_Fingerprint_Capture(cycle).reason == "cycle");
assert(not e.MKMP_Fingerprint_Capture({bad = function() end}).complete);
assert(not e.MKMP_Fingerprint_Capture({huge = string.rep("x", 65537)}).complete);
local a = {z = "\0\1\n|\\\255", a = 0.1, [1] = true, ["1"] = false};
local b = {["1"] = false, [1] = true, a = 0.1, z = "\0\1\n|\\\255"};
local ca, cb = e.MKMP_Fingerprint_Capture(a), e.MKMP_Fingerprint_Capture(b);
assert(ca.complete and cb.complete and ca.payload == cb.payload and ca.checksum == cb.checksum);
assert(e.MKMP_Fingerprint_Checksum("Wikipedia") == "adler32-v1:11e60398");
print("N1_PAYLOAD:"..ca.payload);

for _, count in ipairs({false, "2", -1, 0, 1.5, 4097}) do
	assert(not peer({native_count = count}).env.MKMP_RUNTIME.available);
end
assert(peer({native_count = 2}).env.MKMP_RUNTIME.available);
print("PASS production Lua N1 diagnostics (repository interfaces only)");
