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
MKMP_DEBUG_TRACE_SCHEMA = 1;
MKMP_DEBUG_MAX_PROVIDERS = 16;
MKMP_DEBUG_MAX_CHECKPOINT_BYTES = 262144;
MKMP_DEBUG_MAX_RECORD_BYTES = 131072;
MKMP_DEBUG_MAX_RECORD_FIELDS = 128;

MKMP_DEBUG = {
	initialized = false,
	enabled = false,
	sequence = 0,
	entries = 0,
	bytes = 0,
	reason = "not_initialized",
	segment = 0,
	run_id = "not_initialized",
	rng_ordinal = 0,
	checkpoint = 0
};

local state_providers = {};
local state_provider_count = 0;
local last_component_payloads = {};
local lifecycle_registered = false;
local domains = { ["local"] = true, shared_candidate = true, transport = true, state = true, diagnostic = true };
local reserved_fields = {
	v = true, seq = true, turn = true, event = true, trace_schema = true,
	run_id = true, segment = true, payload_rejected = true, rng_ordinal = true,
	rng_coverage = true
};

local function MKMP_Debug_Number(value)
	if value == 0 then return "0"; end
	return (string.gsub(string.format("%.17g", value), ",", "."));
end

local function MKMP_Debug_Escape(value)
	local text = type(value) == "number" and MKMP_Debug_Number(value) or tostring(value);
	if #text > 65536 then error("diagnostic scalar byte budget"); end

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
		if #keys > MKMP_DEBUG_MAX_RECORD_FIELDS then error("diagnostic field budget"); end
	end

	table.sort(
		keys,
		function(a, b)
			local first, second = tostring(a), tostring(b);
			for i = 1, math.min(#first, #second) do
				local x, y = string.byte(first, i), string.byte(second, i);
				if x ~= y then return x < y; end
			end
			return #first < #second;
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

local function MKMP_Debug_SafeMultiplayer()
	local ok, result = pcall(function() return cm:is_multiplayer(); end);
	if ok and type(result) == "boolean" then return result; end
	return "unknown";
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

	if bytes > MKMP_DEBUG_MAX_BYTES - MKMP_DEBUG.bytes then
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
			assert(file:write(line));
			assert(file:write("\n"));
			assert(file:flush());
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

local function MKMP_Debug_Initialize_Internal()
	if MKMP_DEBUG.initialized then
		return MKMP_DEBUG.enabled;
	end

	MKMP_DEBUG.initialized = true;

	if not io or type(io.open) ~= "function" then
		MKMP_Debug_Disable("io_unavailable");
		return false;
	end

	local size_ok, existing_size = pcall(MKMP_Debug_ReadExistingSize);
	if not size_ok then
		MKMP_Debug_Disable("read_failed");
		return false;
	end
	MKMP_DEBUG.bytes = existing_size;

	if MKMP_DEBUG.bytes >= MKMP_DEBUG_MAX_BYTES then
		MKMP_Debug_Disable("existing_log_at_budget");
		return false;
	end

	MKMP_DEBUG.enabled = true;
	MKMP_DEBUG.reason = "ready";
	-- Process-local identity only. Never a campaign/action identity or RNG seed.
	MKMP_DEBUG.run_id = "append:"..MKMP_Debug_Number(existing_size);

	MKMP_Debug_Log(
		"session_begin",
		{
			schema = MKMP_DEBUG_SCHEMA,
			path = MKMP_DEBUG_LOG_PATH,
			existing_bytes = MKMP_DEBUG.bytes,
			multiplayer = MKMP_Debug_SafeMultiplayer(),
			local_faction = MKMP_Debug_SafeLocalFaction()
		}
	);

	-- Injected from immutable Git inputs by the pack builder. Metadata is
	-- diagnostic-only and never selects a shared-model gameplay branch.
	local identity = type(MKMP_PACK_ID) == "table" and MKMP_PACK_ID or {};
	MKMP_Debug_Log("content_identity", {
		source = identity.source or "unpackaged",
		profile = identity.profile or "unpackaged",
		multiplayer = MKMP_Debug_SafeMultiplayer(),
		save_schema = MK1212_SAVE_SCHEMA_VERSION
	});
	MKMP_Debug_Register_State_Provider("region_ownership", function()
		if type(MKMP_Runtime_Get_Region_Ownership_Snapshot) ~= "function" then
			return nil, "unavailable", "runtime_adapter_missing";
		end
		return MKMP_Runtime_Get_Region_Ownership_Snapshot();
	end);
	if not lifecycle_registered then
		lifecycle_registered = true;
		if cm and type(cm.register_loading_game_callback) == "function" then
			cm:register_loading_game_callback(function()
				MKMP_Debug_Begin_Segment();
			end);
		end
		if cm and type(cm.register_saving_game_callback) == "function" then
			cm:register_saving_game_callback(function()
				MKMP_Debug_Barrier("save_callback_entry", {
					stage = "handler_entry", listener = "MKMP_Debug_Save_Entry"
				});
			end);
		end
	end

	return MKMP_DEBUG.enabled;
end

function MKMP_Debug_Initialize()
	local ok, result = pcall(MKMP_Debug_Initialize_Internal);
	if not ok then MKMP_Debug_Disable("initialize_exception"); return false; end
	return result;
end

local function MKMP_Debug_LogRecord(event_name, payload)
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
		"event="..MKMP_Debug_Escape(event_name or "unknown"),
		"trace_schema="..tostring(MKMP_DEBUG_TRACE_SCHEMA),
		"run_id="..MKMP_Debug_Escape(MKMP_DEBUG.run_id),
		"segment="..tostring(MKMP_DEBUG.segment)
	};
	local domain = (event_name == "session_begin" or event_name == "runtime") and "diagnostic" or "shared_candidate";
	if type(payload) == "table" and domains[payload.domain] then domain = payload.domain; end
	parts[#parts + 1] = "domain="..domain;
	local rejected = 0;

	if type(payload) == "table" then
		local keys = MKMP_Debug_SortedKeys(payload);

		for i = 1, #keys do
			local key = keys[i];
			local value = payload[key];

			if reserved_fields[key] or type(key) ~= "string" or not string.match(key, "^[%a_][%w_]*$") then
				rejected = rejected + 1;
			elseif key ~= "domain" and value ~= nil then
				table.insert(
					parts,
					MKMP_Debug_Escape(key).."="..MKMP_Debug_Escape(value)
				);
			end
		end
	elseif payload ~= nil then
		table.insert(parts, "message="..MKMP_Debug_Escape(payload));
	end
	if rejected > 0 then parts[#parts + 1] = "payload_rejected="..tostring(rejected); end
	if event_name == "rng" then
		MKMP_DEBUG.rng_ordinal = MKMP_DEBUG.rng_ordinal + 1;
		parts[#parts + 1] = "rng_ordinal="..tostring(MKMP_DEBUG.rng_ordinal);
		parts[#parts + 1] = "rng_coverage=wrapped_only";
	end

	local line = table.concat(parts, "|");
	if #line > MKMP_DEBUG_MAX_RECORD_BYTES then
		MKMP_Debug_Disable("record_byte_budget");
		return false;
	end

	if MKMP_Debug_WriteLine(line) then
		MKMP_DEBUG.sequence = next_sequence;
		return true;
	end

	return false;
end

function MKMP_Debug_Log(event_name, payload)
	-- io.open and formatting can throw as well as return nil. Neither may
	-- interrupt the gameplay caller or consume a second campaign RNG draw.
	local ok, result = pcall(MKMP_Debug_LogRecord, event_name, payload);
	if not ok then
		MKMP_Debug_Disable("log_exception");
		return false;
	end
	return result;
end

function MKMP_Debug_Trace(domain, event_name, payload)
	local ok, result = pcall(function()
		local data = {};
		if type(payload) == "table" then
			for key, value in pairs(payload) do data[key] = value; end
		end
		data.domain = domains[domain] and domain or "diagnostic";
		if not domains[domain] then data.trace_error = "invalid_domain"; end
		return MKMP_Debug_Log(event_name, data);
	end);
	return ok and result or false;
end

function MKMP_Debug_Register_State_Provider(name, callback)
	if type(name) ~= "string" or #name > 64 or not string.match(name, "^[a-z][a-z0-9_]*$")
		or type(callback) ~= "function" then return false, "invalid_provider"; end
	if state_providers[name] then
		return state_providers[name] == callback, "provider_already_registered";
	end
	if state_provider_count >= MKMP_DEBUG_MAX_PROVIDERS then return false, "provider_budget"; end
	state_providers[name] = callback;
	state_provider_count = state_provider_count + 1;
	return true;
end

function MKMP_Debug_Begin_Segment()
	local ok, result = pcall(function()
		if not MKMP_DEBUG.enabled then return false; end
		if MKMP_DEBUG.segment >= 65535 then MKMP_Debug_Disable("segment_budget"); return false; end
		MKMP_DEBUG.segment = MKMP_DEBUG.segment + 1;
		MKMP_DEBUG.rng_ordinal, MKMP_DEBUG.checkpoint = 0, 0;
		last_component_payloads = {};
		return MKMP_Debug_Trace("diagnostic", "segment_begin", {
			stage = "handler_entry", listener = "MKMP_Debug_Segment_Entry",
			reason = "load_callback_entry", completion = "not_observed"
		});
	end);
	return ok and result or false;
end

local function MKMP_Debug_Barrier_Internal(name, payload)
	if not MKMP_DEBUG.enabled then return false; end
	local data = {};

	if type(payload) == "table" then
		for key, value in pairs(payload) do
			data[key] = value;
		end
	end

	data.name = name;
	data.domain = "state";
	data.stage = data.stage or "handler_entry";
	data.listener = data.listener or "unspecified_caller";
	data.scope = "registered_components";
	MKMP_DEBUG.checkpoint = MKMP_DEBUG.checkpoint + 1;
	data.checkpoint = tostring(MKMP_DEBUG.checkpoint);
	local names = MKMP_Debug_SortedKeys(state_providers);
	data.component_count = #names;
	data.rng_coverage = nil; -- RNG coverage belongs to the checkpoint contract below.
	data.randomness_coverage = "wrapped_only";
	if not MKMP_Debug_Log("barrier", data) then return false; end
	local complete = #names > 0;
	local total_bytes = 0;
	for i = 1, #names do
		local component = names[i];
		local ok, snapshot, status, reason = pcall(state_providers[component]);
		local captured;
		if not ok then
			status, reason = "unavailable", "provider_exception";
		elseif snapshot == nil then
			status, reason = status or "unavailable", reason or "provider_returned_nil";
		elseif type(MKMP_Fingerprint_Capture) ~= "function" then
			status, reason = "unavailable", "fingerprint_module_missing";
		else
			captured = MKMP_Fingerprint_Capture(snapshot);
			if not captured.complete then status, reason = captured.status, captured.reason; end
			if type(snapshot) == "table" and snapshot.complete == false and status == nil then
				status, reason = "incomplete", "provider_state_incomplete";
			end
		end
		status = status or "complete";
		if status ~= "complete" and status ~= "incomplete" and status ~= "unavailable" then
			status, reason = "incomplete", "invalid_provider_status";
		end
		if status == "complete" and (not captured or not captured.complete) then
			status, reason = "incomplete", "missing_capture";
		end
		local fields = {
			domain = "state", checkpoint = data.checkpoint, component = component,
			schema = "mkfp-table-v1", status = status, complete = status == "complete",
			entries = captured and captured.entries or 0, bytes = captured and captured.bytes or 0,
			reason = reason, payload_mode = "unavailable"
		};
		if status == "complete" then
			if total_bytes + captured.bytes > MKMP_DEBUG_MAX_CHECKPOINT_BYTES then
				fields.status, fields.complete, fields.reason = "incomplete", false, "checkpoint_byte_budget";
				fields.entries, fields.bytes = 0, 0;
			else
				total_bytes = total_bytes + captured.bytes;
				fields.checksum = captured.checksum;
				local previous = last_component_payloads[component];
				if previous and previous.payload == captured.payload then
					fields.payload_mode, fields.payload_ref = "unchanged", previous.checkpoint;
				else
					fields.payload_mode, fields.payload = "inline", captured.payload;
				end
			end
		end
		if fields.complete ~= true then complete = false; end
		if not MKMP_Debug_Log("state_component", fields) then return false; end
		if fields.complete then
			last_component_payloads[component] = {payload = captured.payload, checkpoint = data.checkpoint};
		else
			last_component_payloads[component] = nil;
		end
	end
	return MKMP_Debug_Trace("state", "checkpoint_end", {
		checkpoint = data.checkpoint, component_count = #names,
		complete = complete, status = complete and "complete" or "incomplete",
		bytes = total_bytes, scope = "registered_components"
	});
end

function MKMP_Debug_Barrier(name, payload)
	local ok, result = pcall(MKMP_Debug_Barrier_Internal, name, payload);
	-- A failed snapshot is not an instruction to retry the gameplay operation.
	if not ok then
		MKMP_Debug_Trace("diagnostic", "checkpoint_error", {reason = "barrier_exception"});
		return false;
	end
	return result;
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
		segment = MKMP_DEBUG.segment,
		trace_schema = MKMP_DEBUG_TRACE_SCHEMA,
		provider_count = state_provider_count,
		rng_coverage = "wrapped_only",
		max_entries = MKMP_DEBUG_MAX_ENTRIES,
		max_bytes = MKMP_DEBUG_MAX_BYTES
	};
end
