-------------------------------------------------------------------------------------------------------------
-------------------------------------------------------------------------------------------------------------
--
-- 	MEDIEVAL KINGDOMS 1212 - MECHANICS: DECISIONS
-- 	By: DETrooper
--
-------------------------------------------------------------------------------------------------------------
-------------------------------------------------------------------------------------------------------------

require("mechanics/decisions/mechanics_decisions_ui");

AVAILABLE_DECISIONS = {};
PRIORITY_DECISIONS = {}; -- For important ones. Same as AVAILABLE_DECISIONS but these are always at the top of the list.
REGISTRY_DECISIONS = {}; -- Stored decision data such as functions.

local decisions_initialized = false;
local DECISIONS_MAX_ROWS = 512;

local function Decision_Key(key, owner)
	if type(key) ~= "string" or type(owner) ~= "string" or key == "" or owner == ""
		or #key > 256 or #owner > 256 then return nil; end
	return #key..":"..key..#owner..":"..owner;
end

function MKMP_Find_Decision(decision_key, faction_name)
	if not Decision_Key(decision_key, faction_name) then return nil; end
	local lists = {PRIORITY_DECISIONS, AVAILABLE_DECISIONS};
	for i = 1, #lists do
		for j = 1, #lists[i] do
			local row = lists[i][j];
			if row[1] == decision_key and row[2] == faction_name then return row, lists[i], j; end
		end
	end
end

local function Validate_Decision_Action(actor, payload)
	local row = MKMP_Find_Decision(payload.decision_key, actor);
	local registered = REGISTRY_DECISIONS[payload.decision_key];
	local faction = cm:model():world():faction_by_key(actor);
	if not row or row[3] ~= true or not registered or type(registered.callback) ~= "function"
		or not faction or faction:is_null_interface() or not faction:is_human() then
		return false, "decision_not_available_for_actor";
	end
	if payload.decision_key == "ask_pope_for_money" then
		if not MKMP_Papal_Validate_Loan then return false, "loan_validator_unavailable"; end
		return MKMP_Papal_Validate_Loan(actor);
	end
	return true;
end

local function Execute_Decision_Action(actor, payload)
	local loan = payload.decision_key == "ask_pope_for_money";
	local previous_favour = loan and FACTION_POPE_FAVOUR and FACTION_POPE_FAVOUR[actor];
	local result = REGISTRY_DECISIONS[payload.decision_key].callback(actor);
	if result == false then return false, "decision_effect_unknown"; end
	local row = MKMP_Find_Decision(payload.decision_key, actor);
	local script_complete = loan and type(previous_favour) == "number"
		and FACTION_POPE_FAVOUR[actor] == previous_favour - 3;
	if not loan then script_complete = not row or row[3] == false; end
	-- Confirm only the callback's observed Lua bookkeeping transition. Native
	-- commands remain unproven; MP cannot enter this SP executor at all. A normal
	-- consumed decision must not become a kind-wide permanent lock on reload.
	if script_complete then return true, "script_complete"; end
	return true, "requested";
end

function Add_Decisions_Listeners()
	if decisions_initialized then return; end
	decisions_initialized = true;
	MKMP_Actions_Register("decision", {validate = Validate_Decision_Action, execute = Execute_Decision_Action});
	MKMP_Actions_Register("papal_loan", {validate = function(actor, payload)
		if payload.decision_key ~= "ask_pope_for_money" then return false, "wrong_loan_decision"; end
		return Validate_Decision_Action(actor, payload);
	end, execute = Execute_Decision_Action});
	Add_Decisions_UI_Listeners();
end

function MKMP_Decisions_Submit(decision_key, faction_name)
	local kind = decision_key == "ask_pope_for_money" and "papal_loan" or "decision";
	return MKMP_Actions_Submit_Local(kind, faction_name, {decision_key = decision_key});
end

function MKMP_Decisions_Get_State()
	local snapshot = MKMP_Diagnostic_Copy({schema = 1, enabled = decisions_initialized, available = AVAILABLE_DECISIONS, priority = PRIORITY_DECISIONS});
	return snapshot, "complete";
end

function Add_Decision(decision_key, faction_name, enabled, priority)
	if not Decision_Key(decision_key, faction_name) or type(enabled) ~= "boolean" then return false; end
	if MKMP_Find_Decision(decision_key, faction_name) then return false; end
	if #AVAILABLE_DECISIONS + #PRIORITY_DECISIONS >= DECISIONS_MAX_ROWS then return false; end
	local list = priority == true and PRIORITY_DECISIONS or AVAILABLE_DECISIONS;
	list[#list + 1] = {decision_key, faction_name, enabled};
	return true;
end

function Remove_Decision(decision_key, faction_name)
	local row, list, index = MKMP_Find_Decision(decision_key, faction_name);
	if not row then return false; end
	table.remove(list, index);
	return true;
end

function Register_Decision(decision_key, tooltip, required_regions, map_information, callback)
	REGISTRY_DECISIONS[decision_key] = {tooltip = tooltip, required_regions = required_regions,
		map_information = map_information, callback = callback};
end

function Enable_Decision(decision_key, faction_name)
	local row = MKMP_Find_Decision(decision_key, faction_name);
	if not row then return false; end
	if row[3] == false then
		row[3] = true;
		if Highlight_Decisions_Button then pcall(Highlight_Decisions_Button); end
	end
	return true;
end

function Disable_Decision(decision_key, faction_name)
	local row = MKMP_Find_Decision(decision_key, faction_name);
	if not row then return false; end
	row[3] = false;
	return true;
end

------------------------------------------------
---------------- Saving/Loading ----------------
------------------------------------------------
cm:register_saving_game_callback(
	function(context)
		SaveDecisionsTable(context, AVAILABLE_DECISIONS, "AVAILABLE_DECISIONS");
		SaveDecisionsTable(context, PRIORITY_DECISIONS, "PRIORITY_DECISIONS");
		cm:save_value("MKMP_DECISIONS_OWNER_SCHEMA", 1, context);
	end
);

cm:register_loading_game_callback(
	function(context)
		local schema = cm:load_value("MKMP_DECISIONS_OWNER_SCHEMA", 0, context);
		if schema ~= 0 and schema ~= 1 then error("MK1212 load refused: decision ownership schema"); end
		local available = LoadDecisionsTable(context, "AVAILABLE_DECISIONS");
		local priority = LoadDecisionsTable(context, "PRIORITY_DECISIONS");
		local seen = {};
		for _, list in ipairs({priority, available}) do
			for i = 1, #list do
				local key = Decision_Key(list[i][1], list[i][2]);
				if seen[key] then error("MK1212 load refused: duplicated decision owner"); end
				seen[key] = true;
			end
		end
		if #available + #priority > DECISIONS_MAX_ROWS then error("MK1212 decision budget"); end
		AVAILABLE_DECISIONS, PRIORITY_DECISIONS = available, priority;
	end
);

function SaveDecisionsTable(context, tab, savename)
	local parts = {};
	local count = MK1212_SaveDenseLength(tab);
	for i = 1, count do
		local row = tab[i];
		if MK1212_SaveDenseLength(row) ~= 3 or type(row[1]) ~= "string"
			or type(row[2]) ~= "string" or type(row[3]) ~= "boolean" then
			error("MK1212 save refused: invalid decision record");
		end
		MK1212_SaveAppend(parts, row[1], ",");
		MK1212_SaveAppend(parts, row[2], ",");
		MK1212_SaveAppend(parts, row[3], ",;");
	end
	MK1212_SaveCommitString(context, savename, table.concat(parts), count);
end

function LoadDecisionsTable(context, savename)
	local rows = MK1212_LoadSaveRows(context, savename);
	local output = {};
	local seen = {};
	for i = 1, #rows do
		local row = rows[i];
		local key = #row == 3 and Decision_Key(row[1], row[2]) or nil;
		if not key or seen[key] then error("MK1212 load refused: malformed/duplicate owned decision"); end
		seen[key] = true;
		output[#output + 1] = {row[1], row[2], MK1212_SaveBoolean(row[3], savename)};
	end
	return output;
end
