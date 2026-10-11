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

function Add_Decisions_Listeners()
	Add_Decisions_UI_Listeners();
end

function Add_Decision(decision_key, faction_name, enabled, priority)
	-- Check first if the decision already exists!
	if #PRIORITY_DECISIONS > 0 then
		for i = 1, #PRIORITY_DECISIONS do
			if PRIORITY_DECISIONS[i][1] == decision_key then
				return;
			end	
		end
	end

	if #AVAILABLE_DECISIONS > 0 then
		for i = 1, #AVAILABLE_DECISIONS do
			if AVAILABLE_DECISIONS[i][1] == decision_key then
				return;
			end	
		end
	end

	-- Decision does not already exist, so add it.
	local decision = {decision_key, faction_name, enabled};

	if priority == true then
		table.insert(PRIORITY_DECISIONS, decision);
	else
		table.insert(AVAILABLE_DECISIONS, decision);
	end
end

function Remove_Decision(decision_key)
	if #PRIORITY_DECISIONS > 0 then
		for i = 1, #PRIORITY_DECISIONS do
			if PRIORITY_DECISIONS[i][1] == decision_key then
				--dev.log("Removing decision: "..PRIORITY_DECISIONS[i][1]);
				table.remove(PRIORITY_DECISIONS, i);
				--dev.log("Decision removed.");
				return;
			end	
		end
	end

	if #AVAILABLE_DECISIONS > 0 then
		for i = 1, #AVAILABLE_DECISIONS do
			if AVAILABLE_DECISIONS[i][1] == decision_key then
				--dev.log("Removing decision: "..AVAILABLE_DECISIONS[i][1]);
				table.remove(AVAILABLE_DECISIONS, i);
				--dev.log("Decision removed.");
				return;
			end	
		end
	end
end

function Register_Decision(decision_key, tooltip, required_regions, map_information, callback)
	REGISTRY_DECISIONS[decision_key] = {};

	REGISTRY_DECISIONS[decision_key].tooltip = tooltip;
	REGISTRY_DECISIONS[decision_key].required_regions = required_regions;
	REGISTRY_DECISIONS[decision_key].map_information = map_information;
	REGISTRY_DECISIONS[decision_key].callback = callback;
end

function Enable_Decision(decision_key)
	if #PRIORITY_DECISIONS > 0 then
		for i = 1, #PRIORITY_DECISIONS do
			if PRIORITY_DECISIONS[i][1] == decision_key and PRIORITY_DECISIONS[i][3] == false then
				PRIORITY_DECISIONS[i][3] = true;
				Highlight_Decisions_Button();
				--dev.log("Enabled decision: "..PRIORITY_DECISIONS[i][1]);
				return;
			end	
		end
	end

	if #AVAILABLE_DECISIONS > 0 then
		for i = 1, #AVAILABLE_DECISIONS do
			if AVAILABLE_DECISIONS[i][1] == decision_key and AVAILABLE_DECISIONS[i][3] == false then
				AVAILABLE_DECISIONS[i][3] = true;
				Highlight_Decisions_Button();
				--dev.log("Enabled decision: "..AVAILABLE_DECISIONS[i][1]);
				return;
			end	
		end
	end
end

function Disable_Decision(decision_key)
	if #PRIORITY_DECISIONS > 0 then
		for i = 1, #PRIORITY_DECISIONS do
			if PRIORITY_DECISIONS[i][1] == decision_key then
				PRIORITY_DECISIONS[i][3] = false;
				--dev.log("Disabled decision: "..PRIORITY_DECISIONS[i][1]);
				return;
			end	
		end
	end

	if #AVAILABLE_DECISIONS > 0 then
		for i = 1, #AVAILABLE_DECISIONS do
			if AVAILABLE_DECISIONS[i][1] == decision_key then
				AVAILABLE_DECISIONS[i][3] = false;
				--dev.log("Disabled decision: "..AVAILABLE_DECISIONS[i][1]);
				return;
			end	
		end
	end
end

------------------------------------------------
---------------- Saving/Loading ----------------
------------------------------------------------
cm:register_saving_game_callback(
	function(context)
		SaveDecisionsTable(context, AVAILABLE_DECISIONS, "AVAILABLE_DECISIONS");
		SaveDecisionsTable(context, PRIORITY_DECISIONS, "PRIORITY_DECISIONS");
	end
);

cm:register_loading_game_callback(
	function(context)
		AVAILABLE_DECISIONS = LoadDecisionsTable(context, "AVAILABLE_DECISIONS");
		PRIORITY_DECISIONS = LoadDecisionsTable(context, "PRIORITY_DECISIONS");
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
		local key = MK1212_SaveUniqueRow(seen, row, 3, savename);
		seen[key] = true;
		output[#output + 1] = {row[1], row[2], MK1212_SaveBoolean(row[3], savename)};
	end
	return output;
end
