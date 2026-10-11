-- Captured gameplay actions. Transport receipt and local UI observation are not
-- authority to mutate an MP campaign. No packet, log or local option can open
-- this boundary; each future native adapter needs exact-build phase/command proof.

local ACTION_KEY = "MKMP_ACTIONS";
local MAX_ACTIONS = 128;
local MAX_SEQUENCE = 1000000; -- Exactly representable by Attila's float Lua.
local MAX_PAYLOAD_BYTES = 16384;
local registry = {};
local registry_count = 0;
local records = {};
local sequence = 0;
local local_sequence = 0; -- Diagnostic only; never persisted or shared authority.
local initialized = false;
local blocked = false;
local preserve_raw = false;
local raw_payload, raw_schema = "", 0;

local function Action_Trace(domain, stage, values)
	if MKMP_Debug_Trace then
		values.stage = stage;
		pcall(MKMP_Debug_Trace, domain, "action", values);
	end
end

local function Action_Key(value)
	return type(value) == "string" and #value > 0 and #value <= 256
		and string.match(value, "^[A-Za-z0-9_.:%-]+$") ~= nil;
end

local function Action_Integer(value, minimum, maximum)
	return MK1212_IsFiniteNumber(value) and value == math.floor(value)
		and value >= minimum and value <= maximum;
end

-- This codec captures a bounded immutable value, not a Lua object reference.
-- Keys are sorted bytewise; numeric keys preserve array order. The full value
-- (not its diagnostic checksum) is used to compare an operation's arguments.
function MKMP_Actions_Copy(value)
	local entries, bytes, seen = 0, 0, {};
	local function visit(item, depth)
		entries = entries + 1;
		if entries > 1024 or depth > 6 then error("action payload budget"); end
		local kind = type(item);
		if kind ~= "table" then
			if kind ~= "string" and kind ~= "boolean" and kind ~= "number" then
				error("unsupported action value");
			end
			if kind == "number" and not MK1212_IsFiniteNumber(item) then error("invalid action number"); end
			local text = MK1212_SaveScalar(item);
			bytes = bytes + #text + 16;
			if bytes > MAX_PAYLOAD_BYTES then error("action byte budget"); end
			return item, string.sub(kind, 1, 1)..#text..":"..text;
		end
		if getmetatable(item) ~= nil then error("action payload must be a plain table"); end
		if seen[item] then error("cyclic action payload"); end
		seen[item] = true;
		local keys = {};
		for key, _ in pairs(item) do
			if type(key) ~= "string" and not Action_Integer(key, 1, 1024) then error("invalid action key"); end
			keys[#keys + 1] = key;
			if #keys > 1024 then error("action key budget"); end
		end
		table.sort(keys, function(a, b)
			if type(a) ~= type(b) then return type(a) == "number"; end
			if type(a) == "number" then return a < b; end
			return MK1212_SaveByteLess(a, b);
		end);
		local output, parts = {}, {"t", tostring(#keys), ":"};
		for i = 1, #keys do
			local key = keys[i];
			local _, encoded_key = visit(key, depth + 1);
			local copied, encoded = visit(item[key], depth + 1);
			output[key] = copied;
			parts[#parts + 1] = encoded_key..encoded;
		end
		seen[item] = nil;
		local result = table.concat(parts);
		if #result > MAX_PAYLOAD_BYTES then error("action byte budget"); end
		return output, result;
	end
	return visit(value, 0);
end

function MKMP_Actions_Register(kind, specification)
	if not Action_Key(kind) or type(specification) ~= "table"
		or type(specification.validate) ~= "function" or type(specification.execute) ~= "function" then
		return false;
	end
	if registry[kind] then return registry[kind] == specification; end
	if registry_count >= 32 then return false; end
	registry[kind] = specification;
	registry_count = registry_count + 1;
	return true;
end

function MKMP_Actions_Get_State()
	local snapshot = MKMP_Diagnostic_Copy({schema = 1, mp_authority = "unproven", blocked = blocked,
		script_completion = "local_bookkeeping_only_native_effect_unproven",
		sequence = sequence, records = records});
	return snapshot, blocked and "incomplete" or "complete", blocked and "invalid_saved_state" or nil;
end

function MKMP_Actions_Matches(action_id, kind, actor, payload)
	if blocked or not Action_Key(kind) or not Action_Key(actor) then return false; end
	local ok, captured, canonical = pcall(MKMP_Actions_Copy, payload);
	if not ok or type(captured) ~= "table" then return false; end
	for i = 1, #records do
		local row = records[i];
		if row.id == action_id then
			local token = tostring(row.turn)..":"..kind..":"..actor..":"..canonical;
			return row.kind == kind and row.actor == actor and row.token == token, row.status;
		end
	end
	return false;
end

function MKMP_Actions_UI_Feedback(component, reason)
	if not component or not UIComponent then return; end
	pcall(function()
		local message = "Action could not be completed. Check the campaign action report.";
		if reason == "native_delivery_and_command_semantics_unproven" then
			message = "This multiplayer script action is awaiting synchronization validation. Its scripted effect was not applied.";
		elseif reason == "duplicate" then
			message = "This action has already been submitted.";
		elseif reason == "previous_effect_uncertain" or reason == "effect_uncertain" then
			message = "The previous action has an unconfirmed result. It will not be repeated automatically.";
		end
		UIComponent(component):SetTooltipText(message);
	end);
end

function MKMP_Actions_Confirm(action_id, outcome)
	-- Called only by the owning game callback after it has checked its captured
	-- record and actual result. An external ACK must never call this function.
	if outcome ~= "confirmed" and outcome ~= "uncertain" then return false; end
	for i = 1, #records do
		local record = records[i];
		if record.id == action_id then
			if record.status == "confirmed" then return outcome == "confirmed"; end
			if record.status ~= "requested" and record.status ~= "executing" and record.status ~= "uncertain" then return false; end
			record.status = outcome;
			Action_Trace("shared_candidate", outcome, {action_id = action_id, actor = record.actor, mechanic = record.kind});
			return true;
		end
	end
	return false;
end

local function Action_Prune(turn)
	for i = #records, 1, -1 do
		local record = records[i];
		if (record.status == "confirmed" or record.status == "script_complete") and record.turn < turn - 1 then
			table.remove(records, i);
		end
	end
end

function MKMP_Actions_Submit_Local(kind, actor, payload)
	local specification = registry[kind];
	if not specification or not Action_Key(actor) then return false, "unknown_action_or_actor"; end
	local ok, captured, canonical = pcall(MKMP_Actions_Copy, payload);
	if not ok or type(captured) ~= "table" then return false, "invalid_payload"; end
	if local_sequence >= MAX_SEQUENCE then return false, "local_intent_budget"; end
	local_sequence = local_sequence + 1;
	local intent_id = "local:"..actor..":"..tostring(local_sequence);
	local values = {intent_id = intent_id, mechanic = kind, actor = actor,
		payload_digest = MK1212_SaveChecksum(canonical), phase = "local_ui"};
	Action_Trace("local", "observed", values);
	if cm:is_multiplayer() then
		-- A local event cannot write even a shared Lua 'pending' flag. The passive
		-- N4 coordinator can inspect a separate candidate but cannot enable this.
		values.reason = "native_delivery_and_command_semantics_unproven";
		Action_Trace("local", "blocked", values);
		return false, values.reason, intent_id;
	end
	if blocked then return false, "action_state_blocked", intent_id; end
	local turn = cm:model():turn_number();
	if not Action_Integer(turn, 0, MAX_SEQUENCE) then return false, "invalid_turn", intent_id; end
	if FACTION_TURN and FACTION_TURN ~= "nil" and FACTION_TURN ~= actor then
		return false, "wrong_actor_turn", intent_id;
	end
	Action_Prune(turn);
	-- Once keys include the full captured payload; checksums never choose model
	-- behavior. Callers capture queue/ownership preconditions for repeatable work.
	local token = tostring(turn)..":"..kind..":"..actor..":"..canonical;
	for i = 1, #records do
		local record = records[i];
		if record.actor == actor and record.kind == kind and record.status == "uncertain" then
			return false, "previous_effect_uncertain", record.id;
		end
		if record.kind == kind and record.actor == actor and record.token == token then
			values.action_id = record.id;
			Action_Trace("local", "duplicate", values);
			return false, "duplicate", record.id;
		end
	end
	if #records >= MAX_ACTIONS or sequence >= MAX_SEQUENCE then return false, "action_budget", intent_id; end
	local ledger_bytes = #token + 512;
	for i = 1, #records do ledger_bytes = ledger_bytes + #records[i].token + 512; end
	-- Escaping can triple bytes. Reserve the complete save budget before a call.
	if ledger_bytes > 262144 then return false, "action_save_budget", intent_id; end
	local valid, accepted, reason = pcall(specification.validate, actor, captured);
	if not valid or accepted ~= true then
		values.reason = valid and (reason or "invalid_precondition") or "validation_failed";
		Action_Trace("local", "blocked", values);
		return false, values.reason, intent_id;
	end
	sequence = sequence + 1;
	local action_id = "sp:"..actor..":"..tostring(sequence);
	local record = {id = action_id, kind = kind, actor = actor, turn = turn,
		status = "executing", token = token};
	records[#records + 1] = record; -- Claim before any possibly partial call.
	values.action_id, values.parent_id, values.phase = action_id, intent_id, "sp_local_action";
	Action_Trace("shared_candidate", "validated", values);
	if MKMP_Debug_Barrier then pcall(MKMP_Debug_Barrier, "action_before", values); end
	if MKMP_Delivery_Probe_Observe_Command then
		pcall(MKMP_Delivery_Probe_Observe_Command, kind, "sp_local_action", action_id, "requested", values);
	end
	local executed, result, status = pcall(specification.execute, actor, captured, action_id);
	if not executed or result ~= true then
		record.status = "uncertain";
		values.reason = executed and (status or "effect_not_confirmed") or "engine_or_callback_error";
		Action_Trace("shared_candidate", "uncertain", values);
		if MKMP_Debug_Barrier then pcall(MKMP_Debug_Barrier, "action_after", values); end
		return false, "effect_uncertain", action_id;
	end
	if record.status == "executing" then
		if status == "confirmed" or status == "script_complete" then record.status = status;
		else record.status = "requested"; end
	end
	Action_Trace("shared_candidate", record.status, values);
	if MKMP_Debug_Barrier then pcall(MKMP_Debug_Barrier, "action_after", values); end
	if record.status == "uncertain" then return false, "effect_uncertain", action_id; end
	return true, record.status, action_id;
end

function MKMP_Actions_Observe_Native(kind, record, context)
	-- Explicit extension boundary for an operation-specific native adapter.
	-- There is intentionally no public 'enable networking' or evidence-file flag.
	local ok, captured = pcall(MKMP_Actions_Copy, record);
	if not ok or type(captured) ~= "table" then return false, "invalid_native_observation"; end
	Action_Trace("shared_candidate", "observed", {mechanic = kind, action_id = captured.action_id,
		actor = captured.actor, phase = captured.phase, reason = "native_observation_only"});
	return false, "operation_phase_proof_required";
end

function MKMP_Actions_Initialize()
	if initialized then return; end
	initialized = true;
	if MKMP_Debug_Register_State_Provider then
		MKMP_Debug_Register_State_Provider("actions", MKMP_Actions_Get_State);
	end
end

cm:register_saving_game_callback(function(context)
	if preserve_raw then
		cm:save_value(ACTION_KEY, raw_payload, context);
		cm:save_value(ACTION_KEY.."__schema", raw_schema, context);
		return;
	end
	local parts = {};
	MK1212_SaveAppend(parts, "meta", ",");
	MK1212_SaveAppend(parts, "1", ",");
	MK1212_SaveAppend(parts, sequence, ",;");
	for i = 1, #records do
		local row = records[i];
		MK1212_SaveAppend(parts, row.id, ",");
		MK1212_SaveAppend(parts, row.kind, ",");
		MK1212_SaveAppend(parts, row.actor, ",");
		MK1212_SaveAppend(parts, row.turn, ",");
		MK1212_SaveAppend(parts, row.status, ",");
		MK1212_SaveAppend(parts, row.token, ",;");
	end
	MK1212_SaveCommitString(context, ACTION_KEY, table.concat(parts), #records + 1);
end);

cm:register_loading_game_callback(function(context)
	-- Existing schema-3 saves have no action ledger: start with no pending work.
	-- A new ledger is never replayed. Interrupted calls remain uncertain on load.
	local saved = cm:load_value(ACTION_KEY, "", context);
	local schema = cm:load_value(ACTION_KEY.."__schema", 0, context);
	local ok, next_records, next_sequence = pcall(function()
		if saved == "" and schema == 0 then return {}, 0; end
		local rows = MK1212_LoadSaveRows(context, ACTION_KEY);
		if #rows < 1 or #rows > MAX_ACTIONS + 1 or #rows[1] ~= 3
			or rows[1][1] ~= "meta" or rows[1][2] ~= "1" then error("unknown action schema"); end
		local count = MK1212_SaveNumber(rows[1][3], ACTION_KEY);
		if not Action_Integer(count, 0, MAX_SEQUENCE) then error("invalid action sequence"); end
		local current_turn = cm:model():turn_number();
		if not Action_Integer(current_turn, 0, MAX_SEQUENCE) then error("invalid current action turn"); end
		local output, ids, tokens, serials, ledger_bytes = {}, {}, {}, {}, 0;
		for i = 2, #rows do
			local row = rows[i];
			if #row ~= 6 or type(row[1]) ~= "string" or #row[1] > 512 or not Action_Key(row[2]) or not Action_Key(row[3])
				or ids[row[1]] or #row[6] > MAX_PAYLOAD_BYTES + 600 then error("invalid action row"); end
			local owned_token = #row[2]..":"..row[2]..#row[3]..":"..row[3]..row[6];
			if tokens[owned_token] then error("duplicate owned action token"); end
			local turn = MK1212_SaveNumber(row[4], ACTION_KEY);
			if not Action_Integer(turn, 0, current_turn) then error("invalid action turn"); end
			local prefix = "sp:"..row[3]..":";
			local serial_text = string.sub(row[1], #prefix + 1);
			local serial = tonumber(serial_text);
			if string.sub(row[1], 1, #prefix) ~= prefix or not Action_Integer(serial, 1, count)
				or tostring(serial) ~= serial_text or serials[serial] then error("invalid action identity"); end
			serials[serial] = true;
			local token_prefix = tostring(turn)..":"..row[2]..":"..row[3]..":t";
			if string.sub(row[6], 1, #token_prefix) ~= token_prefix then error("invalid action token"); end
			ledger_bytes = ledger_bytes + #row[6] + 512;
			if ledger_bytes > 262144 then error("action ledger byte budget"); end
			local status = row[5];
			if status ~= "confirmed" and status ~= "script_complete" and status ~= "requested"
				and status ~= "executing" and status ~= "uncertain" then
				error("invalid action status");
			end
			if status == "requested" or status == "executing" then status = "uncertain"; end
			output[#output + 1] = {id = row[1], kind = row[2], actor = row[3], turn = turn, status = status, token = row[6]};
			ids[row[1]], tokens[owned_token] = true, true;
		end
		return output, count;
	end);
	local_sequence = 0;
	if ok then
		records, sequence, blocked, preserve_raw = next_records, next_sequence, false, false;
	else
		blocked, preserve_raw = true, true;
		raw_payload, raw_schema = saved, schema;
		Action_Trace("diagnostic", "blocked", {mechanic = "actions", reason = "invalid_saved_action_state"});
	end
end);
