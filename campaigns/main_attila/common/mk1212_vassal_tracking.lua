-----------------------------------------------------------------------------------------------------------------------
-----------------------------------------------------------------------------------------------------------------------
--
-- 	MEDIEVAL KINGDOMS 1212 - COMMON: VASSAL TRACKING
-- 	By: DETrooper
--
-----------------------------------------------------------------------------------------------------------------------
-----------------------------------------------------------------------------------------------------------------------
-- Sadly, Attila does not have built-in functions for checking if a faction is a vassal.
-- As such, a tracking system is necessary if annexing vassals is going to be a thing.

local PENDING_LIBERATION_CHECKS = {};
local PENDING_SUBJUGATIONS = {};
local PENDING_DIPLO_EVENTS = {};
local PENDING_OPERATION_MAX_AGE_TURNS = 1;

FACTIONS_TO_FACTIONS_VASSALIZED = {};

local function VassalTrackingLog(message)
	if dev and dev.log then
		dev.log("[MKMP][VASSAL] "..tostring(message));
	end
end

local function VassalTrackingSortedKeys(tab)
	local keys = {};

	for key, _ in pairs(tab) do
		table.insert(keys, key);
	end

	table.sort(keys);
	return keys;
end

local function VassalTrackingPairToken(first, second)
	return tostring(first).."|"..tostring(second);
end

local function VassalTrackingSplitPairToken(token)
	local separator = string.find(token, "|", 1, true);

	if not separator then
		return nil, nil;
	end

	return string.sub(token, 1, separator - 1), string.sub(token, separator + 1);
end

local function EnsureVassalList(faction_name)
	if not FACTIONS_TO_FACTIONS_VASSALIZED[faction_name] then
		FACTIONS_TO_FACTIONS_VASSALIZED[faction_name] = {};
	end

	return FACTIONS_TO_FACTIONS_VASSALIZED[faction_name];
end

local function IsValidFactionKey(faction_name)
	if not faction_name or faction_name == "" or faction_name == "nil" then
		return false;
	end

	local faction = cm:model():world():faction_by_key(faction_name);
	return faction and not faction:is_null_interface();
end

function Add_MK1212_Vassal_Tracking_Listeners()
	cm:add_listener(
		"FactionTurnStart_Vassal_Tracking",
		"FactionTurnStart",
		true,
		function(context) FactionTurnStartEnd_Vassal_Tracking(context) end,
		true
	);
	cm:add_listener(
		"FactionTurnEnd_Vassal_Tracking",
		"FactionTurnEnd",
		true,
		function(context) FactionTurnStartEnd_Vassal_Tracking(context) end,
		true
	);
	cm:add_listener(
		"FactionBecomesLiberationVassal_Vassal_Tracking",
		"FactionBecomesLiberationVassal",
		true,
		function(context) FactionBecomesLiberationVassal_Vassal_Tracking(context) end,
		true
	);
	cm:add_listener(
		"FactionSubjugatesOtherFaction_Vassal_Tracking",
		"FactionSubjugatesOtherFaction",
		true,
		function(context) FactionSubjugatesOtherFaction_Vassal_Tracking(context) end,
		true
	);
	cm:add_listener(
		"PositiveDiplomaticEvent_Vassal_Tracking",
		"PositiveDiplomaticEvent",
		true,
		function(context) PositiveDiplomaticEvent_Vassal_Tracking(context) end,
		true
	);
	cm:add_listener(
		"FactionLeaderDeclaresWar_Vassal_Tracking",
		"FactionLeaderDeclaresWar",
		true,
		function(context) FactionLeaderDeclaresWar_Vassal_Tracking(context) end,
		true
	)
	if cm:is_new_game() then
		local faction_list = cm:model():world():faction_list();

		for i = 0, faction_list:num_items() - 1 do
			local faction = faction_list:item_at(i);
			local faction_name = faction:name();
	
			FACTIONS_TO_FACTIONS_VASSALIZED[faction_name] = {};
	
			if FACTIONS_TO_FACTIONS_VASSALIZED_START[faction_name] then
				for j = 1, #FACTIONS_TO_FACTIONS_VASSALIZED_START[faction_name] do
					local vassal_faction_name = FACTIONS_TO_FACTIONS_VASSALIZED_START[faction_name][j];
	
					table.insert(FACTIONS_TO_FACTIONS_VASSALIZED[faction_name], vassal_faction_name);
				end
			end
		end
	end
end

function FactionTurnStartEnd_Vassal_Tracking(context)
	Process_Pending_Vassal_Operations();

	local faction = context:faction();
	local faction_name = faction:name();
	local faction_is_human = faction:is_human();

	if not FACTIONS_TO_FACTIONS_VASSALIZED[faction_name] then
		FACTIONS_TO_FACTIONS_VASSALIZED[faction_name] = {};
	end

	for i = 1, #FACTIONS_TO_FACTIONS_VASSALIZED[faction_name] do
		local vassal_faction_name = FACTIONS_TO_FACTIONS_VASSALIZED[faction_name][i];
		local vassal_faction = cm:model():world():faction_by_key(vassal_faction_name);

		if vassal_faction:region_list():num_items() < 1 or vassal_faction:at_war_with(faction) then
			Faction_Unvassalized(faction_name, vassal_faction_name);
			break;
		end
	end
end

function FactionBecomesLiberationVassal_Vassal_Tracking(context)
	local liberating_faction_name = context:liberating_character():faction():name();
	local vassal_faction_name = context:faction():name();
	local token = VassalTrackingPairToken(liberating_faction_name, vassal_faction_name);

	EnsureVassalList(liberating_faction_name);

	if not HasValue(FACTIONS_TO_FACTIONS_VASSALIZED[liberating_faction_name], vassal_faction_name) then
		PENDING_LIBERATION_CHECKS[token] = cm:model():turn_number();
	end
end

function FactionSubjugatesOtherFaction_Vassal_Tracking(context)
	local vassal_faction_name = context:other_faction():name();
	PENDING_SUBJUGATIONS[vassal_faction_name] = cm:model():turn_number();
end

function PositiveDiplomaticEvent_Vassal_Tracking(context)
	local proposer = context:proposer():name();
	local recipient = context:recipient():name();
	local token = VassalTrackingPairToken(proposer, recipient);

	PENDING_DIPLO_EVENTS[token] = cm:model():turn_number();
end

function FactionLeaderDeclaresWar_Vassal_Tracking(context)
	local faction_name = context:character():faction():name();

	if #FACTIONS_TO_FACTIONS_VASSALIZED[faction_name] > 0 then
		for i = 1, #FACTIONS_TO_FACTIONS_VASSALIZED[faction_name] do
			local vassal_faction_name = FACTIONS_TO_FACTIONS_VASSALIZED[faction_name][i];
			local vassal_faction = cm:model():world():faction_by_key(vassal_faction_name);

			if vassal_faction:at_war_with(context:character():faction()) then
				FACTIONS_VASSALIZED_DELAYS[vassal_faction_name] = nil;

				if Get_Vassal_Currently_Annexing(faction_name) == vassal_faction_name then
					Stop_Annexing_Vassal(faction_name, vassal_faction_name);
				end

				table.remove(FACTIONS_TO_FACTIONS_VASSALIZED[faction_name], i);
				return;
			end
		end
	else
		-- Faction has no vassals or is a vassal.
		local master_faction_name = Get_Vassal_Overlord(faction_name);

		if master_faction_name  then
			if cm:model():world():faction_by_key(master_faction_name):at_war_with(context:character():faction()) then
				for i = 1, #FACTIONS_TO_FACTIONS_VASSALIZED[master_faction_name] do
					if FACTIONS_TO_FACTIONS_VASSALIZED[master_faction_name][i] == faction_name then
						FACTIONS_VASSALIZED_DELAYS[faction_name] = nil;

						if Get_Vassal_Currently_Annexing(master_faction_name) == faction_name then
							Stop_Annexing_Vassal(master_faction_name, faction_name);
						end

						table.remove(FACTIONS_TO_FACTIONS_VASSALIZED[master_faction_name], i);
						return;
					end
				end
			end
		end
	end
end

function Process_Pending_Vassal_Operations()
	local current_turn = cm:model():turn_number();

	-- Liberation-vassal events need one stable campaign barrier before we can
	-- distinguish a true vassal from a normal liberated ally.
	for _, token in ipairs(VassalTrackingSortedKeys(PENDING_LIBERATION_CHECKS)) do
		local queued_turn = PENDING_LIBERATION_CHECKS[token];
		local master_faction_name, vassalized_faction_name = VassalTrackingSplitPairToken(token);

		if IsValidFactionKey(master_faction_name) and IsValidFactionKey(vassalized_faction_name) then
			local master_faction = cm:model():world():faction_by_key(master_faction_name);
			local vassalized_faction = cm:model():world():faction_by_key(vassalized_faction_name);

			if master_faction:allied_with(vassalized_faction) then
				VassalTrackingLog("liberation resolved as alliance token="..token);
			else
				local vassals = EnsureVassalList(master_faction_name);

				if not HasValue(vassals, vassalized_faction_name) then
					Faction_Vassalized(master_faction_name, vassalized_faction_name, true, true, true);
				end
			end

			PENDING_LIBERATION_CHECKS[token] = nil;
		elseif current_turn - queued_turn > PENDING_OPERATION_MAX_AGE_TURNS then
			VassalTrackingLog("dropping stale liberation token="..token);
			PENDING_LIBERATION_CHECKS[token] = nil;
		end
	end

	-- Subjugation is reported through two event families. Reconcile immutable
	-- records by recipient/vassal key instead of storing a single mutable
	-- proposer/recipient/vassal triple across a real-time delay.
	for _, vassalized_faction_name in ipairs(VassalTrackingSortedKeys(PENDING_SUBJUGATIONS)) do
		local subjugation_turn = PENDING_SUBJUGATIONS[vassalized_faction_name];
		local matches = {};

		for _, token in ipairs(VassalTrackingSortedKeys(PENDING_DIPLO_EVENTS)) do
			local proposer, recipient = VassalTrackingSplitPairToken(token);

			if recipient == vassalized_faction_name and PENDING_DIPLO_EVENTS[token] == subjugation_turn then
				table.insert(matches, {token = token, proposer = proposer});
			end
		end

		if #matches == 1 then
			local match = matches[1];

			if IsValidFactionKey(match.proposer) and IsValidFactionKey(vassalized_faction_name) then
				local vassals = EnsureVassalList(match.proposer);

				if not HasValue(vassals, vassalized_faction_name) then
					Faction_Vassalized(match.proposer, vassalized_faction_name, true, true, true);
				end
			end

			PENDING_DIPLO_EVENTS[match.token] = nil;
			PENDING_SUBJUGATIONS[vassalized_faction_name] = nil;
		elseif #matches > 1 then
			VassalTrackingLog("ambiguous subjugation for "..vassalized_faction_name.." matches="..tostring(#matches));
		elseif current_turn - subjugation_turn > PENDING_OPERATION_MAX_AGE_TURNS then
			VassalTrackingLog("dropping stale subjugation for "..vassalized_faction_name);
			PENDING_SUBJUGATIONS[vassalized_faction_name] = nil;
		end
	end

	-- Bound unmatched positive-diplomacy records.
	for _, token in ipairs(VassalTrackingSortedKeys(PENDING_DIPLO_EVENTS)) do
		if current_turn - PENDING_DIPLO_EVENTS[token] > PENDING_OPERATION_MAX_AGE_TURNS then
			VassalTrackingLog("dropping stale diplomacy token="..token);
			PENDING_DIPLO_EVENTS[token] = nil;
		end
	end
end

function Faction_Vassalized(master_faction_name, vassalized_faction_name, add_to_table, transfer_vassals, make_peace)
	if not IsValidFactionKey(master_faction_name) or not IsValidFactionKey(vassalized_faction_name) then
		VassalTrackingLog("refusing invalid vassalization "..tostring(master_faction_name).." -> "..tostring(vassalized_faction_name));
		return false;
	end

	local master_faction = cm:model():world():faction_by_key(master_faction_name);
	local vassalized_faction = cm:model():world():faction_by_key(vassalized_faction_name);
	local vassals = EnsureVassalList(master_faction_name);

	if add_to_table == true and not HasValue(vassals, vassalized_faction_name) then
		table.insert(vassals, vassalized_faction_name);
	end

	if transfer_vassals == true then
		Vassal_Transfer_Vassals_To_New_Master(master_faction_name, vassalized_faction_name);
	end

	if make_peace == true then
		Vassal_Make_Peace_With_Other_Vassals(vassalized_faction);
	end

	cm:trigger_event("FactionVassalized", master_faction, vassalized_faction);
end

function Faction_Unvassalized(master_faction_name, vassalized_faction_name)
	local master_faction = cm:model():world():faction_by_key(master_faction_name);
	local vassalized_faction = cm:model():world():faction_by_key(vassalized_faction_name);

	if not FACTIONS_TO_FACTIONS_VASSALIZED[master_faction_name] then
		FACTIONS_TO_FACTIONS_VASSALIZED[master_faction_name] = {};
	else
		for i = 1, #FACTIONS_TO_FACTIONS_VASSALIZED[master_faction_name] do
			local current_vassal_name = FACTIONS_TO_FACTIONS_VASSALIZED[master_faction_name][i];

			if current_vassal_name == vassalized_faction_name then
				table.remove(FACTIONS_TO_FACTIONS_VASSALIZED[master_faction_name], i);
				break;
			end
		end
	end

	cm:trigger_event("FactionUnvassalized", master_faction, vassalized_faction);
end

function Get_Vassal_Overlord(vassal_faction_name)
	for _, master_faction_name in ipairs(VassalTrackingSortedKeys(FACTIONS_TO_FACTIONS_VASSALIZED)) do
		local vassals = EnsureVassalList(master_faction_name);

		for i = 1, #vassals do
			if vassals[i] == vassal_faction_name then
				return master_faction_name;
			end
		end
	end
end

function Vassal_Transfer_Vassals_To_New_Master(master_faction_name, vassalized_faction_name)
	if FACTIONS_TO_FACTIONS_VASSALIZED[vassalized_faction_name] then
		if #FACTIONS_TO_FACTIONS_VASSALIZED[vassalized_faction_name] > 0 then
			for i = 1, #FACTIONS_TO_FACTIONS_VASSALIZED[vassalized_faction_name] do
				Faction_Vassalized(master_faction_name, FACTIONS_TO_FACTIONS_VASSALIZED[vassalized_faction_name][i], false, false, true);
			end
		end
	end

	FACTIONS_TO_FACTIONS_VASSALIZED[vassalized_faction_name] = {};
end

function Vassal_Make_Peace_With_Other_Vassals(faction)
	local faction_list = cm:model():world():faction_list();

	for i = 0, faction_list:num_items() - 1 do
		local current_faction = faction_list:item_at(i);
		local current_faction_name = current_faction:name();

		if current_faction:at_war_with(faction) then
			if HasValue(FACTIONS_TO_FACTIONS_VASSALIZED[faction:name()], current_faction_name) then
				cm:force_make_peace(current_faction_name, faction:name());
			end
		end
	end
end

------------------------------------------------
---------------- Saving/Loading ----------------
------------------------------------------------
cm:register_loading_game_callback(
	function(context)
		FACTIONS_TO_FACTIONS_VASSALIZED = LoadKeyPairTables(context, "FACTIONS_TO_FACTIONS_VASSALIZED");
		PENDING_LIBERATION_CHECKS = LoadKeyPairTableNumbers(context, "PENDING_VASSAL_LIBERATION_CHECKS");
		PENDING_SUBJUGATIONS = LoadKeyPairTableNumbers(context, "PENDING_VASSAL_SUBJUGATIONS");
		PENDING_DIPLO_EVENTS = LoadKeyPairTableNumbers(context, "PENDING_VASSAL_DIPLO_EVENTS");

		local faction_list = cm:model():world():faction_list();
		for i = 0, faction_list:num_items() - 1 do
			EnsureVassalList(faction_list:item_at(i):name());
		end
	end
);

cm:register_saving_game_callback(
	function(context)
		SaveKeyPairTables(context, FACTIONS_TO_FACTIONS_VASSALIZED, "FACTIONS_TO_FACTIONS_VASSALIZED");
		SaveKeyPairTable(context, PENDING_LIBERATION_CHECKS, "PENDING_VASSAL_LIBERATION_CHECKS");
		SaveKeyPairTable(context, PENDING_SUBJUGATIONS, "PENDING_VASSAL_SUBJUGATIONS");
		SaveKeyPairTable(context, PENDING_DIPLO_EVENTS, "PENDING_VASSAL_DIPLO_EVENTS");
	end
);
