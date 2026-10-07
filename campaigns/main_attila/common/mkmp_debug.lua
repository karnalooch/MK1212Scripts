------------------------------------------------------------------------------------------------------------------------
------------------------------------------------------------------------------------------------------------------------
--
-- MK1212 MULTIPLAYER FILE DEBUG LOG
--
-- Diagnostics-only, append-only and fail-soft.
-- This file is an output sink only: log contents MUST NEVER drive gameplay.
--
------------------------------------------------------------------------------------------------------------------------
------------------------------------------------------------------------------------------------------------------------

MKMP_DEBUG_SCHEMA = 1;
MKMP_DEBUG_LOG_PATH = "MK1212_mp_debug.log";
MKMP_DEBUG_MAX_ENTRIES = 100000;
MKMP_DEBUG_MAX_BYTES = 16777216; -- 16 MiB. Existing data is preserved; logging stops at the budget.

MKMP_DEBUG = {
	initialized = false,
	enabled = false,
	sequence = 0,
	entries = 0,
	bytes = 0,
	reason = "not_initialized"
};

local function MKMP_Debug_Escape(value)
	local text = tostring(value);

	text = string.gsub(text, "\\", "\\\\");
	text = string.gsub(text, "|", "\\|");
	text = string.gsub(text, "\r", "\\r");
	text = string.gsub(text, "\n", "\\n");
	text = string.gsub(text, "\t", "\\t");

	return text;
end

local function MKMP_Debug_SortedKeys(tab)
	local keys = {};

	for key, _ in pairs(tab) do
		table.insert(keys, key);
	end

	table.sort(
		keys,
		function(a, b)
			return tostring(a) < tostring(b);
		end
	);

	return keys;
end

local function MKMP_Debug_SafeTurn()
	if not cm or not cm.model then
		return "unknown";
	end

	local ok, result = pcall(
		function()
			return cm:model():turn_number();
		end
	);

	if not ok or result == nil then
		return "unknown";
	end

	return tostring(result);
end

local function MKMP_Debug_SafeLocalFaction()
	if not cm or not cm.get_local_faction then
		return "unknown";
	end

	local ok, result = pcall(
		function()
			return cm:get_local_faction();
		end
	);

	if not ok or result == nil or result == "" then
		return "unknown";
	end

	return tostring(result);
end

local function MKMP_Debug_ReadExistingSize()
	if not io or type(io.open) ~= "function" then
		return 0;
	end

	local file = io.open(MKMP_DEBUG_LOG_PATH, "rb");

	if not file then
		return 0;
	end

	local size = 0;
	local ok, result = pcall(
		function()
			return file:seek("end");
		end
	);

	pcall(
		function()
			file:close();
		end
	);

	if ok and result then
		size = tonumber(result) or 0;
	end

	return size;
end

local function MKMP_Debug_Disable(reason)
	MKMP_DEBUG.enabled = false;
	MKMP_DEBUG.reason = tostring(reason or "disabled");
end

local function MKMP_Debug_WriteLine(line)
	if not MKMP_DEBUG.enabled then
		return false;
	end

	if MKMP_DEBUG.entries >= MKMP_DEBUG_MAX_ENTRIES then
		MKMP_Debug_Disable("entry_budget_exhausted");
		return false;
	end

	local bytes = string.len(line) + 1;

	if MKMP_DEBUG.bytes + bytes > MKMP_DEBUG_MAX_BYTES then
		MKMP_Debug_Disable("byte_budget_exhausted");
		return false;
	end

	local file, open_error = io.open(MKMP_DEBUG_LOG_PATH, "a");

	if not file then
		MKMP_Debug_Disable("open_failed:"..tostring(open_error));
		return false;
	end

	local write_ok, write_error = pcall(
		function()
			file:write(line);
			file:write("\n");
			file:flush();
		end
	);

	pcall(
		function()
			file:close();
		end
	);

	if not write_ok then
		MKMP_Debug_Disable("write_failed:"..tostring(write_error));
		return false;
	end

	MKMP_DEBUG.entries = MKMP_DEBUG.entries + 1;
	MKMP_DEBUG.bytes = MKMP_DEBUG.bytes + bytes;

	return true;
end

function MKMP_Debug_Initialize()
	if MKMP_DEBUG.initialized then
		return MKMP_DEBUG.enabled;
	end

	MKMP_DEBUG.initialized = true;

	if not io or type(io.open) ~= "function" then
		MKMP_Debug_Disable("io_unavailable");
		return false;
	end

	MKMP_DEBUG.bytes = MKMP_Debug_ReadExistingSize();

	if MKMP_DEBUG.bytes >= MKMP_DEBUG_MAX_BYTES then
		MKMP_Debug_Disable("existing_log_at_budget");
		return false;
	end

	MKMP_DEBUG.enabled = true;
	MKMP_DEBUG.reason = "ready";

	MKMP_Debug_Log(
		"session_begin",
		{
			schema = MKMP_DEBUG_SCHEMA,
			path = MKMP_DEBUG_LOG_PATH,
			existing_bytes = MKMP_DEBUG.bytes,
			multiplayer = cm and cm.is_multiplayer and cm:is_multiplayer() or false,
			local_faction = MKMP_Debug_SafeLocalFaction()
		}
	);

	return MKMP_DEBUG.enabled;
end

function MKMP_Debug_Log(event_name, payload)
	if not MKMP_DEBUG.initialized then
		return false;
	end

	if not MKMP_DEBUG.enabled then
		return false;
	end

	local next_sequence = MKMP_DEBUG.sequence + 1;
	local parts = {
		"MKMP",
		"v="..tostring(MKMP_DEBUG_SCHEMA),
		"seq="..tostring(next_sequence),
		"turn="..MKMP_Debug_Escape(MKMP_Debug_SafeTurn()),
		"event="..MKMP_Debug_Escape(event_name or "unknown")
	};

	if type(payload) == "table" then
		local keys = MKMP_Debug_SortedKeys(payload);

		for i = 1, #keys do
			local key = keys[i];
			local value = payload[key];

			if value ~= nil then
				table.insert(
					parts,
					MKMP_Debug_Escape(key).."="..MKMP_Debug_Escape(value)
				);
			end
		end
	elseif payload ~= nil then
		table.insert(parts, "message="..MKMP_Debug_Escape(payload));
	end

	local line = table.concat(parts, "|");

	if MKMP_Debug_WriteLine(line) then
		MKMP_DEBUG.sequence = next_sequence;
		return true;
	end

	return false;
end

function MKMP_Debug_Barrier(name, payload)
	local data = {};

	if type(payload) == "table" then
		for key, value in pairs(payload) do
			data[key] = value;
		end
	end

	data.name = name;

	if MKMP_Runtime_Get_Campaign_Fingerprint then
		local ok, fingerprint = pcall(MKMP_Runtime_Get_Campaign_Fingerprint);

		if ok and fingerprint ~= nil then
			data.fingerprint = fingerprint;
		end
	end

	return MKMP_Debug_Log("barrier", data);
end

function MKMP_Debug_Status()
	return {
		initialized = MKMP_DEBUG.initialized,
		enabled = MKMP_DEBUG.enabled,
		reason = MKMP_DEBUG.reason,
		path = MKMP_DEBUG_LOG_PATH,
		sequence = MKMP_DEBUG.sequence,
		entries = MKMP_DEBUG.entries,
		bytes = MKMP_DEBUG.bytes,
		max_entries = MKMP_DEBUG_MAX_ENTRIES,
		max_bytes = MKMP_DEBUG_MAX_BYTES
	};
end
