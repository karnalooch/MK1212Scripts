------------------------------------------------------------------------------------------------------------------
------------------------------------------------------------------------------------------------------------------
--
-- 	MEDIEVAL KINGDOMS 1212 - MECHANICS: POPE FAVOUR
-- 	By: DETrooper
--
------------------------------------------------------------------------------------------------------------------
------------------------------------------------------------------------------------------------------------------

-- This is the code that makes the Pope disapprove of your actions, you heretic!
-- Favour works from 0 to 10, similar to Medieval II. Being at 1 is a mild chance of excommunication, while 0 is excommunication for sure!
-- This script also handles the 'borrow money from the pope' decision for Catholic factions.

PAPAL_STATES_KEY = "mk_fact_papacy";

PAPAL_FAVOUR_SYSTEM_ACTIVE = true; -- Disabled if Papal States faction does not exist.
PAPAL_FAVOUR_SYSTEM_FORCE_STOPPED = false; -- Papal favour will never restart even if the Papal States faction is alive.
FACTION_POPE_FAVOUR = {};
FACTION_EXCOMMUNICATED = {};
MAX_POPE_FAVOUR = 10;
MIN_POPE_FAVOUR = 0;
AT_WAR_WITH_POPE = {};
FAVOUR_LAST_ATTACKED_GARRISON = "";
POPE_DEPOSED = false;

local papal_initialized = false;
local papal_active_listeners = false;
local papal_battle_ordinal = 0;
local papal_battle = nil;
local papal_battle_valid = true;
local papal_battle_raw = "";
local papal_battle_prefix = "MKMP_PAPAL_BATTLE_V1;";
local papal_battle_results = {
	heroic_victory = true, decisive_victory = true, close_victory = true,
	pyrrhic_victory = true, valiant_defeat = true, close_defeat = true,
	decisive_defeat = true, crushing_defeat = true
};

local function Papal_Log(stage, fields)
	fields = fields or {};
	fields.domain = fields.domain or "shared_candidate";
	fields.mechanic = "papal";
	fields.stage = stage;
	fields.shared_delivery = "unproven";
	fields.action_identity = fields.action_identity or "observer_lifecycle";
	if fields.action_identity == "observer_lifecycle" then
		fields.action_id = "papal_battle:"..string.format("%.0f", papal_battle_ordinal);
	end
	fields.phase = fields.phase or (papal_battle and papal_battle.phase or "no_battle");
	if MKMP_Debug_Log then pcall(MKMP_Debug_Log, "papal_action", fields); end
end

local function Papal_Read(object, method, ...)
	if object == nil then return nil; end
	local args = {...};
	local ok, value = pcall(function() return object[method](object, unpack(args)); end);
	if ok then return value; end
	return nil;
end

local function Papal_Valid_Interface(object)
	return object ~= nil and Papal_Read(object, "is_null_interface") == false;
end

local function Papal_Key(value)
	return type(value) == "string" and #value > 0 and #value <= 128
		and string.match(value, "^[A-Za-z0-9_%.%-]+$") ~= nil;
end

local function Papal_Integer(value)
	-- Attila's Lua number is float: every admitted ordinal/CQI is exact.
	return type(value) == "number" and value == value and value >= 0
		and value <= 16777215 and value == math.floor(value);
end

local function Papal_Faction(faction_name)
	if not Papal_Key(faction_name) then return nil; end
	local faction = Papal_Read(cm:model():world(), "faction_by_key", faction_name);
	if Papal_Valid_Interface(faction) then return faction; end
	return nil;
end

local function Papal_Character(context)
	local character = Papal_Read(context, "character");
	if not Papal_Valid_Interface(character) then return nil; end
	local faction = Papal_Read(character, "faction");
	if not Papal_Valid_Interface(faction) then return nil; end
	return character, faction;
end

local function Papal_Show_Message(...)
	-- Optional UI must not abort the rest of a valid campaign transition.
	local args = {...};
	local ok = pcall(function() cm:show_message_event(unpack(args)); end);
	if not ok then Papal_Log("ui_failed", {domain = "diagnostic"}); end
end

local function Papal_Faction_Label(faction_name)
	local rank = type(FACTIONS_DFN_LEVEL) == "table" and FACTIONS_DFN_LEVEL[faction_name];
	if Papal_Integer(rank) and rank > 1 then
		return "campaign_localised_strings_string_"..faction_name.."_lvl"..string.format("%.0f", rank);
	end
	return "factions_screen_name_"..faction_name;
end

local function Papal_Battle_Participant(pending_battle, side)
	if Papal_Read(pending_battle, "has_"..side) ~= true then return nil; end
	local character = Papal_Read(pending_battle, side);
	if not Papal_Valid_Interface(character) or Papal_Read(character, "has_military_force") ~= true then return nil; end
	local faction = Papal_Read(character, "faction");
	local force = Papal_Read(character, "military_force");
	if not Papal_Valid_Interface(faction) or force == nil then return nil; end
	local name = Papal_Read(faction, "name");
	local cqi = Papal_Read(character, "cqi");
	local force_cqi = Papal_Read(force, "command_queue_index");
	if not Papal_Key(name) or not Papal_Integer(cqi) or not Papal_Integer(force_cqi) then return nil; end
	return {faction = name, cqi = cqi, force = force_cqi,
		catholic = Papal_Read(faction, "state_religion") == "att_rel_chr_catholic"};
end

local function Papal_Same_Participant(first, second)
	return first and second and first.faction == second.faction
		and first.cqi == second.cqi and first.force == second.force;
end

function PendingBattle_Pope_Favour(context)
	if not papal_battle_valid then Papal_Log("blocked", {reason = "invalid_battle_save"}); return; end
	local pending_battle = cm:model():pending_battle();
	local attacker = Papal_Battle_Participant(pending_battle, "attacker");
	local defender = Papal_Battle_Participant(pending_battle, "defender");
	if not attacker or not defender or attacker.faction == defender.faction then
		papal_battle = nil; -- Never retain the previous battle as a fallback.
		Papal_Log("blocked", {reason = "missing_battle_participant", phase = "pending_battle"});
		return;
	end
	if papal_battle and papal_battle.phase == "pending"
		and Papal_Same_Participant(papal_battle.attacker, attacker)
		and Papal_Same_Participant(papal_battle.defender, defender) then
		Papal_Log("duplicate", {reason = "pending_battle_already_open"});
		return;
	end
	if papal_battle_ordinal >= 16777215 then
		papal_battle_valid = false;
		papal_battle_raw = "MKMP_PAPAL_BATTLE_BLOCKED|ordinal_budget";
		Papal_Log("blocked", {reason = "battle_ordinal_budget"});
		return;
	end
	-- This is an observer's lifecycle ordinal, NOT an engine/network battle ID.
	-- Only a new PendingBattle opens a lifecycle. Completed/decision callbacks
	-- cannot manufacture a battle from turn/faction/general identifiers.
	papal_battle_ordinal = papal_battle_ordinal + 1;
	local turn = cm:model():turn_number();
	if not Papal_Integer(turn) then papal_battle = nil; return; end
	papal_battle = {phase = "pending", round = turn, attacker = attacker, defender = defender, decisions = {}};
	Papal_Log("observed", {phase = "pending_battle", actor = attacker.faction, target = defender.faction});
end

local function Papal_Observe_Battle_Result(context)
	local character, faction = Papal_Character(context);
	if not papal_battle_valid or not papal_battle or not character then
		Papal_Log("blocked", {reason = "missing_battle_lifecycle_or_actor"}); return nil;
	end
	if papal_battle.round ~= cm:model():turn_number() then
		Papal_Log("blocked", {reason = "battle_lifecycle_from_earlier_round"}); return nil;
	end
	local actor = Papal_Read(faction, "name");
	if actor ~= papal_battle.attacker.faction and actor ~= papal_battle.defender.faction then
		Papal_Log("blocked", {actor = actor, reason = "actor_outside_captured_battle"}); return nil;
	end
	local pending_battle = cm:model():pending_battle();
	local attacker = Papal_Battle_Participant(pending_battle, "attacker");
	local defender = Papal_Battle_Participant(pending_battle, "defender");
	if not Papal_Same_Participant(papal_battle.attacker, attacker)
		or not Papal_Same_Participant(papal_battle.defender, defender) then
		Papal_Log("blocked", {actor = actor, reason = "stale_or_missing_battle_participant"}); return nil;
	end
	local attacker_result = Papal_Read(pending_battle, "attacker_battle_result");
	local defender_result = Papal_Read(pending_battle, "defender_battle_result");
	if not papal_battle_results[attacker_result] or not papal_battle_results[defender_result]
		or (attacker_result == "close_defeat" and defender_result == "close_defeat") then
		Papal_Log("blocked", {actor = actor, reason = "unresolved_or_retreat_result"}); return nil;
	end
	if papal_battle.phase == "result" and (papal_battle.attacker_result ~= attacker_result
		or papal_battle.defender_result ~= defender_result) then
		Papal_Log("blocked", {actor = actor, reason = "conflicting_result"}); return nil;
	end
	papal_battle.phase = "result";
	papal_battle.attacker_result, papal_battle.defender_result = attacker_result, defender_result;
	return character, faction;
end

local function Papal_Save_Battle_State(context)
	if not papal_battle_valid then
		cm:save_value("MKMP_PAPAL_BATTLE_STATE", papal_battle_raw, context);
		return;
	end
	local rows = {papal_battle_prefix, string.format("O,%.0f;", papal_battle_ordinal)};
	if papal_battle then
		local b = papal_battle;
		rows[#rows + 1] = table.concat({"B", b.phase, string.format("%.0f", b.round), b.attacker.faction,
			string.format("%.0f", b.attacker.cqi), string.format("%.0f", b.attacker.force), tostring(b.attacker.catholic),
			b.defender.faction, string.format("%.0f", b.defender.cqi), string.format("%.0f", b.defender.force),
			tostring(b.defender.catholic), b.attacker_result or "none", b.defender_result or "none"}, ",")..";";
		local keys = MK1212_SaveSortedKeys(b.decisions);
		if #keys > 2 then error("MK1212 Papal battle decision budget exceeded"); end
		for i = 1, #keys do
			local decision = b.decisions[keys[i]];
			rows[#rows + 1] = "D,"..keys[i]..","..decision.kind..","..decision.status..";";
		end
	end
	local payload = table.concat(rows);
	if #payload > 4096 then error("MK1212 Papal battle save byte budget exceeded"); end
	-- Version and state share one engine value; no independent schema sidecar.
	cm:save_value("MKMP_PAPAL_BATTLE_STATE", payload, context);
end

local function Papal_Load_Battle_State(context)
	local raw = cm:load_value("MKMP_PAPAL_BATTLE_STATE", "", context);
	papal_battle_raw = raw;
	papal_battle, papal_battle_ordinal, papal_battle_valid = nil, 0, false;
	if raw == "" then papal_battle_valid = true; return; end -- Legacy: require a fresh PendingBattle.
	if type(raw) ~= "string" or #raw > 4096 or string.sub(raw, 1, #papal_battle_prefix) ~= papal_battle_prefix then
		Papal_Log("blocked", {reason = "unknown_or_oversized_battle_save"}); return;
	end
	local body = string.sub(raw, #papal_battle_prefix + 1);
	local ordinal, position = string.match(body, "^O,(%d+);()");
	ordinal = tonumber(ordinal);
	if not Papal_Integer(ordinal) then return; end
	if position > #body then papal_battle_ordinal, papal_battle_valid = ordinal, true; return; end
	local first, last, phase, round, aname, acqi, aforce, acatholic, dname, dcqi, dforce, dcatholic, aresult, dresult =
		string.find(body, "B,([^,;]+),(%d+),([^,;]+),(%d+),(%d+),([^,;]+),([^,;]+),(%d+),(%d+),([^,;]+),([^,;]+),([^,;]+);", position);
	if first ~= position or ordinal == 0 or (phase ~= "pending" and phase ~= "result")
		or not Papal_Integer(tonumber(round)) or tonumber(round) > cm:model():turn_number()
		or not Papal_Key(aname) or not Papal_Key(dname) or aname == dname
		or not Papal_Integer(tonumber(acqi)) or not Papal_Integer(tonumber(aforce))
		or not Papal_Integer(tonumber(dcqi)) or not Papal_Integer(tonumber(dforce))
		or (acatholic ~= "true" and acatholic ~= "false") or (dcatholic ~= "true" and dcatholic ~= "false")
		or (phase == "pending" and (aresult ~= "none" or dresult ~= "none"))
		or (phase == "result" and (not papal_battle_results[aresult] or not papal_battle_results[dresult])) then return; end
	local battle = {phase = phase, round = tonumber(round), decisions = {},
		attacker = {faction = aname, cqi = tonumber(acqi), force = tonumber(aforce), catholic = acatholic == "true"},
		defender = {faction = dname, cqi = tonumber(dcqi), force = tonumber(dforce), catholic = dcatholic == "true"}};
	if phase == "result" then battle.attacker_result, battle.defender_result = aresult, dresult; end
	position = last + 1;
	local count = 0;
	while position <= #body do
		local start, finish, actor, kind, status = string.find(body, "D,([^,;]+),([^,;]+),([^,;]+);", position);
		if start ~= position or phase ~= "result" or (actor ~= aname and actor ~= dname) or battle.decisions[actor]
			or (kind ~= "RELEASE" and kind ~= "ENSLAVE" and kind ~= "SLAUGHTER")
			or (status ~= "claimed" and status ~= "requested" and status ~= "unknown") or count >= 2 then return; end
		-- A saved claim cannot be replayed: some engine effects may already exist.
		battle.decisions[actor] = {kind = kind, status = status == "claimed" and "unknown" or status};
		count = count + 1;
		position = finish + 1;
	end
	papal_battle, papal_battle_ordinal, papal_battle_valid = battle, ordinal, true;
end

function MKMP_Papal_Get_State()
	local function copy(value)
		if type(value) ~= "table" then return value; end
		local result = {};
		local keys = MK1212_SaveSortedKeys(value);
		if #keys > 4096 then error("Papal diagnostic snapshot exceeds entry budget"); end
		for i = 1, #keys do result[keys[i]] = copy(value[keys[i]]); end
		return result;
	end
	return {schema = 1, complete = papal_battle_valid, favour = copy(FACTION_POPE_FAVOUR),
		excommunicated = copy(FACTION_EXCOMMUNICATED), at_war = copy(AT_WAR_WITH_POPE),
		active = PAPAL_FAVOUR_SYSTEM_ACTIVE, force_stopped = PAPAL_FAVOUR_SYSTEM_FORCE_STOPPED,
		deposed = POPE_DEPOSED, last_attacked_garrison = FAVOUR_LAST_ATTACKED_GARRISON,
		postbattle = {schema = 1, enabled = papal_battle_valid, ordinal = papal_battle_ordinal,
			identity = "observer_lifecycle_unproven", current = papal_battle and copy(papal_battle) or false}};
end

function Add_Pope_Favour_Listeners()
	if papal_initialized then return; end
	papal_initialized = true;
	if MKMP_Debug_Register_State_Provider then
		pcall(MKMP_Debug_Register_State_Provider, "papal", function()
			local data = MKMP_Papal_Get_State();
			if data.complete then return data, "complete"; end
			return data, "incomplete", "papal_battle_state_invalid";
		end);
	end
	cm:add_listener(
		"FactionTurnStart_Check_Catholic_Nations",
		"FactionTurnStart",
		true,
		function(context) FactionTurnStart_Check_Catholic_Nations(context) end,
		true
	);

	if PAPAL_FAVOUR_SYSTEM_ACTIVE == true and PAPAL_FAVOUR_SYSTEM_FORCE_STOPPED == false then
		Activate_Papal_Favour_System();
	end

	if (not cm:is_multiplayer() or MKMP_SP_Parity_Enabled("pope_favour_decisions")) then
		Register_Decision(
			"ask_pope_for_money", 
			function() 	
				local conditionstring = "Conditions:\n\n([[rgba:8:201:27:150]]Y[[/rgba]]) - Is religion: Catholic.\n";
				local money = "5000";
				local faction_name = cm:get_local_faction();
				
				if FACTION_EXCOMMUNICATED[faction_name] == true then
					conditionstring = conditionstring.."([[rgba:255:0:0:150]]X[[/rgba]]) - Is not excommunicated.\n";
				else
					conditionstring = conditionstring.."([[rgba:8:201:27:150]]Y[[/rgba]]) - Is not excommunicated.\n";
				end
			
				if (FACTION_POPE_FAVOUR[faction_name] or 0) > 7 then
					conditionstring = conditionstring.."([[rgba:8:201:27:150]]Y[[/rgba]]) - Papal Favour is greater than 7.\n";
				else
					conditionstring = conditionstring.."([[rgba:255:0:0:150]]X[[/rgba]]) - Papal Favour is greater than 7.\n";
				end
			
				if FACTION_POPE_FAVOUR[faction_name] == 9 then
					money = "7500";
				elseif FACTION_POPE_FAVOUR[faction_name] == 10 then
					money = "10000";
				end
			
				conditionstring = conditionstring.."\nEffects:\n\n- Recieve [[rgba:255:215:0:215]]"..money.." money[[/rgba]] at the cost of [[rgba:255:0:0:150]]3 Papal Favour[[/rgba]].";
			
				return conditionstring;
			end, 
			nil, 
			nil, 
			Decision_Pope_Money
		);
	end
	
	local faction_list = cm:model():world():faction_list();
	local pope_faction = cm:model():world():faction_by_key(PAPAL_STATES_KEY);

	for i = 0, faction_list:num_items() - 1 do
		local current_faction = faction_list:item_at(i);

		AT_WAR_WITH_POPE[current_faction:name()] = current_faction:at_war_with(pope_faction);

		if cm:is_new_game() then
			if current_faction:state_religion() == "att_rel_chr_catholic" and current_faction ~= pope_faction then
				if current_faction:name() ~= "mk_fact_hre" and current_faction:name() ~= "mk_fact_portugal" then
					cm:apply_effect_bundle("mk_bundle_pope_favour_5", current_faction:name(), 0);
					FACTION_POPE_FAVOUR[current_faction:name()] = 5;

					if current_faction:is_human() and (not cm:is_multiplayer() or MKMP_SP_Parity_Enabled("pope_favour_decisions")) then
						Add_Decision("ask_pope_for_money", current_faction:name(), false, false);
					end
				else
					Force_Excommunication(current_faction:name(), true);
				end
			end
		end
	end
end

function Activate_Papal_Favour_System()
	if papal_active_listeners then return; end
	papal_active_listeners = true;
	cm:add_listener(
		"PendingBattle_Pope_Favour",
		"PendingBattle",
		true,
		function(context) PendingBattle_Pope_Favour(context) end,
		true
	);
	cm:add_listener(
		"FactionLeaderDeclaresWar_Pope",
		"FactionLeaderDeclaresWar",
		true,
		function(context) Check_Excommunication_Pope_War(context) end,
		true
	);
	cm:add_listener(
		"GarrisonAttackedEvent_Pope",
		"GarrisonAttackedEvent",
		true,
		function(context) GarrisonAttackedEvent_Pope(context) end,
		true
	);
	cm:add_listener(
		"CharacterPerformsOccupationDecisionLoot_Pope",
		"CharacterPerformsOccupationDecisionLoot",
		true,
		function(context) Check_If_Catholic_Attacked(context, "LOOTED") end,
		true
	);
	cm:add_listener(
		"CharacterPerformsOccupationDecisionSack_Pope",
		"CharacterPerformsOccupationDecisionSack",
		true,
		function(context) Check_If_Catholic_Attacked(context, "SACKED") end,
		true 
	);
	cm:add_listener(
		"CharacterPerformsOccupationDecisionOccupy_Pope",
		"CharacterPerformsOccupationDecisionOccupy",
		true,
		function(context) Check_If_Catholic_Attacked(context, "OCCUPY") end,
		true
	);
	cm:add_listener(
		"CharacterCompletedBattle_Pope_Favour",
		"CharacterCompletedBattle",
		true,
		function(context) CharacterCompletedBattle_Pope_Favour(context) end,
		true
	);
	cm:add_listener(
		"CharacterParticipatedAsSecondaryGeneralInBattle_Pope_Favour",
		"CharacterParticipatedAsSecondaryGeneralInBattle",
		true,
		function(context) CharacterCompletedBattle_Pope_Favour(context) end,
		true
	);
	cm:add_listener(
		"CharacterPostBattleEnslave_Pope",
		"CharacterPostBattleEnslave",
		true,
		function(context) CharacterPostBattle_Favour(context, "ENSLAVE") end,
		true
	);
	cm:add_listener(
		"CharacterPostBattleRelease_Pope",
		"CharacterPostBattleRelease",
		true,
		function(context) CharacterPostBattle_Favour(context, "RELEASE") end,
		true
	);
	cm:add_listener(
		"CharacterPostBattleSlaughter_Pope",
		"CharacterPostBattleSlaughter",
		true,
		function(context) CharacterPostBattle_Favour(context, "SLAUGHTER") end,
		true
	);
	cm:add_listener(
		"CharacterBecomesFactionLeader_Pope_Favour",
		"CharacterBecomesFactionLeader",
		true,
		function(context) Remove_Excommunication(context) end,
		true
	);
	cm:add_listener(
		"DilemmaChoiceMadeEvent_Pope",
		"DilemmaChoiceMadeEvent",
		true,
		function(context) DilemmaChoiceMadeEvent_Pope(context) end,
		true
	);
	cm:add_listener(
		"FactionReligionConverted_Pope",
		"FactionReligionConverted",
		true,
		function(context) FactionReligionConverted_Pope(context) end,
		true
	);
	cm:add_listener(
		"MissionFailed_Check_Mission",
		"MissionFailed",
		true,
		function(context) MissionFailed_Check_Mission(context) end,
		true
	);
	cm:add_listener(
		"MissionSucceeded_Check_Mission",
		"MissionSucceeded",
		true,
		function(context) MissionSucceeded_Check_Mission(context) end,
		true
	);
end

function Reactivate_Papal_Favour_System()
	if PAPAL_FAVOUR_SYSTEM_FORCE_STOPPED == false then
		PAPAL_FAVOUR_SYSTEM_ACTIVE = true;
		Activate_Papal_Favour_System();

		local faction_list = cm:model():world():faction_list();

		for i = 0, faction_list:num_items() - 1 do
			local current_faction = faction_list:item_at(i);

			cm:remove_effect_bundle("mk_bundle_christian_dejection", current_faction:name());

			if current_faction:state_religion() == "att_rel_chr_catholic" then
				cm:apply_effect_bundle("mk_bundle_pope_favour_5", current_faction:name(), 0);
				FACTION_POPE_FAVOUR[current_faction:name()] = 5;

				if current_faction:is_human() and (not cm:is_multiplayer() or MKMP_SP_Parity_Enabled("pope_favour_decisions")) then
					Add_Decision("ask_pope_for_money", current_faction:name(), false, false);
				end
			end

			Papal_Show_Message(
				current_faction:name(),
				"message_event_text_text_mk_event_pope_papacy_restored_title",
				"message_event_text_text_mk_event_pope_papacy_restored_primary",
				"message_event_text_text_mk_event_pope_papacy_restored_secondary",
				true,
				701
			);
		end
	end
end

function Deactivate_Papal_Favour_System()
	PAPAL_FAVOUR_SYSTEM_ACTIVE = false;
	papal_active_listeners = false;
	papal_battle = nil;
	cm:remove_listener("PendingBattle_Pope_Favour");
	cm:remove_listener("FactionLeaderDeclaresWar_Pope");
	cm:remove_listener("GarrisonAttackedEvent_Pope");
	cm:remove_listener("CharacterPerformsOccupationDecisionLoot_Pope");
	cm:remove_listener("CharacterPerformsOccupationDecisionSack_Pope");
	cm:remove_listener("CharacterPerformsOccupationDecisionOccupy_Pope");
	cm:remove_listener("CharacterCompletedBattle_Pope_Favour");
	cm:remove_listener("CharacterParticipatedAsSecondaryGeneralInBattle_Pope_Favour");
	cm:remove_listener("CharacterPostBattleEnslave_Pope");
	cm:remove_listener("CharacterPostBattleRelease_Pope");
	cm:remove_listener("CharacterPostBattleSlaughter_Pope");
	cm:remove_listener("CharacterBecomesFactionLeader_Pope_Favour");
	cm:remove_listener("DilemmaChoiceMadeEvent_Pope");
	cm:remove_listener("FactionReligionConverted_Pope");
	cm:remove_listener("MissionFailed_Check_Mission");
	cm:remove_listener("MissionSucceeded_Check_Mission");

	local faction_list = cm:model():world():faction_list();

	for i = 0, faction_list:num_items() - 1 do
		local current_faction = faction_list:item_at(i);

		AT_WAR_WITH_POPE[current_faction:name()] = false;

		if FACTION_EXCOMMUNICATED[current_faction:name()] == true then
			Remove_Excommunication_Manual(current_faction:name());
		end

		if current_faction:is_human() and (not cm:is_multiplayer() or MKMP_SP_Parity_Enabled("pope_favour_decisions")) then
			Remove_Decision("ask_pope_for_money", current_faction:name());
		end

		for j = 0, 10 do
			cm:remove_effect_bundle("mk_bundle_pope_favour_"..j, current_faction:name());
		end
	end
end

function Force_Stop_Papal_Favour_System()
	Deactivate_Papal_Favour_System();
	PAPAL_FAVOUR_SYSTEM_FORCE_STOPPED = true;
end

function FactionTurnStart_Check_Catholic_Nations(context)
	local actor = Papal_Read(context, "faction");
	if not Papal_Valid_Interface(actor) then return; end
	local faction_name = context:faction():name();
	local faction_religion = context:faction():state_religion();
	local turn_number = cm:model():turn_number();

	if faction_religion == "att_rel_chr_catholic" and faction_name ~= PAPAL_STATES_KEY then
		local pope_faction = Papal_Faction(PAPAL_STATES_KEY);
		if not pope_faction then return; end
		local war_with_pope = context:faction():at_war_with(pope_faction);

		AT_WAR_WITH_POPE[faction_name] = war_with_pope;

		if PAPAL_FAVOUR_SYSTEM_ACTIVE then
			-- Todo: See if this block is even necessary, dunno why it would be.
			if context:faction():is_human() and cm:model():turn_number() > 1 then
				-- Human faction changed religion, giving them an effect bundle!
				cm:apply_effect_bundle("mk_bundle_pope_favour_5", faction_name, 0);
			end

			if FACTION_EXCOMMUNICATED[faction_name] ~= true then
				if war_with_pope then
					Force_Excommunication(faction_name);
				else
					-- Possible stances from strategic_stance_between_factions are -3 to 3, corresponding to diplomatic stances (i.e. 2 being Very Friendly, -2 being Hostile).
					local stance = cm:model():campaign_ai():strategic_stance_between_factions(PAPAL_STATES_KEY, faction_name);

					if stance <= -3 then
						local chance = cm:random_number(3);

						if chance == 1 then
							Subtract_Pope_Favour(faction_name, 1, "relations_decay");
						end
					elseif stance == -2 then
						local chance = cm:random_number(6);

						if chance == 1 then
							Subtract_Pope_Favour(faction_name, 1, "relations_decay");
						end
					elseif stance == 2 then
						local chance = cm:random_number(6);

						if chance == 1 then
							Add_Pope_Favour(faction_name, 1, "relations_increase");
						end
					elseif stance >= 3 then
						local chance = cm:random_number(3);
						
						if chance == 1 then
							Add_Pope_Favour(faction_name, 1, "relations_increase");
						end
					end
				end
			end

			Update_Pope_Favour(context:faction());
		end
	elseif faction_religion ~= "att_rel_chr_catholic" and FACTION_POPE_FAVOUR[faction_name]  then
		-- Faction is no longer Catholic!
		FACTION_POPE_FAVOUR[faction_name] = nil;

		for i = 0, 10 do
			cm:remove_effect_bundle("mk_bundle_pope_favour_"..i, faction_name);
		end

		Remove_Excommunication_Manual(faction_name);

		if context:faction():is_human() and (not cm:is_multiplayer() or MKMP_SP_Parity_Enabled("pope_favour_decisions")) then
			Remove_Decision("ask_pope_for_money", faction_name);
		end
	end

	if faction_name == PAPAL_STATES_KEY and PAPAL_FAVOUR_SYSTEM_ACTIVE == false then
		-- Papal States liberated!
		Reactivate_Papal_Favour_System();
	end
end

function GarrisonAttackedEvent_Pope(context)
	FAVOUR_LAST_ATTACKED_GARRISON = "";
	local garrison = Papal_Read(context, "garrison_residence");
	if not Papal_Valid_Interface(garrison) then return; end
	local faction = Papal_Read(garrison, "faction");
	if Papal_Valid_Interface(faction) then
		FAVOUR_LAST_ATTACKED_GARRISON = faction:name();
	end
end

function Check_If_Catholic_Attacked(context, type)
	local character, faction = Papal_Character(context);
	if not character or not PAPAL_FAVOUR_SYSTEM_ACTIVE then return; end
	local region = FindClosestRegion(character:logical_position_x(), character:logical_position_y(), "none"); -- Taking the character's region may be inaccurate if they're at sea or across a strait.

	if Papal_Valid_Interface(region) then
		local region_name = region:name();
		local faction_name = context:character():faction():name();

		if region_name ~= "att_reg_italia_roma" and faction_name ~= PAPAL_STATES_KEY then
			if type == "LOOTED" or type == "SACKED" then
				if SackExploitCheck_Pope(region_name) == true then
					if context:character():faction():is_human() and context:character():faction():state_religion() == "att_rel_chr_catholic" and FACTION_EXCOMMUNICATED[faction_name] ~= true then
						local defender_cqi, defender_force_cqi, defender_name = cm:pending_battle_cache_get_defender(1);

						if defender_name ~= "rebels" then
							if FAVOUR_LAST_ATTACKED_GARRISON ~= "" and (FAVOUR_LAST_ATTACKED_GARRISON ~= defender_name) then
								defender_name = FAVOUR_LAST_ATTACKED_GARRISON;
							end

							local sacked_faction = Papal_Faction(defender_name);

							if sacked_faction then
								local sacked_rel = sacked_faction:state_religion();

								if sacked_rel == "att_rel_chr_catholic" then
									-- Sacked/Looted another Catholic faction!
									Subtract_Pope_Favour(faction_name, 1, "sacked_settlement");
								end
							end
						end
					end
				end
			end
		else
			local owner = Papal_Read(region, "owning_faction");
			if Papal_Valid_Interface(owner) and owner:name() == PAPAL_STATES_KEY then
				if context:character():faction():is_human() then
					if context:character():faction():state_religion() == "att_rel_chr_catholic" then
						cm:trigger_dilemma(faction_name, "mk_dilemma_rome_attacked_christian");
						Force_Excommunication(faction_name);
					else
						-- Resolve the complete target collection before starting the
						-- transition. The old branch referenced an undefined local.
						local faction_list = cm:model():world():faction_list();
						Papal_Show_Message(
							faction_name,
							"message_event_text_text_mk_event_pope_rome_attacked_nonchrist_title",
							"message_event_text_text_mk_event_pope_rome_attacked_nonchrist_primary",
							"message_event_text_text_mk_event_pope_rome_attacked_nonchrist_secondary",
							true,
							708
						);

						for i = 0, faction_list:num_items() - 1 do
							local current_faction = faction_list:item_at(i);

							if Papal_Valid_Interface(current_faction) and current_faction:state_religion() == "att_rel_chr_catholic" then
								cm:apply_effect_bundle("mk_bundle_christian_dejection", current_faction:name(), 0);
							end
						end

						Deactivate_Papal_Favour_System();
					end
				end
			end
		end
	end
end

function Check_Excommunication_Pope_War(context)
	local character, faction = Papal_Character(context);
	if not character then return; end
	if AT_WAR_WITH_POPE[context:character():faction():name()] == false then
		-- They weren't at war with the Pope...
		local pope_faction = Papal_Faction(PAPAL_STATES_KEY);
		if not pope_faction then return; end
		local now_at_war = context:character():faction():at_war_with(pope_faction);
			
		if now_at_war == true then
			-- They are now at war with the Pope!
			AT_WAR_WITH_POPE[context:character():faction():name()] = true;
				
			if context:character():faction():state_religion() == "att_rel_chr_catholic" then
				Force_Excommunication(context:character():faction():name());
			else
				Papal_Show_Message(
					context:character():faction():name(),
					"message_event_text_text_mk_event_pope_enemy_of_christendom_title",
					"message_event_text_text_mk_event_pope_enemy_of_christendom_primary",
					"message_event_text_text_mk_event_pope_enemy_of_christendom_secondary",
					true,
					709
				);

				cm:apply_effect_bundle("mk_bundle_christendoms_outcry", context:character():faction():name(), 0);
			end
		end
	end
end

function CharacterCompletedBattle_Pope_Favour(context)
	local character, faction = Papal_Observe_Battle_Result(context);
	if not character then return; end
	Papal_Log("observed", {actor = faction:name(), phase = "character_completed_battle",
		attacker_result = papal_battle.attacker_result, defender_result = papal_battle.defender_result});
end

function CharacterPostBattle_Favour(context, decision_kind)
	if decision_kind ~= "RELEASE" and decision_kind ~= "ENSLAVE" and decision_kind ~= "SLAUGHTER" then return false; end
	-- Result observation here also handles a decision callback arriving before
	-- CharacterCompletedBattle; it never opens a missing PendingBattle lifecycle.
	local character, faction = Papal_Observe_Battle_Result(context);
	if not character then return false; end
	local actor = faction:name();
	if faction:state_religion() ~= "att_rel_chr_catholic" or not faction:is_human()
		or not papal_battle.attacker.catholic or not papal_battle.defender.catholic then return false; end
	local previous = papal_battle.decisions[actor];
	if previous then
		Papal_Log(previous.kind == decision_kind and "duplicate" or "blocked",
			{actor = actor, kind = decision_kind, reason = "battle_faction_decision_already_claimed"});
		return false;
	end
	-- All callbacks for generals of one faction share one decision claim. Two
	-- human factions have independent claims; a one-second global latch cannot
	-- suppress the other player's action or reopen a previous decision.
	local decision = {kind = decision_kind, status = "claimed"};
	papal_battle.decisions[actor] = decision;
	Papal_Log("claimed", {actor = actor, kind = decision_kind, phase = "postbattle_decision"});
	local ok = pcall(function()
		if FACTION_EXCOMMUNICATED[actor] ~= true then
			if decision_kind == "RELEASE" then
				Add_Pope_Favour(actor, 1, "released_captives");
			elseif decision_kind == "SLAUGHTER" and actor ~= PAPAL_STATES_KEY and actor ~= POPE_CONTROLLING_FACTION then
				Subtract_Pope_Favour(actor, 1, "slaughtered_captives");
			end
		end
	end);
	-- A returned command is requested, not proof of successful engine delivery.
	-- On error the claim survives save/load; an uncertain partial effect is never
	-- retried automatically, including through a different decision callback.
	decision.status = ok and "requested" or "unknown";
	Papal_Log(decision.status, {actor = actor, kind = decision_kind, phase = "postbattle_decision"});
	return ok;
end

function DilemmaChoiceMadeEvent_Pope(context)
	if context:dilemma() == "mk_dilemma_rome_attacked_christian" then
		local papacy = cm:model():world():faction_by_key(PAPAL_STATES_KEY);

		if context:choice() == 0 then
			-- Choice made to keep a puppet pope!
			Remove_Excommunication_Manual(context:faction():name());
			FACTION_POPE_FAVOUR[context:faction():name()] = 10;
			Update_Pope_Favour(context:faction());
		elseif context:choice() == 1 then
			-- Choice made to depose the pope!
			POPE_DEPOSED = true;
			--[[if papacy:is_null_interface() == false then
				cm:grant_faction_handover(context:faction():name(), PAPAL_STATES_KEY, turn_number-1, turn_number-1, context);
			end]]--
			Deactivate_Papal_Favour_System();
		end
	end
end

function FactionReligionConverted_Pope(context)
	local faction = context:faction();
	local faction_name = faction:name();
	local state_religion = faction:state_religion();

	if PAPAL_FAVOUR_SYSTEM_ACTIVE == true then
		if state_religion == "att_rel_chr_catholic" then
			if faction_name == CURRENT_CRUSADE_TARGET_OWNER then
				End_Crusade("aborted");
			end

			Update_Pope_Favour(faction);
		elseif FACTION_POPE_FAVOUR[faction_name]  then
			FACTION_POPE_FAVOUR[faction_name] = nil;

			for i = 0, 10 do
				cm:remove_effect_bundle("mk_bundle_pope_favour_"..i, faction_name);
			end

			Remove_Excommunication_Manual(faction_name);

			if faction:is_human() then 
				if (not cm:is_multiplayer() or MKMP_SP_Parity_Enabled("pope_favour_decisions")) then
					Remove_Decision("ask_pope_for_money", faction_name);
				end

				if MISSION_TAKE_JERUSALEM_ACTIVE == true then
					MISSION_TAKE_JERUSALEM_ACTIVE = false;
					cm:remove_listener("CharacterEntersGarrison_Jerusalem");
					cm:cancel_custom_mission(faction_name, "mk_mission_crusades_take_jerusalem_dilemma");
					Make_Peace_Crusades(faction_name);
				end
			end

			if HasValue(CURRENT_CRUSADE_FACTIONS_JOINED, faction_name) then
				Remove_Faction_From_Crusade(faction_name);
			end
		end
	end
end

function MissionSucceeded_Check_Mission(context)
	local faction_name = context:faction():name();

	if faction_name ~= PAPAL_STATES_KEY then
		local mission_name = context:mission():mission_record_key();

		if mission_name == "att_religious_catholic_assassinate_character_1" then
			Add_Pope_Favour(faction_name, 1, "mission_succeed_generic");
		elseif mission_name == "att_religious_catholic_construct_bch_religion_catholic_legendary_1" then
			Add_Pope_Favour(faction_name, 1, "mission_succeed_generic");
		elseif mission_name == "att_religious_catholic_construct_bch_religion_catholic_major_1" then
			Add_Pope_Favour(faction_name, 1, "mission_succeed_generic");
		elseif mission_name == "att_religious_catholic_construct_bch_religion_catholic_minor_1" then
			Add_Pope_Favour(faction_name, 1, "mission_succeed_generic");
		elseif mission_name == "att_religious_catholic_construct_building_religious_1" then
			Add_Pope_Favour(faction_name, 1, "mission_succeed_generic");
		elseif mission_name == "att_religious_catholic_convert_region_1" then
			Add_Pope_Favour(faction_name, 1, "mission_succeed_generic");
		elseif mission_name == "att_religious_catholic_declare_war_1" then
			Add_Pope_Favour(faction_name, 1, "mission_succeed_generic");
		elseif mission_name == "att_religious_catholic_recruit_agent_1" then
			Add_Pope_Favour(faction_name, 1, "mission_succeed_generic");
		elseif mission_name == "mk_religious_catholic_intervention_end_war" then
			Add_Pope_Favour(faction_name, 1, "mission_succeed_peace");
		end

		if context:faction():state_religion() == "att_rel_chr_catholic" then
			Update_Pope_Favour(context:faction());	
		end
	end
end

function MissionFailed_Check_Mission(context)
	local faction_name = context:faction():name();

	if faction_name ~= PAPAL_STATES_KEY and faction_name ~= POPE_CONTROLLING_FACTION then
		local mission_name = context:mission():mission_record_key();

		if mission_name == "att_religious_catholic_construct_bch_religion_catholic_legendary_1" then
			Subtract_Pope_Favour(faction_name, 1, "mission_fail_generic");
		elseif mission_name == "att_religious_catholic_construct_bch_religion_catholic_major_1" then
			Subtract_Pope_Favour(faction_name, 1, "mission_fail_generic");
		elseif mission_name == "att_religious_catholic_construct_bch_religion_catholic_minor_1" then
			Subtract_Pope_Favour(faction_name, 1, "mission_fail_generic");
		elseif mission_name == "att_religious_catholic_construct_building_religious_1" then
			Subtract_Pope_Favour(faction_name, 1, "mission_fail_generic");
		elseif mission_name == "att_religious_catholic_convert_region_1" then
			Subtract_Pope_Favour(faction_name, 1, "mission_fail_generic");
		elseif mission_name == "att_religious_catholic_recruit_agent_1" then
			Subtract_Pope_Favour(faction_name, 1, "mission_fail_generic");
		elseif mission_name == "mk_religious_catholic_intervention_end_war" then
			Subtract_Pope_Favour(faction_name, 3, "mission_fail_peace");
		end
		
		if context:faction():state_religion() == "att_rel_chr_catholic" then
			Update_Pope_Favour(context:faction());	
		end
	end
end

function Update_Pope_Favour(faction)
	if not Papal_Valid_Interface(faction) then return false; end
	local pope_favour = 5;
	local bundle_applied = false;
	
	if FACTION_POPE_FAVOUR[faction:name()]  then
		pope_favour = FACTION_POPE_FAVOUR[faction:name()];
	else
		FACTION_POPE_FAVOUR[faction:name()] = 5;
	end

	-- Remove every Pope favour effect bundle from 0 to 10.
	for i = 0, 10 do
		cm:remove_effect_bundle("mk_bundle_pope_favour_"..i, faction:name());
	end
	
	-- Can only handle whole numbers
	pope_favour = math.floor(pope_favour);
	
	if pope_favour > 0 then
		cm:apply_effect_bundle("mk_bundle_pope_favour_"..pope_favour, faction:name(), 0);
		bundle_applied = true;
	else
		cm:apply_effect_bundle("mk_bundle_pope_favour_0", faction:name(), 0);
	end

	Check_Excommunication_Low_Favour(faction);

	if faction:is_human() and (not cm:is_multiplayer() or MKMP_SP_Parity_Enabled("pope_favour_decisions")) then
		if pope_favour > 7 then
			Enable_Decision("ask_pope_for_money", faction:name());
		else
			Disable_Decision("ask_pope_for_money", faction:name());
		end
	end
end

function Check_Excommunication_Low_Favour(faction)
	local faction_name = faction:name();

	if FACTION_POPE_FAVOUR[faction_name] == 0 and FACTION_EXCOMMUNICATED[faction_name] ~= true then
		FACTION_EXCOMMUNICATED[faction_name] = true;
		cm:apply_effect_bundle("mk_bundle_pope_excommunication", faction_name, 0);

		if faction:is_human() and (not cm:is_multiplayer() or MKMP_SP_Parity_Enabled("pope_favour_decisions")) then
			Remove_Decision("ask_pope_for_money", faction_name);
		end

		if IRONMAN_ENABLED then
			if faction:is_human() and (not cm:is_multiplayer() or MKMP_SP_Parity_Enabled("pope_favour_decisions")) then
				Unlock_Achievement("achievement_its_only_human_to_sin");
			end
		end

		Papal_Show_Message(
			faction_name,
			"message_event_text_text_mk_event_pope_excommunication_title",
			"message_event_text_text_mk_event_pope_excommunication_primary",
			"message_event_text_text_mk_event_pope_excommunication_secondary",
			true, 
			707
		);

		local faction_list = cm:model():world():faction_list();

		for i = 0, faction_list:num_items() - 1 do
			local current_faction = faction_list:item_at(i);
			local current_faction_name = current_faction:name();

			if current_faction_name ~= faction_name and current_faction:is_human() then
				local faction_string = "factions_screen_name_"..faction_name;

				if FACTIONS_DFN_LEVEL[faction_name] and FACTIONS_DFN_LEVEL[faction_name] > 1 then
					faction_string = "campaign_localised_strings_string_"..faction_name.."_lvl"..tostring(FACTIONS_DFN_LEVEL[faction_name]);
				end

				Papal_Show_Message(
					current_faction_name,
					"message_event_text_text_mk_event_pope_excommunication_other_title",
					faction_string,
					"message_event_text_text_mk_event_pope_excommunication_other_secondary",
					true,
					707
				);
			end
		end

		if NICKNAMES then
			Increase_Character_Nickname_Stat(faction:faction_leader():cqi(), "times_excommunicated", 1);
		end
	end
end

function Force_Excommunication(faction_name, silent)
	if FACTION_EXCOMMUNICATED[faction_name] ~= true then
		local faction = Papal_Faction(faction_name);
		if not faction then return false; end

		FACTION_POPE_FAVOUR[faction_name] = 0;
		FACTION_EXCOMMUNICATED[faction_name] = true;

		for i = 0, 10 do
			cm:remove_effect_bundle("mk_bundle_pope_favour_"..i, faction_name);
		end

		cm:apply_effect_bundle("mk_bundle_pope_favour_0", faction_name, 0);
		cm:apply_effect_bundle("mk_bundle_pope_excommunication", faction_name, 0);

		if faction:is_human() and (not cm:is_multiplayer() or MKMP_SP_Parity_Enabled("pope_favour_decisions")) then
			Remove_Decision("ask_pope_for_money", faction_name);
		end

		if not silent then
			if IRONMAN_ENABLED then
				if faction:is_human() and (not cm:is_multiplayer() or MKMP_SP_Parity_Enabled("pope_favour_decisions")) then
					Unlock_Achievement("achievement_its_only_human_to_sin");
				end
			end

			Papal_Show_Message(
				faction_name,
				"message_event_text_text_mk_event_pope_excommunication_title",
				"message_event_text_text_mk_event_pope_excommunication_primary",
				"message_event_text_text_mk_event_pope_excommunication_secondary",
				true, 
				707
			);

			Increase_Character_Nickname_Stat(faction:faction_leader():cqi(), "times_excommunicated", 1);

			local faction_list = cm:model():world():faction_list();

			for i = 0, faction_list:num_items() - 1 do
				local current_faction = faction_list:item_at(i);
				local current_faction_name = current_faction:name();

				if current_faction_name ~= faction_name and current_faction:is_human() then
					local faction_string = "factions_screen_name_"..faction_name;

					if FACTIONS_DFN_LEVEL[faction_name] and FACTIONS_DFN_LEVEL[faction_name] > 1 then
						faction_string = "campaign_localised_strings_string_"..faction_name.."_lvl"..tostring(FACTIONS_DFN_LEVEL[faction_name]);
					end

					Papal_Show_Message(
						current_faction_name,
						"message_event_text_text_mk_event_pope_excommunication_other_title",
						faction_string,
						"message_event_text_text_mk_event_pope_excommunication_other_secondary",
						true,
						707
					);
				end
			end
		end
	end
end

local function Papal_Clear_Excommunication(faction)
	if not Papal_Valid_Interface(faction) then return false; end
	local faction_name = faction:name();
	if FACTION_EXCOMMUNICATED[faction_name] ~= true then return false; end

	-- Claim the transition before issuing model commands. Repeated leader or
	-- dilemma callbacks cannot reset favour or repeat the notification.
	FACTION_EXCOMMUNICATED[faction_name] = false;
	cm:remove_effect_bundle("mk_bundle_pope_excommunication", faction_name);
	if faction:state_religion() == "att_rel_chr_catholic" and PAPAL_FAVOUR_SYSTEM_ACTIVE then
		FACTION_POPE_FAVOUR[faction_name] = 2;
		if faction:is_human() and (not cm:is_multiplayer() or MKMP_SP_Parity_Enabled("pope_favour_decisions")) then
			Add_Decision("ask_pope_for_money", faction_name, false, false);
		end
		Update_Pope_Favour(faction);
		Papal_Show_Message(
			faction_name,
			"message_event_text_text_mk_event_pope_excommunication_lifted_title",
			"message_event_text_text_mk_event_pope_excommunication_lifted_primary",
			"message_event_text_text_mk_event_pope_excommunication_lifted_secondary",
			true, 701
		);
		local faction_list = cm:model():world():faction_list();
		local faction_label = Papal_Faction_Label(faction_name);
		for i = 0, faction_list:num_items() - 1 do
			local current_faction = faction_list:item_at(i);
			if Papal_Valid_Interface(current_faction) and current_faction:name() ~= faction_name and current_faction:is_human() then
				Papal_Show_Message(
					current_faction:name(),
					"message_event_text_text_mk_event_pope_excommunication_lifted_other_title",
					faction_label,
					"message_event_text_text_mk_event_pope_excommunication_lifted_other_secondary",
					true, 707
				);
			end
		end
	end
	Papal_Log("requested", {actor = faction_name, phase = "excommunication_lifted"});
	return true;
end

function Remove_Excommunication(context)
	-- CharacterBecomesFactionLeader supplies a character; context:faction is not
	-- a supported substitute for this event's owner.
	local character, faction = Papal_Character(context);
	if not character then return false; end
	return Papal_Clear_Excommunication(faction);
end

function Remove_Excommunication_Manual(faction_name)
	return Papal_Clear_Excommunication(Papal_Faction(faction_name));
end

function MKMP_Papal_Validate_Loan(faction_name)
	local faction = Papal_Faction(faction_name);
	if not faction or faction_name == PAPAL_STATES_KEY or not faction:is_human() then return false, "invalid_actor"; end
	if not PAPAL_FAVOUR_SYSTEM_ACTIVE or PAPAL_FAVOUR_SYSTEM_FORCE_STOPPED or not Papal_Faction(PAPAL_STATES_KEY) then
		return false, "papacy_inactive";
	end
	if not FactionIsAlive(faction_name) then return false, "actor_dead"; end
	if faction:state_religion() ~= "att_rel_chr_catholic" or FACTION_EXCOMMUNICATED[faction_name] == true then
		return false, "actor_ineligible";
	end
	local favour = FACTION_POPE_FAVOUR[faction_name];
	if not Papal_Integer(favour) or favour < 8 or favour > 10 then return false, "insufficient_favour"; end
	return true, nil, ({[8] = 5000, [9] = 7500, [10] = 10000})[favour];
end

function Decision_Pope_Money(faction_name)
	-- The action registry owns accepted intent IDs and no-retry claims. This is
	-- the mutation executor, called only after that execution contract permits it.
	local valid, reason, amount = MKMP_Papal_Validate_Loan(faction_name);
	if not valid then return false, reason; end
	Papal_Log("validated", {actor = faction_name, phase = "loan_execute", amount = amount,
		action_identity = "caller_owned"});
	cm:treasury_mod(faction_name, amount);
	Subtract_Pope_Favour(faction_name, 3, "borrowed_money");
	Papal_Log("requested", {actor = faction_name, phase = "loan_execute", amount = amount,
		action_identity = "caller_owned"});
	return true;
end

function Add_Pope_Favour(faction_name, amount, reason)
	local faction = Papal_Faction(faction_name);
	if not faction or not Papal_Integer(amount) then return false; end

	if FACTION_POPE_FAVOUR[faction_name] == nil then
		FACTION_POPE_FAVOUR[faction_name] = 5 + amount;
		FACTION_POPE_FAVOUR[faction_name] = math.max(FACTION_POPE_FAVOUR[faction_name], MIN_POPE_FAVOUR);
		FACTION_POPE_FAVOUR[faction_name] = math.min(FACTION_POPE_FAVOUR[faction_name], MAX_POPE_FAVOUR);
	else
		FACTION_POPE_FAVOUR[faction_name] = FACTION_POPE_FAVOUR[faction_name] + amount;
		FACTION_POPE_FAVOUR[faction_name] = math.max(FACTION_POPE_FAVOUR[faction_name], MIN_POPE_FAVOUR);
		FACTION_POPE_FAVOUR[faction_name] = math.min(FACTION_POPE_FAVOUR[faction_name], MAX_POPE_FAVOUR);
	end

	Update_Pope_Favour(faction);
	Papal_Show_Message(
		faction_name,
		"message_event_text_text_mk_event_pope_favour_increase_title",
		"message_event_text_text_mk_event_pope_favour_increase_primary_"..reason,
		"message_event_text_text_mk_event_pope_favour_increase_secondary_"..reason,
		true, 
		701
	);

	return true;
end

function Subtract_Pope_Favour(faction_name, amount, reason)
	local faction = Papal_Faction(faction_name);
	if not faction or not Papal_Integer(amount) then return false; end

	if FACTION_POPE_FAVOUR[faction_name] == nil then
		FACTION_POPE_FAVOUR[faction_name] = 5 - amount;
		FACTION_POPE_FAVOUR[faction_name] = math.max(FACTION_POPE_FAVOUR[faction_name], MIN_POPE_FAVOUR);
		FACTION_POPE_FAVOUR[faction_name] = math.min(FACTION_POPE_FAVOUR[faction_name], MAX_POPE_FAVOUR);
	else
		FACTION_POPE_FAVOUR[faction_name] = FACTION_POPE_FAVOUR[faction_name] - amount;
		FACTION_POPE_FAVOUR[faction_name] = math.max(FACTION_POPE_FAVOUR[faction_name], MIN_POPE_FAVOUR);
		FACTION_POPE_FAVOUR[faction_name] = math.min(FACTION_POPE_FAVOUR[faction_name], MAX_POPE_FAVOUR);
	end

	Update_Pope_Favour(faction);
	Papal_Show_Message(
		faction_name,
		"message_event_text_text_mk_event_pope_favour_decrease_title",
		"message_event_text_text_mk_event_pope_favour_decrease_primary_"..reason,
		"message_event_text_text_mk_event_pope_favour_decrease_secondary_"..reason,
		true, 
		707
	);

	return true;
end

function TimeTrigger_Pope(context)
	-- Compatibility for a timer already queued in a pre-N0 save. It has no
	-- authority to reopen a postbattle decision and schedules no replacement.
	return false;
end

------------------------------------------------
---------------- Saving/Loading ----------------
------------------------------------------------
cm:register_saving_game_callback(
	function(context)
		SaveKeyPairTable(context, FACTION_POPE_FAVOUR, "FACTION_POPE_FAVOUR");
		SaveBooleanPairTable(context, FACTION_EXCOMMUNICATED, "FACTION_EXCOMMUNICATED");
		cm:save_value("PAPAL_FAVOUR_SYSTEM_ACTIVE", PAPAL_FAVOUR_SYSTEM_ACTIVE, context);
		cm:save_value("PAPAL_FAVOUR_SYSTEM_FORCE_STOPPED", PAPAL_FAVOUR_SYSTEM_FORCE_STOPPED, context);
		cm:save_value("FAVOUR_LAST_ATTACKED_GARRISON", FAVOUR_LAST_ATTACKED_GARRISON, context);
		cm:save_value("POPE_DEPOSED", POPE_DEPOSED, context);
		Papal_Save_Battle_State(context);
	end
);

cm:register_loading_game_callback(
	function(context)
		local favour = LoadKeyPairTableNumbers(context, "FACTION_POPE_FAVOUR");
		local excommunicated = LoadBooleanPairTable(context, "FACTION_EXCOMMUNICATED");
		local active = cm:load_value("PAPAL_FAVOUR_SYSTEM_ACTIVE", true, context);
		local force_stopped = cm:load_value("PAPAL_FAVOUR_SYSTEM_FORCE_STOPPED", false, context);
		local garrison = cm:load_value("FAVOUR_LAST_ATTACKED_GARRISON", "", context);
		local deposed = cm:load_value("POPE_DEPOSED", false, context);
		if type(active) ~= "boolean" or type(force_stopped) ~= "boolean" or type(deposed) ~= "boolean"
			or (garrison ~= "" and not Papal_Key(garrison)) then error("MK1212 invalid Papal save state"); end
		local keys = MK1212_SaveSortedKeys(favour);
		if #keys > 4096 then error("MK1212 Papal favour faction budget exceeded"); end
		for i = 1, #keys do
			if not Papal_Key(keys[i]) or not Papal_Integer(favour[keys[i]]) or favour[keys[i]] > MAX_POPE_FAVOUR then
				error("MK1212 invalid Papal favour save value");
			end
		end
		-- Validate the whole legacy snapshot before replacing either authoritative
		-- map. An unknown owned battle frame disables only postbattle processing.
		Papal_Load_Battle_State(context);
		FACTION_POPE_FAVOUR, FACTION_EXCOMMUNICATED = favour, excommunicated;
		PAPAL_FAVOUR_SYSTEM_ACTIVE, PAPAL_FAVOUR_SYSTEM_FORCE_STOPPED = active, force_stopped;
		FAVOUR_LAST_ATTACKED_GARRISON, POPE_DEPOSED = garrison, deposed;
	end
);
