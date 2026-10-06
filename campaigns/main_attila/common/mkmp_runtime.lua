------------------------------------------------------------------------------------------------------------------------
------------------------------------------------------------------------------------------------------------------------
--
-- MK1212 MULTIPLAYER RUNTIME OBSERVABILITY ADAPTER
--
-- Optional, read-only-first bridge around twdll_attila.dll.
-- Gameplay must continue unchanged when the DLL is absent or incompatible.
--
------------------------------------------------------------------------------------------------------------------------
------------------------------------------------------------------------------------------------------------------------

MKMP_RUNTIME = {
	initialized = false,
	available = false,
	reason = "not_initialized",
	module = nil,
	game_build = "unknown",
	twdll_sha = "unknown",
	native_faction_count = nil
};

function MKMP_Runtime_Log(message)
	local text = "[MKMP][RUNTIME] "..tostring(message);

	if MKMP_RUNTIME.module
	and MKMP_RUNTIME.module.core
	and type(MKMP_RUNTIME.module.core.Log) == "function" then
		local ok = pcall(MKMP_RUNTIME.module.core.Log, text);

		if ok then
			return;
		end
	end

	if dev and dev.log then
		dev.log(text);
	end
end

local function MKMP_Runtime_Call(fn, ...)
	if type(fn) ~= "function" then
		return nil, "capability_missing";
	end

	local ok, result = pcall(fn, ...);

	if not ok then
		return nil, tostring(result);
	end

	return result, nil;
end

function MKMP_Runtime_Initialize()
	if MKMP_RUNTIME.initialized then
		return MKMP_RUNTIME.available;
	end

	MKMP_RUNTIME.initialized = true;

	if not package or type(package.loadlib) ~= "function" then
		MKMP_RUNTIME.reason = "package.loadlib_unavailable";
		MKMP_Runtime_Log(MKMP_RUNTIME.reason);
		return false;
	end

	local load_ok, loader, load_error = pcall(
		package.loadlib,
		"twdll_attila.dll",
		"luaopen_twdll"
	);

	if not load_ok then
		MKMP_RUNTIME.reason = "loadlib_error:"..tostring(loader);
		MKMP_Runtime_Log(MKMP_RUNTIME.reason);
		return false;
	end

	if type(loader) ~= "function" then
		MKMP_RUNTIME.reason = "dll_unavailable:"..tostring(load_error);
		MKMP_Runtime_Log(MKMP_RUNTIME.reason);
		return false;
	end

	local open_ok, module_or_error = pcall(loader);

	if not open_ok or type(module_or_error) ~= "table" then
		MKMP_RUNTIME.reason = "luaopen_failed:"..tostring(module_or_error);
		MKMP_Runtime_Log(MKMP_RUNTIME.reason);
		return false;
	end

	MKMP_RUNTIME.module = module_or_error;

	if MKMP_RUNTIME.module.core then
		local game_build = MKMP_Runtime_Call(MKMP_RUNTIME.module.core.GameBuild);

		if game_build then
			MKMP_RUNTIME.game_build = tostring(game_build);
		end

		local twdll_sha = MKMP_Runtime_Call(MKMP_RUNTIME.module.core.GetBuildSha);

		if twdll_sha then
			MKMP_RUNTIME.twdll_sha = tostring(twdll_sha);
		end
	end

	if MKMP_RUNTIME.module.world then
		local faction_count = MKMP_Runtime_Call(MKMP_RUNTIME.module.world.GetFactionCount);

		if faction_count ~= nil then
			MKMP_RUNTIME.native_faction_count = tonumber(faction_count);
		end
	end

	MKMP_RUNTIME.available = true;
	MKMP_RUNTIME.reason = "ready";

	MKMP_Runtime_Log(
		"ready game="..MKMP_RUNTIME.game_build..
		" twdll_sha="..MKMP_RUNTIME.twdll_sha..
		" factions="..tostring(MKMP_RUNTIME.native_faction_count)
	);

	return true;
end

function MKMP_Runtime_Available()
	return MKMP_RUNTIME.initialized and MKMP_RUNTIME.available;
end

function MKMP_Runtime_Get_Environment_Fingerprint()
	local limits = "slots10=unknown";

	if MK1212_Get_Hardcoded_Limits_Fingerprint then
		limits = MK1212_Get_Hardcoded_Limits_Fingerprint();
	end

	return table.concat(
		{
			"schema=1",
			"multiplayer="..tostring(cm:is_multiplayer()),
			"game="..tostring(MKMP_RUNTIME.game_build),
			"twdll="..tostring(MKMP_RUNTIME.twdll_sha),
			limits
		},
		"|"
	);
end

function MKMP_Runtime_Get_Campaign_Snapshot()
	local parts = {
		"snapshot_schema=1",
		"turn="..tostring(cm:model():turn_number())
	};
	local factions = {};
	local faction_list = cm:model():world():faction_list();

	for i = 0, faction_list:num_items() - 1 do
		local faction = faction_list:item_at(i);

		if faction and not faction:is_null_interface() then
			local name = faction:name();
			local region_count = faction:region_list():num_items();
			local force_count = faction:military_force_list():num_items();
			local character_count = faction:character_list():num_items();
			local religion = faction:state_religion();

			table.insert(
				factions,
				name..
				":r="..tostring(region_count)..
				":f="..tostring(force_count)..
				":c="..tostring(character_count)..
				":rel="..tostring(religion)
			);
		end
	end

	table.sort(factions);

	for i = 1, #factions do
		table.insert(parts, factions[i]);
	end

	return table.concat(parts, "|");
end

function MKMP_Runtime_Hash_String(value)
	local text = tostring(value or "");
	local hash = 0;

	-- Keep arithmetic comfortably below Lua's exact-integer range for doubles.
	for i = 1, string.len(text) do
		hash = (hash * 131 + string.byte(text, i)) % 2147483647;
	end

	return tostring(hash);
end

function MKMP_Runtime_Get_Campaign_Fingerprint()
	return MKMP_Runtime_Hash_String(MKMP_Runtime_Get_Campaign_Snapshot());
end

function MKMP_Runtime_Get_Battle_Telemetry()
	if not MKMP_RUNTIME.available
	or not MKMP_RUNTIME.module
	or not MKMP_RUNTIME.module.battle
	or type(MKMP_RUNTIME.module.battle.GetBattleInfo) ~= "function" then
		return nil;
	end

	local info, err = MKMP_Runtime_Call(MKMP_RUNTIME.module.battle.GetBattleInfo);

	if err or type(info) ~= "table" then
		return nil;
	end

	-- Deliberately drop process-local memory addresses returned by twdll.
	return {
		cap = info.cap,
		size = info.size
	};
end

function MKMP_Runtime_Log_Barrier(name)
	MKMP_Runtime_Log(
		"barrier="..tostring(name)..
		" env="..MKMP_Runtime_Get_Environment_Fingerprint()..
		" fingerprint="..MKMP_Runtime_Get_Campaign_Fingerprint()
	);
end

function MKMP_Runtime_Status()
	return {
		initialized = MKMP_RUNTIME.initialized,
		available = MKMP_RUNTIME.available,
		reason = MKMP_RUNTIME.reason,
		game_build = MKMP_RUNTIME.game_build,
		twdll_sha = MKMP_RUNTIME.twdll_sha,
		native_faction_count = MKMP_RUNTIME.native_faction_count
	};
end
