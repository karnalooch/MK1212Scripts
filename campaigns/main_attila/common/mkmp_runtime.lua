------------------------------------------------------------------------------------------------------------------------
------------------------------------------------------------------------------------------------------------------------
--
-- MK1212 MULTIPLAYER RUNTIME OBSERVABILITY ADAPTER
--
-- Optional, read-only-first bridge around twdll for both single-player diagnostics and multiplayer observability.
-- Gameplay must continue unchanged when the DLL is absent, incompatible, or faults during initialization.
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
	native_faction_count = nil,
	load_candidate = "none",
	load_attempts = 0,
	luaopen_calls = 0,
	initialize_calls = 0,
	last_load_error = nil
};

local MKMP_RUNTIME_EXPECTED_GAME = "Attila";
local MKMP_RUNTIME_LOAD_CANDIDATES = {
	"twdll_attila.dll",
	"twdll",
	"twdll.dll"
};

local function MKMP_Runtime_Log_Internal(message)
	local text = "[MKMP][RUNTIME] "..tostring(message);

	if MKMP_Debug_Log then
		pcall(
			MKMP_Debug_Log,
			"runtime",
			{
				message = message,
				available = MKMP_RUNTIME.available,
				reason = MKMP_RUNTIME.reason,
				load_candidate = MKMP_RUNTIME.load_candidate,
				twdll_sha = MKMP_RUNTIME.twdll_sha
			}
		);
	end

	if MKMP_RUNTIME.module
	and MKMP_RUNTIME.module.core
	and type(MKMP_RUNTIME.module.core.Log) == "function" then
		local ok = pcall(MKMP_RUNTIME.module.core.Log, text);

		if ok then
			return;
		end
	end

	if dev and dev.log then
		pcall(dev.log, text);
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

local function MKMP_Runtime_Set_Unavailable(reason)
	MKMP_RUNTIME.available = false;
	MKMP_RUNTIME.reason = tostring(reason or "unavailable");
	MKMP_RUNTIME.module = nil;

	MKMP_Runtime_Log_Internal(MKMP_RUNTIME.reason);

	return false;
end

local function MKMP_Runtime_Load_Module()
	if not package or type(package.loadlib) ~= "function" then
		return nil, "package.loadlib_unavailable";
	end

	for i = 1, #MKMP_RUNTIME_LOAD_CANDIDATES do
		local candidate = MKMP_RUNTIME_LOAD_CANDIDATES[i];

		MKMP_RUNTIME.load_attempts = MKMP_RUNTIME.load_attempts + 1;

		local load_ok, loader, load_error = pcall(
			package.loadlib,
			candidate,
			"luaopen_twdll"
		);

		if not load_ok then
			MKMP_RUNTIME.last_load_error =
				"loadlib_error:"..candidate..":"..tostring(loader);
		elseif type(loader) == "function" then
			MKMP_RUNTIME.load_candidate = candidate;
			MKMP_RUNTIME.luaopen_calls = MKMP_RUNTIME.luaopen_calls + 1;

			local open_ok, module_or_error = pcall(loader);

			if not open_ok then
				return nil, "luaopen_failed:"..candidate..":"..tostring(module_or_error);
			end

			if type(module_or_error) ~= "table" then
				return nil, "luaopen_invalid_module:"..candidate;
			end

			return module_or_error, nil;
		else
			MKMP_RUNTIME.last_load_error =
				"dll_unavailable:"..candidate..":"..tostring(load_error or loader);
		end
	end

	return nil, MKMP_RUNTIME.last_load_error or "dll_unavailable";
end

local function MKMP_Runtime_Validate_Core(module)
	if type(module.core) ~= "table" then
		return false, "capability_missing:core";
	end

	for _, capability in ipairs(
		{
			"Log",
			"GameBuild",
			"GetBuildSha"
		}
	) do
		if type(module.core[capability]) ~= "function" then
			return false, "capability_missing:core."..capability;
		end
	end

	local game_build, game_error = MKMP_Runtime_Call(module.core.GameBuild);

	if game_error or game_build == nil then
		return false, "capability_error:core.GameBuild:"..tostring(game_error);
	end

	MKMP_RUNTIME.game_build = tostring(game_build);

	if MKMP_RUNTIME.game_build ~= MKMP_RUNTIME_EXPECTED_GAME then
		return false, "game_build_mismatch:"..MKMP_RUNTIME.game_build;
	end

	local twdll_sha, sha_error = MKMP_Runtime_Call(module.core.GetBuildSha);

	if sha_error or twdll_sha == nil then
		return false, "capability_error:core.GetBuildSha:"..tostring(sha_error);
	end

	MKMP_RUNTIME.twdll_sha = tostring(twdll_sha);

	if string.len(MKMP_RUNTIME.twdll_sha) ~= 40
	or not string.match(MKMP_RUNTIME.twdll_sha, "^[0-9a-fA-F]+$") then
		return false, "invalid_build_sha:"..MKMP_RUNTIME.twdll_sha;
	end

	return true, nil;
end

local function MKMP_Runtime_Initialize_Internal()
	local module, load_error = MKMP_Runtime_Load_Module();

	if not module then
		return MKMP_Runtime_Set_Unavailable(load_error);
	end

	-- Keep the module private until its identity contract is proven.
	MKMP_RUNTIME.module = module;

	local core_ok, core_error = MKMP_Runtime_Validate_Core(module);

	if not core_ok then
		return MKMP_Runtime_Set_Unavailable(core_error);
	end

	if module.world
	and type(module.world.GetFactionCount) == "function" then
		local faction_count = MKMP_Runtime_Call(module.world.GetFactionCount);

		if faction_count ~= nil then
			MKMP_RUNTIME.native_faction_count = tonumber(faction_count);
		end
	end

	MKMP_RUNTIME.available = true;
	MKMP_RUNTIME.reason = "ready";

	MKMP_Runtime_Log_Internal(
		"ready game="..MKMP_RUNTIME.game_build..
		" twdll_sha="..MKMP_RUNTIME.twdll_sha..
		" factions="..tostring(MKMP_RUNTIME.native_faction_count)..
		" load_candidate="..MKMP_RUNTIME.load_candidate
	);

	return true;
end

function MKMP_Runtime_Initialize()
	MKMP_RUNTIME.initialize_calls = MKMP_RUNTIME.initialize_calls + 1;

	-- One luaopen per Lua state. Save/load creates a fresh state and therefore a
	-- fresh adapter table; repeated product initializers in one state are no-ops.
	if MKMP_RUNTIME.initialized then
		return MKMP_RUNTIME.available;
	end

	MKMP_RUNTIME.initialized = true;

	local ok, result = pcall(MKMP_Runtime_Initialize_Internal);

	if not ok then
		return MKMP_Runtime_Set_Unavailable("initializer_error:"..tostring(result));
	end

	return result == true;
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
	MKMP_Runtime_Log_Internal(
		"barrier="..tostring(name)..
		" env="..MKMP_Runtime_Get_Environment_Fingerprint()..
		" state="..MKMP_Runtime_Get_Campaign_Snapshot()
	);
end

function MKMP_Runtime_Status()
	return {
		initialized = MKMP_RUNTIME.initialized,
		available = MKMP_RUNTIME.available,
		reason = MKMP_RUNTIME.reason,
		game_build = MKMP_RUNTIME.game_build,
		twdll_sha = MKMP_RUNTIME.twdll_sha,
		native_faction_count = MKMP_RUNTIME.native_faction_count,
		load_candidate = MKMP_RUNTIME.load_candidate,
		load_attempts = MKMP_RUNTIME.load_attempts,
		luaopen_calls = MKMP_RUNTIME.luaopen_calls,
		initialize_calls = MKMP_RUNTIME.initialize_calls,
		last_load_error = MKMP_RUNTIME.last_load_error
	};
end
