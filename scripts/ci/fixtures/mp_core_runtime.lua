-- Execute the production codec/RNG in independent Lua environments. Engine
-- calls are explicit test doubles; these tests do not emulate Attila lockstep.
local scenario = assert(arg[1]);

local function equal(a, b, message)
	assert(a == b, (message or "not equal")..": "..tostring(a).." / "..tostring(b));
end

local function refuses(fn, message)
	local ok, error_text = pcall(fn);
	assert(not ok, "expected refusal: "..tostring(message));
	return tostring(error_text);
end

local function peer()
	local e = {saves = {}, writes = {}, logs = {}, draws = 0, loading_callbacks = {}};
	setmetatable(e, {__index = _G});
	e._G = e;
	e.cm = {
		register_loading_game_callback = function(self, fn) e.loading_callbacks[#e.loading_callbacks + 1] = fn; end,
		register_saving_game_callback = function() end,
		load_value = function(self, key, default)
			if e.saves[key] == nil then return default; end
			return e.saves[key];
		end,
		save_value = function(self, key, value)
			e.writes[#e.writes + 1] = {key, value};
			e.saves[key] = value;
		end,
		random_number = function(self, maximum, minimum)
			e.draws = e.draws + 1;
			if e.force_result then return e.result; end
			return minimum;
		end,
	};
	e.MKMP_Debug_Log = function(name, data) e.logs[#e.logs + 1] = {name, data}; end;
	e.load = function(path)
		local code = assert(loadfile("campaigns/main_attila/"..path..".lua"));
		setfenv(code, e);
		code();
	end;
	e.require = function(name)
		if name == "common/mkmp_persistence" then e.load(name); end
		return {};
	end;
	e.load("common/mk1212_common");
	return e;
end

if scenario == "roundtrip" then
	local host, client = peer(), peer();
	local strange = "Nowe, miasto; 100% — Łódź\n\t";
	local input = {["z"] = "", ["a,;%"] = strange, [""] = "%E"};
	local reversed = {[""] = "%E", ["a,;%"] = strange, ["z"] = ""};
	host.SaveKeyPairTable(nil, input, "names");
	client.SaveKeyPairTable(nil, reversed, "names");
	equal(host.saves.names, client.saves.names, "canonical bytes");
	equal(host.saves.names__schema, 3);
	local restored = host.LoadKeyPairTable(nil, "names");
	for key, value in pairs(input) do equal(restored[key], value, "literal scalar"); end
	host.SaveKeyPairTable(nil, restored, "names");
	equal(host.saves.names, client.saves.names, "save/load/save bytes");
	host.SaveTable(nil, {"", "%E", strange, "\0\1\127"}, "array");
	local array = host.LoadTable(nil, "array");
	equal(#array, 4); equal(array[1], ""); equal(array[2], "%E"); equal(array[3], strange); equal(array[4], "\0\1\127");
	host.SaveBooleanPairTable(nil, {yes = true, no = false}, "flags");
	local flags = host.LoadBooleanPairTable(nil, "flags"); equal(flags.yes, true); equal(flags.no, false);
	host.SaveKeyPairTables(nil, {empty = {}, items = {strange, ""}}, "nested");
	local nested = host.LoadKeyPairTables(nil, "nested"); equal(#nested.empty, 0); equal(nested.items[1], strange); equal(nested.items[2], "");
	local precision = 0.12345678901234567;
	host.SaveKeyPairTable(nil, {growth = precision, debt = -15}, "numbers");
	equal(host.LoadKeyPairTableNumbers(nil, "numbers").growth, precision, "Lua numeric precision");
	equal(host.MK1212_SaveChecksum("Wikipedia"), "adler32-v1:11e60398", "standard checksum test vector");
	local first = host.logs[#host.logs][2].checksum;
	host.SaveKeyPairTable(nil, {growth = precision, debt = -16}, "numbers");
	assert(first ~= host.logs[#host.logs][2].checksum, "equal length values need distinct diagnostic checksums");
elseif scenario == "legacy" then
	local e = peer();
	for _, schema in ipairs({0, 1, 2}) do
		e.saves.old__schema = schema == 0 and nil or schema;
		e.saves.old = "city,100%2C,;zero,0,;";
		local old = e.LoadKeyPairTable(nil, "old");
		equal(old.city, "100%2C", "legacy percent not decoded"); equal(old.zero, "0");
		e.SaveKeyPairTable(nil, old, "old");
		equal(e.LoadKeyPairTable(nil, "old").city, "100%2C"); equal(e.saves.old__schema, 3);
	end
	e.saves.nested = "empty,;items,one,two,;";
	local nested = e.LoadKeyPairTables(nil, "nested"); equal(#nested.empty, 0); equal(nested.items[2], "two");
	equal(#e.LoadTable(nil, "missing"), 0);
	e.saves.array = "1,2,-3,";
	local values = e.LoadTableNumbers(nil, "array"); equal(values[3], -3);
	_G.line, _G.pos = "untouched", 99;
	equal(e.SplitString("one,two,", ",")[2], "two"); equal(_G.line, "untouched"); equal(_G.pos, 99);
elseif scenario == "refusals" then
	local e = peer();
	e.SaveKeyPairTable(nil, {old = "last good"}, "value");
	local good, version, writes = e.saves.value, e.saves.value__schema, #e.writes;
	local invalid_writes = {
		function() e.SaveKeyPairTable(nil, {[1] = "a", ["1"] = "b"}, "value"); end,
		function() e.SaveTable(nil, {[1] = "a", [3] = "b"}, "value"); end,
		function() e.SaveKeyPairTable(nil, {bad = 0/0}, "value"); end,
		function() e.SaveKeyPairTable(nil, {bad = math.huge}, "value"); end,
		function() e.SaveBooleanPairTable(nil, {bad = "false"}, "value"); end,
		function() e.SaveKeyPairTable(nil, {bad = {}}, "value"); end,
		function() e.SaveTable(nil, {string.rep("x", e.MK1212_SAVE_MAX_STRING_BYTES)}, "value"); end,
		function() e.MK1212_SaveCommitString(nil, "value", "", e.MK1212_SAVE_MAX_ENTRIES + 1); end,
	};
	for _, write in ipairs(invalid_writes) do
		refuses(write); equal(e.saves.value, good); equal(e.saves.value__schema, version); equal(#e.writes, writes);
	end
	local bad = {
		{4, ""}, {"3", ""}, {3, "key,value,;"},
		{2, "key,first,;key,second,;"}, {2, "key,missing_terminator"},
		{3, "MK1212_SAVE_V3|key,%XX,;"}, {3, "MK1212_SAVE_V3|key,%41,;"},
		{3, "MK1212_SAVE_V3|key,,;"}, {2, 42},
	};
	for _, record in ipairs(bad) do
		e.saves.bad__schema, e.saves.bad = record[1], record[2];
		refuses(function() e.LoadKeyPairTable(nil, "bad"); end);
	end
	e.saves.bad__schema, e.saves.bad = 2, "key,maybe,;";
	refuses(function() e.LoadBooleanPairTable(nil, "bad"); end);
	e.saves.bad = "key,nan,;"; refuses(function() e.LoadKeyPairTableNumbers(nil, "bad"); end);
	e.saves.bad = "key,inf,;"; refuses(function() e.LoadKeyPairTableNumbers(nil, "bad"); end);
	e.saves.bad = string.rep("x", e.MK1212_SAVE_MAX_STRING_BYTES + 1);
	refuses(function() e.LoadKeyPairTable(nil, "bad"); end);
	e.FACTION_TURN, e.FACTIONS_TO_RELIGIONS = "existing", {existing = "religion"};
	e.saves.FACTION_TURN = "replacement";
	e.SaveKeyPairTable(nil, {replacement = "different"}, "FACTIONS_TO_RELIGIONS");
	e.saves.REGIONS_TO_TRANSFER__schema = 99;
	refuses(function() e.loading_callbacks[1](nil); end);
	equal(e.FACTION_TURN, "existing", "late load failure changed early scalar");
	equal(e.FACTIONS_TO_RELIGIONS.existing, "religion", "late load failure changed early map");
	-- Diagnostics failure must not cancel a completed valid engine write.
	e.MKMP_Debug_Log = function() error("logger unavailable"); end;
	e.SaveTable(nil, {"still saved"}, "log_failure"); equal(e.LoadTable(nil, "log_failure")[1], "still saved");
elseif scenario == "custom" then
	local e = peer();
	e.load("mechanics/population/mechanics_population");
	e.load("mechanics/decisions/mechanics_decisions");
	e.load("nicknames/nicknames_tracking");
	local populations = {z = {10, 20, 30, 40, 50}, a = {0.00123456789012345, -0.1, 0, 100, 0.25}};
	e.SavePopulationNumbersTable(nil, populations, "population");
	local pop = e.LoadPopulationNumbersTable(nil, "population");
	for k, values in pairs(populations) do for i = 1, 5 do equal(pop[k][i], values[i]); end end
	e.SaveFactionPopulationNumbersTable(nil, {z = 1, a = 2}, "faction");
	local first = e.saves.faction;
	e.SaveFactionPopulationNumbersTable(nil, {a = 2, z = 1}, "faction"); equal(e.saves.faction, first);
	equal(e.LoadFactionPopulationNumbersTable(nil, "faction").a, 2);
	e.SaveDecisionsTable(nil, {{"decision,1", "faction;A", false}, {"other", "B", true}}, "decisions");
	local decisions = e.LoadDecisionsTable(nil, "decisions"); equal(decisions[1][1], "decision,1"); equal(decisions[1][3], false); equal(decisions[2][3], true);
	local stats = {regions_taken = 1, captives_killed = 2, times_excommunicated = 3, turns_without_revolt = 4, heroic_victories = 5};
	e.SaveNicknamesStatsTable(nil, {["123"] = stats}, "nickname");
	local loaded = e.LoadNicknamesStatsTable(nil, "nickname"); for key, value in pairs(stats) do equal(loaded["123"][key], value); end
	e.saves.oldpop = "region,1,2,3,4,5,;"; equal(e.LoadPopulationNumbersTable(nil, "oldpop").region[5], 5);
	e.saves.olddecisions = "decision,faction,false,;"; equal(e.LoadDecisionsTable(nil, "olddecisions")[1][3], false);
	e.saves.oldnick = "123,1,2,3,4,5,;"; equal(e.LoadNicknamesStatsTable(nil, "oldnick")["123"].heroic_victories, 5);
	refuses(function() e.SavePopulationNumbersTable(nil, {bad = {1,2,3,4}}, "population"); end);
	e.saves.badpop = "region,1,2,x,4,5,;"; refuses(function() e.LoadPopulationNumbersTable(nil, "badpop"); end);
elseif scenario == "budgets" then
	local e = peer();
	e.MK1212_SAVE_MAX_STRING_BYTES = 256;
	local repeated = string.rep("x", 100);
	local values, mapped = {}, {};
	for i = 1, 100 do values[i] = repeated; mapped["key"..i] = repeated; end
	local calls, original = 0, e.MK1212_SaveToken;
	e.MK1212_SaveToken = function(...)
		calls = calls + 1;
		assert(calls < 12, "writer kept encoding after byte budget was exhausted");
		return original(...);
	end;
	for _, write in ipairs({
		function() e.SaveTable(nil, values, "oversized"); end,
		function() e.SaveKeyPairTable(nil, mapped, "oversized"); end,
		function() e.SaveKeyPairTables(nil, {key = values}, "oversized"); end,
	}) do
		calls = 0;
		local failure = refuses(write);
		assert(string.find(failure, "byte budget", 1, true), failure);
		equal(#e.writes, 0, "oversized output reached engine");
	end
	refuses(function() original(string.rep("%", 100)); end, "escaped bytes must be bounded too");
elseif scenario == "region_queue" then
	local e = peer();
	local missing = {is_null_interface = function() return true; end};
	local owners = {a = "ai", b = "ai"};
	local applied, immortality = {}, {};
	local function faction(key)
		if key == "missing" then return missing; end
		return {
			is_null_interface = function() return false; end,
			name = function() return key; end,
			is_human = function() return key == "human"; end
		};
	end
	local function region(key)
		if not owners[key] then return missing; end
		return {
			is_null_interface = function() return false; end,
			owning_faction = function() return faction(owners[key]); end,
			has_governor = function() return key == "a"; end,
			governor = function() return {command_queue_index = function() return 17; end}; end
		};
	end
	e.cm.model = function() return {world = function() return {
		faction_by_key = function(self, key) return faction(key); end,
		region_manager = function() return {region_by_key = function(self, key) return region(key); end}; end
	}; end}; end;
	e.cm.set_character_immortality = function(self, who, value)
		immortality[who] = value;
		if value and e.fail_enable then error("injected enable failure after mutation"); end
	end;
	e.cm.transfer_region_to_faction = function(self, key, target)
		applied[#applied + 1] = key..":"..target;
		e.Drain_Region_Transfers(); -- synchronous reentry must not double-process
		if e.fail_transfer then error("injected engine failure"); end
		owners[key] = target;
	end;
	e.FACTION_TURN = "ai";
	equal(e.Transfer_Region_To_Faction("a", "human"), true);
	equal(e.Transfer_Region_To_Faction("a", "human"), true);
	equal(e.Transfer_Region_To_Faction("b", "human"), true);
	equal(#e.REGIONS_TO_TRANSFER, 2);
	e.SaveTable(nil, e.Serialize_Region_Transfer_Queue(), "REGIONS_TO_TRANSFER");
	e.REGIONS_TO_TRANSFER = e.Load_Region_Transfer_Queue(nil);
	e.Drain_Region_Transfers(); equal(#applied, 0); equal(#e.REGIONS_TO_TRANSFER, 2);
	e.FACTION_TURN, e.fail_transfer = "other", true;
	refuses(e.Drain_Region_Transfers);
	equal(#applied, 1); equal(applied[1], "a:human");
	equal(immortality["character_cqi:17"], false, "governor cleanup after engine failure");
	equal(#e.REGIONS_TO_TRANSFER, 1); equal(e.REGIONS_TO_TRANSFER[1].region, "b", "later operation survived");
	e.fail_transfer = false;
	e.Drain_Region_Transfers(); equal(#applied, 2); equal(applied[2], "b:human");
	e.Transfer_Region_To_Faction("b", "human"); equal(#applied, 2, "already-owned region is idempotent");
	e.Queue_Region_Transfer("a", "human"); e.Queue_Region_Transfer("b", "human");
	e.fail_enable = true;
	refuses(e.Drain_Region_Transfers);
	equal(immortality["character_cqi:17"], false, "cleanup also covers partial enable failure");
	equal(#applied, 2, "failed immortality enable must not execute transfer");
	equal(#e.REGIONS_TO_TRANSFER, 1); equal(e.REGIONS_TO_TRANSFER[1].region, "b");
	e.fail_enable = false;
	e.Drain_Region_Transfers(); equal(#e.REGIONS_TO_TRANSFER, 0);
	equal(e.Transfer_Region_To_Faction("missing", "human"), false);
	equal(e.Transfer_Region_To_Faction("a", "missing"), false);
	equal(e.Queue_Region_Transfer("a|b", "human"), false);
	e.saves.REGIONS_TO_TRANSFER__schema = nil;
	e.saves.REGIONS_TO_TRANSFER = "human|a,human|a,human|b,";
	local deduped = e.Load_Region_Transfer_Queue(nil); equal(#deduped, 2); equal(deduped[2].region, "b");
	for _, invalid in ipairs({"human|a|b,", "human|,", "missing_delimiter,", string.rep("human|a,", 65)}) do
		e.saves.REGIONS_TO_TRANSFER = invalid;
		refuses(function() e.Load_Region_Transfer_Queue(nil); end);
	end
	for i = 1, 64 do e.Queue_Region_Transfer("region"..i, "human"); end
	equal(#e.REGIONS_TO_TRANSFER, 64);
	refuses(function() e.Queue_Region_Transfer("region65", "human"); end);
	equal(#e.REGIONS_TO_TRANSFER, 64);
elseif scenario == "logger" then
	for _, mode in ipairs({"normal", "read_throw", "open_throw", "open_nil", "write_throw", "write_nil", "flush_nil"}) do
		local e = peer();
		local lines = {};
		local file = {
			write = function(self, text)
				if mode == "write_throw" then error("write unavailable"); end
				if mode == "write_nil" then return nil, "disk full"; end
				lines[#lines + 1] = text; return self;
			end,
			flush = function() if mode == "flush_nil" then return nil, "disk full"; end return true; end,
			close = function() return true; end
		};
		e.io = {open = function(path, access)
			if access == "rb" then
				if mode == "read_throw" then error("read unavailable"); end
				return nil;
			end
			if mode == "open_throw" then error("open unavailable"); end
			if mode == "open_nil" then return nil, "access denied"; end
			return file;
		end};
		e.cm.is_multiplayer = function() return true; end;
		e.cm.model = function() return {turn_number = function() return 2; end}; end;
		e.MKMP_PACK_ID = {source = string.rep("a", 40), profile = "full-experimental"};
		e.load("common/mkmp_debug");
		e.MKMP_Debug_Initialize();
		equal(e.MK1212_Random_Int(1, 8, "logger_failure"), 1, mode);
		equal(e.draws, 1, "logger must not retry RNG");
		e.SaveTable(nil, {"saved"}, "diagnostics"); equal(e.LoadTable(nil, "diagnostics")[1], "saved");
		if mode == "normal" then
			local log = table.concat(lines);
			assert(string.find(log, "event=content_identity", 1, true));
			assert(string.find(log, "profile=full-experimental", 1, true));
			e.MKMP_Debug_Log("bad_format", {value = setmetatable({}, {__tostring = function() error("bad formatter"); end})});
		end
		equal(e.MKMP_DEBUG.enabled, false, "failure must disable diagnostics");
	end
elseif scenario == "difficulty" then
	local host, client = peer(), peer();
	local function prepare(e, level, multiplayer)
		e.cm.is_multiplayer = function() return multiplayer; end;
		e.cm.model = function() return {difficulty_level = function()
			assert(not multiplayer, "MP read peer-local difficulty"); return level;
		end}; end;
		e.cm.create_force = function(self, faction, units) e.units = units; end;
		e.cm.apply_effect_bundle_to_characters_force = function() end;
		e.cm.disable_movement_for_character = function() end;
		e.cm.set_character_immortality = function() end;
		e.cm.award_experience_level = function(self, character, xp) e.xp = xp; end;
		e.load("mechanics/pope/mechanics_pope_crusades");
	end
	prepare(host, 1, true); prepare(client, -3, true);
	host.CreateCivilWarArmy("region", "english", "rebels", "id", 1, 2);
	client.CreateCivilWarArmy("region", "english", "rebels", "id", 1, 2);
	equal(host.units, client.units, "MP rebel army composition");
	host.Crusade_Defense_Force(10); client.Crusade_Defense_Force(10);
	equal(host.xp, client.xp, "MP crusade defense experience"); equal(host.xp, 2);
	prepare(host, 1, false); prepare(client, -3, false);
	host.CreateCivilWarArmy("region", "english", "rebels", "id", 1, 2);
	client.CreateCivilWarArmy("region", "english", "rebels", "id", 1, 2);
	assert(host.units ~= client.units, "SP selected difficulty must retain army scaling");
	host.Crusade_Defense_Force(10); client.Crusade_Defense_Force(10);
	equal(host.xp, 1); equal(client.xp, 5);
elseif scenario == "rng" then
	local e = peer();
	for _, bounds in ipairs({{1.5, 2}, {0/0, 2}, {1, math.huge}, {"1", 2}, {3, 2}}) do
		refuses(function() e.MK1212_Random_Int(bounds[1], bounds[2], "invalid"); end);
	end
	equal(e.draws, 0, "invalid bounds must not consume engine RNG");
	for _, value in ipairs({0/0, math.huge, -math.huge, 1.5, "2", false, 10}) do
		e.force_result, e.result = true, value;
		refuses(function() e.MK1212_Random_Int(1, 8, "invalid-result"); end);
	end
	e.force_result, e.result = true, nil;
	refuses(function() e.MK1212_Random_Int(1, 8, "nil-result"); end);
	e.force_result = false;
	equal(e.MK1212_Random_Int(16, 30, "heir"), 16);
	equal(e.MK1212_Random_Int(-3, -1, "negative"), -3);
	e.MKMP_Debug_Log = function() error("injected logger failure"); end;
	e.dev = {log = function() error("injected dev logger failure"); end};
	e.cm.model = function() error("diagnostic turn lookup unavailable"); end;
	local before = e.draws;
	equal(e.MK1212_Random_Int(2, 4, "failed_logger"), 2);
	equal(e.draws, before + 1);
else
	error("unknown fixture scenario "..scenario);
end
print("PASS core-production-lua "..scenario);
