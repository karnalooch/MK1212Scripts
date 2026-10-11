-- Population accounting uses captured commander/force/region and reservation
-- identity. Local UI callbacks are not shared MP events; the common action gate
-- records them without changing the MP model until delivery semantics are proven.
local initialized = false;
local reservations = {};
local revisions = {};
local revision_turns = {};
local phase_ledger = {};
local uncertain_queues = {};
local pending_force = nil;
local blocked = false;
local MAX_QUEUE = 64;
local MAX_COMMANDERS = 512;
local MAX_RESERVATIONS = 8192;
local SAVE_KEY = "MKMP_POPULATION_RESERVATIONS";

local function Log(stage, values)
	if MKMP_Debug_Trace then
		values.stage, values.mechanic = stage, "population";
		pcall(MKMP_Debug_Trace, "shared_candidate", "population_action", values);
	end
end

local function Integer(value, minimum, maximum)
	return MK1212_IsFiniteNumber(value) and value == math.floor(value) and value >= minimum and value <= maximum;
end

local function Commander_Key(cqi)
	return type(cqi) == "string" and Integer(tonumber(cqi), 1, 16777215)
		and tostring(tonumber(cqi)) == cqi;
end

local function Mark_Queue_Uncertain(cqi, reason)
	if not Commander_Key(cqi) then return false; end
	if #(POPULATION_UNITS_IN_RECRUITMENT[cqi] or {}) == 0 and #(reservations[cqi] or {}) == 0 then return false; end
	if uncertain_queues[cqi] then return false; end
	local turn = cm:model():turn_number();
	if not Integer(turn, 0, 1000000) or #MK1212_SaveSortedKeys(uncertain_queues) >= MAX_COMMANDERS then
		blocked = true;
		return false;
	end
	uncertain_queues[cqi] = {reason = reason, turn = turn};
	Log("uncertain", {commander = cqi, reason = reason, identity_status = "native_reservation_identity_unproven"});
	return false;
end

local function Queue_Revision(cqi)
	return revisions[cqi] or 0;
end

local function Queue_Advance(cqi)
	local current = Queue_Revision(cqi);
	local turn = cm:model():turn_number();
	if not Commander_Key(cqi) or current >= 1000000 or not Integer(turn, 0, 1000000) then
		error("population queue revision exhausted or invalid");
	end
	revisions[cqi] = current + 1;
	revision_turns[cqi] = turn;
end

local function Prune_Ledgers(turn)
	local keys = MK1212_SaveSortedKeys(phase_ledger);
	for i = 1, #keys do
		if phase_ledger[keys[i]] < turn - 1 then phase_ledger[keys[i]] = nil; end
	end
	keys = MK1212_SaveSortedKeys(revisions);
	for i = 1, #keys do
		local cqi = keys[i];
		if (revision_turns[cqi] or 0) < turn and #(reservations[cqi] or {}) == 0
			and #(POPULATION_UNITS_IN_RECRUITMENT[cqi] or {}) == 0 and not uncertain_queues[cqi] then
			revisions[cqi], revision_turns[cqi], reservations[cqi] = nil, nil, nil;
		end
	end
end

function MKMP_Population_Guard_Phase(phase, actor)
	local turn = cm:model():turn_number();
	if blocked or not Integer(turn, 0, 1000000) or type(phase) ~= "string" or type(actor) ~= "string"
		or #phase == 0 or #actor == 0 or #phase + #actor > 255 then return false; end
	Prune_Ledgers(turn);
	local key = phase..":"..actor;
	if phase_ledger[key] == turn then return false; end
	if #MK1212_SaveSortedKeys(phase_ledger) >= 4096 and phase_ledger[key] == nil then return false; end
	phase_ledger[key] = turn;
	return true;
end

function MKMP_Population_Queue_Cleared(cqi)
	if blocked or not Commander_Key(cqi) or uncertain_queues[cqi] then return false; end
	local queue, items = POPULATION_UNITS_IN_RECRUITMENT[cqi] or {}, reservations[cqi] or {};
	if #queue == 0 and #items == 0 then return true; end
	if #queue ~= #items then return Mark_Queue_Uncertain(cqi, "queue_state_mismatch"); end
	if Queue_Revision(cqi) >= 1000000 then return Mark_Queue_Uncertain(cqi, "queue_revision_exhausted"); end
	if not Integer(cm:model():turn_number(), 0, 1000000) then return false; end
	if revisions[cqi] == nil and #MK1212_SaveSortedKeys(revisions) >= MAX_COMMANDERS then return false; end
	-- This owner updates both sides only after every refusal condition. Native
	-- callers must not erase the public queue before invoking this function.
	Queue_Advance(cqi);
	POPULATION_UNITS_IN_RECRUITMENT[cqi], reservations[cqi] = nil, nil;
	return true;
end

function MKMP_Population_Queue_Trained(cqi, index)
	-- A queue slot supplied by a same-type search is not native unit identity.
	return Mark_Queue_Uncertain(cqi, "unverified_training_slot");
end

function MKMP_Population_Observe_Trained(context)
	local ok, cqi, actor, unit_key = pcall(function()
		local unit = context:unit();
		if not unit or unit:is_null_interface() or not unit:has_force_commander() then return nil; end
		local faction, commander = unit:faction(), unit:force_commander();
		if not faction or faction:is_null_interface() or not faction:is_human()
			or not commander or commander:is_null_interface() then return nil; end
		local key = tostring(commander:cqi());
		if not Commander_Key(key) then return nil; end
		return key, faction:name(), unit:unit_key();
	end);
	if not ok or not cqi then return false; end
	Log("observed", {actor = actor, commander = cqi, unit = unit_key,
		identity_status = "native_reservation_identity_unproven"});
	-- Applies in SP and MP. No published Attila campaign API supplies the unique
	-- trained unit/queue transaction ID needed to consume a paid reservation.
	-- Preserve its original debit and block later refunds, including after load.
	return Mark_Queue_Uncertain(cqi, "native_training_identity_unproven");
end

local function Capture_Character(character)
	if not character or character:is_null_interface() or not character:has_military_force() then return nil; end
	local faction = character:faction();
	if not faction or faction:is_null_interface() then return nil; end
	local cqi = character:cqi();
	if not Integer(cqi, 1, 16777215) then return nil; end
	local horde = faction:is_horde();
	local region = "";
	if not horde then
		if not character:has_region() then return nil; end
		local current = character:region();
		if not current or current:is_null_interface() then return nil; end
		region = current:name();
	end
	local force = character:military_force():command_queue_index();
	local actor = faction:name();
	if type(actor) ~= "string" or #actor == 0 or #actor > 128
		or type(horde) ~= "boolean" or type(region) ~= "string" or #region > 256
		or not Integer(force, 1, 16777215) then return nil; end
	return {actor = actor, commander = tostring(cqi), region = region, horde = horde,
		force = force, turn = cm:model():turn_number()};
end

function MKMP_Population_Capture_Recruit(character, unit_name)
	local ok, payload = pcall(Capture_Character, character);
	if not ok or not payload then return nil; end
	local queue = POPULATION_UNITS_IN_RECRUITMENT[payload.commander] or {};
	payload.unit, payload.slot, payload.revision = unit_name, #queue + 1, Queue_Revision(payload.commander);
	return payload;
end

function MKMP_Population_Capture_Cancel(character, slot)
	local ok, payload = pcall(Capture_Character, character);
	if not ok or not payload or not Integer(slot, 1, MAX_QUEUE) then return nil; end
	local queue = POPULATION_UNITS_IN_RECRUITMENT[payload.commander] or {};
	local item = reservations[payload.commander] and reservations[payload.commander][slot];
	if not queue[slot] or not item then return nil; end
	payload.unit, payload.slot, payload.reservation = queue[slot], slot, item.id;
	payload.revision = Queue_Revision(payload.commander);
	return payload;
end

local function Validate_Queue(actor, payload)
	if blocked or actor ~= payload.actor or payload.turn ~= cm:model():turn_number()
		or not Commander_Key(payload.commander) then return false, "population_actor"; end
	if uncertain_queues[payload.commander] then return false, "population_queue_uncertain"; end
	local character = cm:model():character_for_command_queue_index(tonumber(payload.commander));
	local current = Capture_Character(character);
	if not current or current.actor ~= actor or current.region ~= payload.region or current.force ~= payload.force
		or current.horde ~= payload.horde then
		return false, "population_commander_changed";
	end
	if payload.revision ~= Queue_Revision(payload.commander) then return false, "population_queue_changed"; end
	if Queue_Revision(payload.commander) >= 1000000 then return false, "population_revision_exhausted"; end
	if not Integer(payload.slot, 1, MAX_QUEUE) then return false, "population_queue_slot"; end
	return true;
end

local function Validate_Recruit(actor, payload)
	local valid, reason = Validate_Queue(actor, payload);
	if not valid then return false, reason; end
	local unit = POPULATION_UNITS_TO_POPULATION[payload.unit];
	local queue = POPULATION_UNITS_IN_RECRUITMENT[payload.commander] or {};
	if #queue >= MAX_QUEUE or payload.slot ~= #queue + 1 or not unit
		or not Integer(unit[2], 1, 5) or not Integer(unit[1], 1, 100000) then return false, "population_unit_or_slot"; end
	if not reservations[payload.commander] and #MK1212_SaveSortedKeys(reservations) >= MAX_COMMANDERS then
		return false, "population_commander_budget";
	end
	local reservation_keys, reservation_count = MK1212_SaveSortedKeys(reservations), 0;
	for i = 1, #reservation_keys do reservation_count = reservation_count + #reservations[reservation_keys[i]]; end
	if reservation_count >= MAX_RESERVATIONS then return false, "population_reservation_budget"; end
	if not revisions[payload.commander] and #MK1212_SaveSortedKeys(revisions) >= MAX_COMMANDERS then
		return false, "population_revision_budget";
	end
	if #queue ~= #(reservations[payload.commander] or {}) then return false, "population_reservation_mismatch"; end
	if not payload.horde then
		local population, manpower = POPULATION_REGIONS_POPULATIONS[payload.region], POPULATION_REGIONS_MANPOWER[payload.region];
		if not population or not manpower or not MK1212_IsFiniteNumber(population[unit[2]])
			or not MK1212_IsFiniteNumber(manpower[unit[2]]) or population[unit[2]] < unit[1] or manpower[unit[2]] < unit[1] then
			return false, "population_insufficient_manpower";
		end
	end
	return true;
end

local function Execute_Recruit(actor, payload, action_id)
	local unit = POPULATION_UNITS_TO_POPULATION[payload.unit];
	local queue = POPULATION_UNITS_IN_RECRUITMENT[payload.commander] or {};
	local items = reservations[payload.commander] or {};
	local record = {id = action_id, unit = payload.unit, region = payload.region,
		class = unit[2], amount = unit[1], horde = payload.horde, known = true};
	-- All Lua accounting operands were validated before the first assignment.
	if not payload.horde then Change_Manpower_Region(payload.region, unit[2], -unit[1]); end
	queue[#queue + 1], items[#items + 1] = payload.unit, record;
	POPULATION_UNITS_IN_RECRUITMENT[payload.commander], reservations[payload.commander] = queue, items;
	Queue_Advance(payload.commander);
	Log("confirmed", {action_id = action_id, actor = actor, target = payload.region, kind = "reservation"});
	return true, "confirmed"; -- Confirms Lua accounting, not the engine recruiting command.
end

local function Validate_Cancel(actor, payload)
	local valid, reason = Validate_Queue(actor, payload);
	if not valid then return false, reason; end
	local queue = POPULATION_UNITS_IN_RECRUITMENT[payload.commander] or {};
	local item = reservations[payload.commander] and reservations[payload.commander][payload.slot];
	if not item or item.id ~= payload.reservation or item.unit ~= payload.unit or queue[payload.slot] ~= payload.unit then
		return false, "population_reservation_changed";
	end
	if not item.known then return false, "legacy_reservation_origin_unknown"; end
	if not item.horde then
		local population, manpower = POPULATION_REGIONS_POPULATIONS[item.region], POPULATION_REGIONS_MANPOWER[item.region];
		if not population or not manpower or not MK1212_IsFiniteNumber(population[item.class])
			or not MK1212_IsFiniteNumber(manpower[item.class]) then return false, "population_refund_region_unavailable"; end
	end
	return true;
end

local function Execute_Cancel(actor, payload, action_id)
	local items = reservations[payload.commander];
	local item = items[payload.slot];
	if not item.horde then Change_Manpower_Region(item.region, item.class, item.amount); end
	table.remove(POPULATION_UNITS_IN_RECRUITMENT[payload.commander], payload.slot);
	table.remove(items, payload.slot);
	Queue_Advance(payload.commander);
	Log("confirmed", {action_id = action_id, parent_id = item.id, actor = actor, target = item.region, kind = "refund"});
	return true, "confirmed";
end

function MKMP_Population_Capture_Force(character, mode)
	local ok, payload = pcall(function()
		local result = Capture_Character(character);
		if not result or result.horde then return nil; end
		local units = character:military_force():unit_list();
		if units:num_items() > 64 then return nil; end
		result.units, result.mode = {}, mode;
		for i = 0, units:num_items() - 1 do
			local unit = units:item_at(i);
			if not unit:has_unit_commander() then
				result.units[#result.units + 1] = {unit = unit:unit_key(), strength = unit:percentage_proportion_of_full_strength()};
			end
		end
		return result;
	end);
	if ok then return payload; end
end

local function Find_Captured_Force(actor, force_cqi)
	local faction = cm:model():world():faction_by_key(actor);
	if not faction or faction:is_null_interface() then return nil; end
	local forces = faction:military_force_list();
	if forces:num_items() > 512 then return nil; end
	for i = 0, forces:num_items() - 1 do
		local force = forces:item_at(i);
		if force:command_queue_index() == force_cqi then return force; end
	end
end

local function Validate_Force(actor, payload)
	if blocked or pending_force or payload.actor ~= actor or payload.turn ~= cm:model():turn_number()
		or not Commander_Key(payload.commander) or payload.horde ~= false
		or type(payload.region) ~= "string" or #payload.region == 0 or #payload.region > 256
		or type(payload.units) ~= "table"
		or (payload.mode ~= "disband" and payload.mode ~= "merge" and payload.mode ~= "commander") then
		return false, "population_force_precondition";
	end
	local count = MK1212_SaveDenseLength(payload.units, 64);
	for i = 1, count do
		local row = payload.units[i];
		if type(row) ~= "table" or type(row.unit) ~= "string" or #row.unit == 0 or #row.unit > 256
			or not MK1212_IsFiniteNumber(row.strength) or row.strength < 0 or row.strength > 100 then
			return false, "population_force_snapshot";
		end
	end
	if not Integer(payload.force, 1, 16777215) or not Find_Captured_Force(actor, payload.force) then
		return false, "population_force_unavailable";
	end
	return true;
end

local function Execute_Force(actor, payload, action_id)
	pending_force = {actor = actor, payload = payload, id = action_id, timer = "MKMP_Population_"..action_id};
	-- SP-only executor. Its one owned timer is an observation, never MP delivery.
	cm:add_time_trigger(pending_force.timer, 0.1);
	return true, "requested";
end

local function Unit_Totals(units)
	local totals = {};
	for i = 1, #units do
		local row = units[i];
		local unit = POPULATION_UNITS_TO_POPULATION[row.unit];
		if unit and not string.find(row.unit, "mk_merc", 1, true) then
			if not MK1212_IsFiniteNumber(row.strength) or row.strength < 0 or row.strength > 100 then
				error("invalid captured unit strength");
			end
			totals[row.unit] = (totals[row.unit] or 0) + math.floor(unit[1] * row.strength / 100 + 0.5);
		end
	end
	return totals;
end

function MKMP_Population_Observe_Timer(context)
	local pending = pending_force;
	if not pending or context.string ~= pending.timer then return false; end
	pending_force = nil; -- Consume before any observation/refund; duplicates cannot repeat.
	local ok, confirmed = pcall(function()
		local payload = pending.payload;
		if cm:is_multiplayer() or cm:model():turn_number() ~= payload.turn or FACTION_TURN ~= pending.actor then return false; end
		local force = Find_Captured_Force(pending.actor, payload.force);
		if not force or not force:has_general() then return false; end
		local general = force:general_character();
		if payload.mode == "commander" then
			if not general or general:is_null_interface() then return false; end
			local next_cqi = tostring(general:cqi());
			if not Commander_Key(next_cqi) or not Commander_Key(payload.commander)
				or next_cqi == payload.commander or #(POPULATION_UNITS_IN_RECRUITMENT[next_cqi] or {}) > 0
				or #(reservations[next_cqi] or {}) > 0 or uncertain_queues[next_cqi] then return false; end
			local next_owner = general:faction();
			if not next_owner or next_owner:is_null_interface() or next_owner:name() ~= pending.actor then return false; end
			local queue, items = POPULATION_UNITS_IN_RECRUITMENT[payload.commander] or {}, reservations[payload.commander] or {};
			if #queue ~= #items then return Mark_Queue_Uncertain(payload.commander, "queue_state_mismatch"); end
			if #queue == 0 and not uncertain_queues[payload.commander] then return true; end
			if Queue_Revision(next_cqi) >= 1000000 or Queue_Revision(payload.commander) >= 1000000 then return false; end
			local added_revisions = (revisions[next_cqi] == nil and 1 or 0) + (revisions[payload.commander] == nil and 1 or 0);
			if #MK1212_SaveSortedKeys(revisions) + added_revisions > MAX_COMMANDERS then return false; end
			Queue_Advance(next_cqi); Queue_Advance(payload.commander);
			POPULATION_UNITS_IN_RECRUITMENT[next_cqi] = POPULATION_UNITS_IN_RECRUITMENT[payload.commander];
			reservations[next_cqi] = reservations[payload.commander];
			POPULATION_UNITS_IN_RECRUITMENT[payload.commander], reservations[payload.commander] = nil, nil;
			uncertain_queues[next_cqi], uncertain_queues[payload.commander] = uncertain_queues[payload.commander], nil;
			return true;
		end
		local current = MKMP_Population_Capture_Force(general, payload.mode);
		if not current or current.commander ~= payload.commander or current.region ~= payload.region then return false; end
		local before, after = Unit_Totals(payload.units), Unit_Totals(current.units);
		if payload.mode == "merge" then
			-- Merging identical types does not create a manpower refund. Preserve
			-- the aggregate before/after evidence instead of treating a vanished
			-- card as a disbanded full-strength unit.
			Log("observed", {action_id = pending.id, actor = pending.actor, kind = "merge_no_refund"});
			return true;
		end
		-- Every surviving card must match a captured type and rounded strength.
		-- A same-type strength loss or an incoming unit is ambiguous, not proof
		-- that a specific paid unit was disbanded.
		local unmatched = MKMP_Actions_Copy(payload.units);
		for i = 1, #current.units do
			local row, found = current.units[i], false;
			local definition = POPULATION_UNITS_TO_POPULATION[row.unit];
			local size = definition and definition[1] or 10000;
			for j = 1, #unmatched do
				if unmatched[j].unit == row.unit and math.floor(unmatched[j].strength * size / 100 + 0.5)
					== math.floor(row.strength * size / 100 + 0.5) then
					table.remove(unmatched, j); found = true; break;
				end
			end
			if not found then return false; end
		end
		if #unmatched == 0 then return false; end -- No observed disband yet.
		local refunds = {0, 0, 0, 0, 0};
		local keys = MK1212_SaveSortedKeys(before);
		for i = 1, #keys do
			local key = keys[i];
			local difference = before[key] - (after[key] or 0);
			if difference < 0 then return false; end
			local class = POPULATION_UNITS_TO_POPULATION[key][2];
			refunds[class] = refunds[class] + difference;
		end
		local pop, manpower = POPULATION_REGIONS_POPULATIONS[payload.region], POPULATION_REGIONS_MANPOWER[payload.region];
		for class = 1, 5 do
			if not pop or not manpower or not MK1212_IsFiniteNumber(pop[class]) or not MK1212_IsFiniteNumber(manpower[class]) then return false; end
		end
		for class = 1, 5 do
			if refunds[class] > 0 then Change_Manpower_Region(payload.region, class, refunds[class]); end
		end
		return true;
	end);
	MKMP_Actions_Confirm(pending.id, ok and confirmed and "confirmed" or "uncertain");
	Log(ok and confirmed and "confirmed" or "uncertain", {action_id = pending.id, actor = pending.actor, kind = pending.payload.mode});
	return true;
end

function MKMP_Population_Actions_Get_State()
	local complete = not blocked and #MK1212_SaveSortedKeys(uncertain_queues) == 0;
	return MKMP_Diagnostic_Copy({schema = 1, complete = complete, blocked = blocked, reservations = reservations,
		revisions = revisions, revision_turns = revision_turns, uncertain = uncertain_queues,
		phases = phase_ledger, pending = pending_force or {}}), complete and "complete" or "incomplete",
		not complete and "population_accounting_uncertain" or nil;
end

function MKMP_Population_Actions_Initialize()
	if initialized then return; end
	initialized = true;
	MKMP_Actions_Register("population_recruit", {validate = Validate_Recruit, execute = Execute_Recruit});
	MKMP_Actions_Register("population_cancel", {validate = Validate_Cancel, execute = Execute_Cancel});
	MKMP_Actions_Register("population_force", {validate = Validate_Force, execute = Execute_Force});
end

function MKMP_Population_Prepare_Actions()
	local parts, rows, total, ids = {}, 0, 0, {};
	local current_turn = cm:model():turn_number();
	if not Integer(current_turn, 0, 1000000) then error("population invalid current turn"); end
	local queue_keys = MK1212_SaveSortedKeys(POPULATION_UNITS_IN_RECRUITMENT);
	if #queue_keys > MAX_COMMANDERS then error("population public queue commander budget"); end
	for i = 1, #queue_keys do
		local cqi = queue_keys[i];
		if not Commander_Key(cqi) then error("population invalid public commander"); end
		local count = MK1212_SaveDenseLength(POPULATION_UNITS_IN_RECRUITMENT[cqi], MAX_QUEUE);
		total = total + count;
		if total > MAX_RESERVATIONS or #(reservations[cqi] or {}) ~= count then
			error("population untracked queue or total reservation budget");
		end
	end
	total = 0;
	local function row(values)
		for i = 1, #values do MK1212_SaveAppend(parts, values[i], ","); end
		MK1212_SaveEndRow(parts); rows = rows + 1;
	end
	row({"meta", "1"});
	if blocked then row({"blocked", true}); end
	local keys = MK1212_SaveSortedKeys(revisions);
	if #keys > MAX_COMMANDERS then error("population revision commander budget"); end
	for i = 1, #keys do
		local cqi = keys[i];
		if not Commander_Key(cqi) or not Integer(revisions[cqi], 0, 1000000)
			or not Integer(revision_turns[cqi], 0, current_turn) then error("population invalid revision"); end
		row({"queue", cqi, revisions[cqi], revision_turns[cqi]});
	end
	keys = MK1212_SaveSortedKeys(reservations);
	if #keys > MAX_COMMANDERS then error("population reservation commander budget"); end
	for i = 1, #keys do
		local cqi, items = keys[i], reservations[keys[i]];
		if not Commander_Key(cqi) then error("population invalid reservation commander"); end
		local count = MK1212_SaveDenseLength(items, MAX_QUEUE);
		total = total + count;
		if total > MAX_RESERVATIONS then error("population total reservation budget"); end
		if count ~= #(POPULATION_UNITS_IN_RECRUITMENT[cqi] or {}) then error("population queue changed without reservation update"); end
		for slot = 1, count do
			local item = items[slot];
			if type(item) ~= "table" or type(item.id) ~= "string" or #item.id == 0 or #item.id > 256 or ids[item.id]
				or type(item.known) ~= "boolean" or type(item.horde) ~= "boolean"
				or type(item.region) ~= "string" or #item.region > 256
				or not Integer(item.class, item.known and 1 or 0, 5)
				or not Integer(item.amount, item.known and 1 or 0, 100000)
				or (item.known and (revisions[cqi] == nil or (not item.horde and item.region == "")))
				or type(item.unit) ~= "string" or item.unit ~= POPULATION_UNITS_IN_RECRUITMENT[cqi][slot] then
				error("population invalid unit reservation");
			end
			ids[item.id] = true;
			row({"reservation", cqi, slot, item.id, item.unit, item.region, item.class, item.amount, item.horde, item.known});
		end
	end
	keys = MK1212_SaveSortedKeys(phase_ledger);
	if #keys > 4096 then error("population phase ledger budget"); end
	for i = 1, #keys do
		if type(keys[i]) ~= "string" or #keys[i] == 0 or #keys[i] > 256
			or not Integer(phase_ledger[keys[i]], 0, current_turn) then error("population invalid phase ledger"); end
		row({"phase", keys[i], phase_ledger[keys[i]]});
	end
	keys = MK1212_SaveSortedKeys(uncertain_queues);
	if #keys > MAX_COMMANDERS then error("population uncertain queue budget"); end
	for i = 1, #keys do
		local cqi, item = keys[i], uncertain_queues[keys[i]];
		if not Commander_Key(cqi) or #(reservations[cqi] or {}) == 0
			or not Integer(item.turn, 0, current_turn) or type(item.reason) ~= "string"
			or #item.reason == 0 or #item.reason > 64 then error("population invalid uncertain queue"); end
		row({"uncertain", cqi, item.reason, item.turn});
	end
	return table.concat(parts), rows;
end

function MKMP_Population_Save_Actions(context, prepared, rows)
	if not prepared then prepared, rows = MKMP_Population_Prepare_Actions(); end
	-- One framed value owns reservation/revision/phase state. Unknown versions
	-- and inconsistent legacy queue strings fail before any live-state swap.
	MK1212_SaveCommitString(context, SAVE_KEY, prepared, rows);
end

function MKMP_Population_Load_Actions(context, queue)
	local raw = cm:load_value(SAVE_KEY, "", context);
	local schema = cm:load_value(SAVE_KEY.."__schema", 0, context);
	local next_items, next_revisions, next_turns, next_phases, next_uncertain = {}, {}, {}, {}, {};
	local next_blocked = false;
	local current_turn = cm:model():turn_number();
	if not Integer(current_turn, 0, 1000000) then error("population invalid load turn"); end
	local queue_keys = MK1212_SaveSortedKeys(queue);
	if #queue_keys > MAX_COMMANDERS then error("population commander budget"); end
	local total = 0;
	for i = 1, #queue_keys do
		local cqi = queue_keys[i];
		if not Commander_Key(cqi) then error("population invalid commander"); end
		total = total + MK1212_SaveDenseLength(queue[cqi], MAX_QUEUE);
		if total > MAX_RESERVATIONS then error("population total reservation budget"); end
	end
	if raw == "" and schema == 0 then
		-- Legacy saves contain only unit names. Preserve these records; their
		-- missing original debit region cannot become a guessed refund.
		for i = 1, #queue_keys do
			local cqi = queue_keys[i];
			next_items[cqi] = {};
			for slot = 1, #queue[cqi] do
				next_items[cqi][slot] = {id = "legacy:"..cqi..":"..slot, unit = queue[cqi][slot],
					region = "", class = 0, amount = 0, horde = false, known = false};
			end
		end
	else
		local rows = MK1212_LoadSaveRows(context, SAVE_KEY);
		if #rows < 1 or #rows > 2 + MAX_COMMANDERS * 2 + MAX_RESERVATIONS + 4096
			or #rows[1] ~= 2 or rows[1][1] ~= "meta" or rows[1][2] ~= "1" then error("population reservation version"); end
		local ids, counts = {}, {queue = 0, reservation = 0, phase = 0, uncertain = 0, blocked = 0};
		for i = 2, #rows do
			local row = rows[i];
			if row[1] == "queue" then
				if #row ~= 4 or next_revisions[row[2]] ~= nil then error("population revision row"); end
				local cqi, revision, turn = row[2], MK1212_SaveNumber(row[3], SAVE_KEY), MK1212_SaveNumber(row[4], SAVE_KEY);
				if not Commander_Key(cqi) or not Integer(revision, 0, 1000000)
					or not Integer(turn, 0, current_turn) then error("population revision value"); end
				next_revisions[cqi], next_turns[cqi] = revision, turn;
				counts.queue = counts.queue + 1;
			elseif row[1] == "phase" then
				if #row ~= 3 or next_phases[row[2]] ~= nil or #row[2] == 0 or #row[2] > 256 then error("population phase row"); end
				local turn = MK1212_SaveNumber(row[3], SAVE_KEY);
				if not Integer(turn, 0, current_turn) then error("population phase turn"); end
				next_phases[row[2]], counts.phase = turn, counts.phase + 1;
			elseif row[1] == "reservation" then
				if #row ~= 10 then error("population reservation shape"); end
				local cqi, slot = row[2], MK1212_SaveNumber(row[3], SAVE_KEY);
				if not Commander_Key(cqi)
					or not Integer(slot, 1, MAX_QUEUE) or ids[row[4]] or #row[4] == 0 or #row[4] > 256 then error("population reservation identity"); end
				local items = next_items[cqi] or {};
				if slot ~= #items + 1 or not queue[cqi] or queue[cqi][slot] ~= row[5] then error("population reservation queue mismatch"); end
				local class, amount = MK1212_SaveNumber(row[7], SAVE_KEY), MK1212_SaveNumber(row[8], SAVE_KEY);
				local horde, known = MK1212_SaveBoolean(row[9], SAVE_KEY), MK1212_SaveBoolean(row[10], SAVE_KEY);
				if not Integer(class, known and 1 or 0, 5) or not Integer(amount, known and 1 or 0, 100000)
					or #row[6] > 256 or (known and not horde and row[6] == "") then error("population reservation debit"); end
				if known and next_revisions[cqi] == nil then error("population missing queue revision"); end
				items[slot] = {id = row[4], unit = row[5], region = row[6], class = class, amount = amount, horde = horde, known = known};
				next_items[cqi], ids[row[4]] = items, true;
				counts.reservation = counts.reservation + 1;
			elseif row[1] == "uncertain" then
				if #row ~= 4 or not Commander_Key(row[2]) or next_uncertain[row[2]]
					or #row[3] == 0 or #row[3] > 64 then error("population uncertain queue row"); end
				local turn = MK1212_SaveNumber(row[4], SAVE_KEY);
				if not Integer(turn, 0, current_turn) then error("population uncertain queue turn"); end
				next_uncertain[row[2]] = {reason = row[3], turn = turn};
				counts.uncertain = counts.uncertain + 1;
			elseif row[1] == "blocked" then
				if #row ~= 2 or counts.blocked ~= 0 then error("population blocked row"); end
				next_blocked = MK1212_SaveBoolean(row[2], SAVE_KEY);
				counts.blocked = 1;
			else error("population unknown row type"); end
			if counts.queue > MAX_COMMANDERS or counts.reservation > MAX_RESERVATIONS
				or counts.phase > 4096 or counts.uncertain > MAX_COMMANDERS then error("population ledger budget"); end
		end
	end
	for i = 1, #queue_keys do
		if #(next_items[queue_keys[i]] or {}) ~= #queue[queue_keys[i]] then error("population missing reservation"); end
	end
	local uncertain_keys = MK1212_SaveSortedKeys(next_uncertain);
	for i = 1, #uncertain_keys do
		if #(next_items[uncertain_keys[i]] or {}) == 0 then error("population uncertain queue has no debit records"); end
	end
	reservations, revisions, revision_turns, phase_ledger = next_items, next_revisions, next_turns, next_phases;
	pending_force, blocked, uncertain_queues = nil, next_blocked, next_uncertain;
end
