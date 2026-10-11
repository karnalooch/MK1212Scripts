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
	module_loaded = false,
	reason = "not_initialized",
	module = nil,
	game_name = "unknown",
	game_build = "unknown",
	twdll_sha = "unknown",
	native_faction_count = nil
};

local function MKMP_Runtime_Log_Internal(message)
	local text = "[MKMP][RUNTIME] "..tostring(message);

	if MKMP_Debug_Log then
		MKMP_Debug_Log(
			"runtime",
			{
				message = message,
				available = MKMP_RUNTIME.available,
				reason = MKMP_RUNTIME.reason
			}
		);
	end

	if MKMP_RUNTIME.module
	and type(MKMP_RUNTIME.module.core) == "table"
	and type(MKMP_RUNTIME.module.core.Log) == "function" then
		local ok = pcall(MKMP_RUNTIME.module.core.Log, text);

		if ok then
			return;
		end
	end

	if type(dev) == "table" and type(dev.log) == "function" then
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

local function MKMP_Runtime_Initialize_Internal()
	if MKMP_RUNTIME.initialized then
		return MKMP_RUNTIME.available;
	end

	MKMP_RUNTIME.initialized = true;

	if not package or type(package.loadlib) ~= "function" then
		MKMP_RUNTIME.reason = "package.loadlib_unavailable";
		MKMP_Runtime_Log_Internal(MKMP_RUNTIME.reason);
		return false;
	end

	local load_ok, loader, load_error = pcall(
		package.loadlib,
		"twdll_attila.dll",
		"luaopen_twdll"
	);

	if not load_ok then
		MKMP_RUNTIME.reason = "loadlib_error:"..tostring(loader);
		MKMP_Runtime_Log_Internal(MKMP_RUNTIME.reason);
		return false;
	end

	if type(loader) ~= "function" then
		MKMP_RUNTIME.reason = "dll_unavailable:"..tostring(load_error);
		MKMP_Runtime_Log_Internal(MKMP_RUNTIME.reason);
		return false;
	end

	local open_ok, module_or_error = pcall(loader);

	if not open_ok or type(module_or_error) ~= "table" then
		MKMP_RUNTIME.reason = "luaopen_failed:"..tostring(module_or_error);
		MKMP_Runtime_Log_Internal(MKMP_RUNTIME.reason);
		return false;
	end

	MKMP_RUNTIME.module = module_or_error;
	MKMP_RUNTIME.module_loaded = true;

	if type(MKMP_RUNTIME.module.core) == "table" then
		-- The current native GameBuild function returns GAME_NAME ("Attila"),
		-- not an executable version/hash. Exact binary identity belongs to the
		-- external preflight and must never be inferred from successful loading.
		local game_name = MKMP_Runtime_Call(MKMP_RUNTIME.module.core.GameBuild);

		if game_name then
			MKMP_RUNTIME.game_name = tostring(game_name);
		end

		local twdll_sha = MKMP_Runtime_Call(MKMP_RUNTIME.module.core.GetBuildSha);

		if twdll_sha then
			MKMP_RUNTIME.twdll_sha = tostring(twdll_sha);
		end
	end

	if type(MKMP_RUNTIME.module.world) == "table" then
		local faction_count = MKMP_Runtime_Call(MKMP_RUNTIME.module.world.GetFactionCount);

		if type(faction_count) == "number" and faction_count == faction_count
			and faction_count >= 1 and faction_count <= 4096 and faction_count == math.floor(faction_count) then
			MKMP_RUNTIME.native_faction_count = faction_count;
		end
	end

	MKMP_RUNTIME.available = MKMP_RUNTIME.native_faction_count ~= nil;
	MKMP_RUNTIME.reason = MKMP_RUNTIME.available and "ready" or "world_capability_unavailable";

	MKMP_Runtime_Log_Internal(
		MKMP_RUNTIME.reason.." game_name="..MKMP_RUNTIME.game_name..
		" game_build=unknown exact_environment=external_preflight_required"..
		" twdll_sha="..MKMP_RUNTIME.twdll_sha..
		" factions="..tostring(MKMP_RUNTIME.native_faction_count)
	);

	return MKMP_RUNTIME.available;
end

function MKMP_Runtime_Initialize()
	local ok, result = pcall(MKMP_Runtime_Initialize_Internal);
	if not ok then
		MKMP_RUNTIME.available = false;
		MKMP_RUNTIME.reason = "initialize_exception";
		pcall(MKMP_Runtime_Log_Internal, MKMP_RUNTIME.reason);
		return false;
	end
	return result;
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
			"schema=2",
			"multiplayer="..tostring(cm:is_multiplayer()),
			"game_name="..tostring(MKMP_RUNTIME.game_name),
			"game_build="..tostring(MKMP_RUNTIME.game_build),
			"exact_environment=external_preflight_required",
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

	table.sort(factions, function(a, b)
		for i = 1, math.min(#a, #b) do
			local first, second = string.byte(a, i), string.byte(b, i);
			if first ~= second then return first < second; end
		end
		return #a < #b;
	end);

	for i = 1, #factions do
		table.insert(parts, factions[i]);
	end

	return table.concat(parts, "|");
end

function MKMP_Runtime_Get_Region_Ownership_Snapshot()
	-- Use the campaign scripting interface, independently of native DLL state.
	-- The world region list includes all regions; faction counts alone cannot
	-- detect two swapped owners. Null interfaces are incomplete evidence.
	local ok, result, status, reason = pcall(function()
		local regions = cm:model():world():region_manager():region_list();
		local count = regions:num_items();
		if type(count) ~= "number" or count ~= count or count < 1
			or count > 4096 or count ~= math.floor(count) then
			return nil, "incomplete", "region_count_invalid";
		end
		local owners = {};
		for i = 0, count - 1 do
			local region = regions:item_at(i);
			if not region or region:is_null_interface() then return nil, "incomplete", "region_unavailable"; end
			local name, owner = region:name(), region:owning_faction();
			if type(name) ~= "string" or name == "" or owners[name] ~= nil then
				return nil, "incomplete", "region_identity_invalid";
			end
			if not owner or owner:is_null_interface() then return nil, "incomplete", "region_owner_unavailable"; end
			local owner_name = owner:name();
			if type(owner_name) ~= "string" or owner_name == "" then
				return nil, "incomplete", "region_owner_invalid";
			end
			owners[name] = owner_name;
		end
		return {schema = 1, region_count = count, owners = owners}, "complete";
	end);
	if not ok then return nil, "unavailable", "region_interface_unavailable"; end
	return result, status, reason;
end

function MKMP_Runtime_Get_Campaign_Fingerprint()
	local snapshot, status, reason = MKMP_Runtime_Get_Region_Ownership_Snapshot();
	if status ~= "complete" or type(MKMP_Fingerprint_Capture) ~= "function" then
		return {
			schema = "mkfp-table-v1", complete = false,
			status = status ~= "complete" and status or "unavailable",
			reason = reason or "fingerprint_module_missing"
		};
	end
	return MKMP_Fingerprint_Capture(snapshot);
end

function MKMP_Runtime_Get_Battle_Telemetry()
	if not MKMP_RUNTIME.available
	or not MKMP_RUNTIME.module
	or type(MKMP_RUNTIME.module.battle) ~= "table"
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
	if MKMP_Debug_Barrier then
		pcall(MKMP_Debug_Barrier, name, {stage = "handler_entry", listener = "MKMP_Runtime_Log_Barrier"});
	end
end

function MKMP_Runtime_Status()
	return {
		initialized = MKMP_RUNTIME.initialized,
		available = MKMP_RUNTIME.available,
		module_loaded = MKMP_RUNTIME.module_loaded,
		reason = MKMP_RUNTIME.reason,
		game_name = MKMP_RUNTIME.game_name,
		game_build = MKMP_RUNTIME.game_build,
		exact_environment = "external_preflight_required",
		twdll_sha = MKMP_RUNTIME.twdll_sha,
		native_faction_count = MKMP_RUNTIME.native_faction_count
	};
end
