-------------------------------------------------------------------------------------------------------------------------
-------------------------------------------------------------------------------------------------------------------------
--
-- 	MEDIEVAL KINGDOMS 1212 - MECHANICS: WAR WEARINESS
-- 	Modified By: DETrooper
-- 	Original Script by Creative Assembly
--
-------------------------------------------------------------------------------------------------------------------------
-------------------------------------------------------------------------------------------------------------------------

PLAYER_WAR_WEARINESS = {}; -- This is the level of war weariness the players faction is suffering
PLAYER_WAR_WEARINESS_EVENTS = {}; -- Keep track of the events shown to each player
PLAYER_WAR_WEARINESS_TURNS_AT_WAR = {}; -- The amount of turns each faction has been at war.

-- One completed FactionTurnStart per faction/round, including across save/load.
-- The owned v1 payload is a canonical faction-key/integer map. Old saves have an
-- empty ledger; loading never replays a turn. Entries are bounded by campaign
-- factions (hard ceiling 4096). Unknown/corrupt metadata is retained verbatim
-- and stops only passive turn processing rather than guessing completed work.
local ww_initialized = false;
local ww_last_turn = {};
local ww_turn_entries = 0;
local ww_turn_schema = 1;
local ww_turn_raw = "";
local ww_turn_state_valid = true;

local function WW_Log(event, fields)
	if MKMP_Debug_Log then
		pcall(MKMP_Debug_Log, event, fields);
	end
end

-- A bounded copy includes the private completed-phase ledger. Diagnostics must
-- not hand another subsystem a mutable reference into campaign authority.
function MKMP_War_Weariness_Get_State()
	local function copy(source)
		if type(source) ~= "table" then error("war weariness snapshot unavailable"); end
		local result, count = {}, 0;
		for key, value in pairs(source) do
			count = count + 1;
			if count > 4096 or type(key) ~= "string"
				or (type(value) ~= "number" and type(value) ~= "string" and type(value) ~= "boolean") then
				error("war weariness snapshot invalid or over budget");
			end
			result[key] = value;
		end
		return result;
	end
	return {
		schema = 1, complete = ww_turn_state_valid, turn_schema = ww_turn_schema,
		values = copy(PLAYER_WAR_WEARINESS), events = copy(PLAYER_WAR_WEARINESS_EVENTS),
		turns_at_war = copy(PLAYER_WAR_WEARINESS_TURNS_AT_WAR),
		completed_phase = copy(ww_last_turn), phase_semantics = "claimed_before_model_call",
		passive_increment = TURN_AT_WAR
	};
end

local function WW_Load_Turn_State(context)
	ww_last_turn = {};
	ww_turn_entries = 0;
	ww_turn_schema = cm:load_value("MKMP_WW_TURN_SCHEMA", 1, context);
	ww_turn_raw = cm:load_value("MKMP_WW_LAST_TURN", "", context);
	ww_turn_state_valid = ww_turn_schema == 1 and type(ww_turn_raw) == "string"
		and #ww_turn_raw <= 262144;
	local cursor = 1;
	local entries = 0;
	local current_turn = cm:model():turn_number();
	while ww_turn_state_valid and cursor <= #ww_turn_raw do
		local first, last, faction_name, encoded_turn = string.find(ww_turn_raw, "([^,;]+),([^,;]+),;", cursor);
		local turn = tonumber(encoded_turn);
		if first ~= cursor or not turn or turn ~= turn or turn < 0
			or turn > current_turn or turn ~= math.floor(turn)
			or ww_last_turn[faction_name] ~= nil or entries >= 4096 then
			ww_turn_state_valid = false;
			break;
		end
		local faction = cm:model():world():faction_by_key(faction_name);
		if not faction or faction:is_null_interface() then
			ww_turn_state_valid = false;
			break;
		end
		ww_last_turn[faction_name] = turn;
		entries = entries + 1;
		cursor = last + 1;
	end
	if not ww_turn_state_valid then
		ww_last_turn = {};
		WW_Log("contract_error", {contract = "war_weariness_turn_state", schema = ww_turn_schema});
	else
		ww_turn_entries = entries;
	end
end

local function WW_Save_Turn_State(context)
	if not ww_turn_state_valid then
		cm:save_value("MKMP_WW_LAST_TURN", ww_turn_raw, context);
		cm:save_value("MKMP_WW_TURN_SCHEMA", ww_turn_schema, context);
		return;
	end
	local keys = MK1212_SaveSortedKeys(ww_last_turn);
	local output = {};
	if #keys > 4096 then error("MK1212 war weariness turn ledger exceeds faction budget"); end
	for i = 1, #keys do
		local key, turn = keys[i], ww_last_turn[keys[i]];
		if type(key) ~= "string" or key == "" or string.find(key, "[,;]")
			or type(turn) ~= "number" or turn ~= turn or turn < 0
			or turn == math.huge or turn ~= math.floor(turn) then
			error("MK1212 war weariness turn ledger is invalid");
		end
		output[#output + 1] = key..","..string.format("%.0f", turn)..",;";
	end
	local payload = table.concat(output);
	if #payload > 262144 then error("MK1212 war weariness turn ledger exceeds byte budget"); end
	-- Validate the complete owned v1 payload before committing either field.
	cm:save_value("MKMP_WW_LAST_TURN", payload, context);
	cm:save_value("MKMP_WW_TURN_SCHEMA", 1, context);
end

TURN_AT_PEACE = -3; -- This is the amount that a faction will always recover by every turn if at peace
TURN_AT_WAR = 1; -- This is the amount war weariness will increase if at war (used to be per faction).
TURN_AT_WAR_DELAY = 4; -- Amount of turns that should pass before the TURN_AT_WAR penalty begins to apply.

MAX_WAR_WEARINESS = 100; -- This is the maximum amount that the war weariness value can increase to, it can be set higher than the max war weariness level to allow a slower recovery at the top end of the scale
MIN_WAR_WEARINESS = -5; -- This is the minimum amount that the war weariness value can decrease to, it can be set lower than zero to allow the player to essentially 'bank' long periods of peace

PEACE_MADE = -3; -- The amount war weariness decreases by if the faction makes peace with someone
TROOPS_AT_HOME = -1; -- This is the maximum amount war weariness will decrease by if the player has kept their troops at home.

-- Difficulty modifiers for passive increase
WW_EASY_MOD = 0.5;
WW_NORMAL_MOD = 1.0;
WW_HARD_MOD = 1.5;
WW_VERY_HARD_MOD = 2.0;
WW_LEGENDARY_MOD = 2.0;

-- These are the values that war weariness will change by given that the player achieves that result in a battle
battle_result_values = {
	["heroic_victory"] = -10,
	["decisive_victory"] = -5,
	["close_victory"] = -3,
	["pyrrhic_victory"] = -1,
	["valiant_defeat"] = 4,
	["close_defeat"] = 6,
	["decisive_defeat"] = 8,
	["crushing_defeat"] = 10
};

function Add_War_Weariness_Listeners()
	if ww_initialized then
		return;
	end
	-- Own initialization before callbacks can re-enter it: no compounded
	-- difficulty multiplier, duplicate listeners, or resetting a new campaign.
	ww_initialized = true;
	if MKMP_Debug_Register_State_Provider then
		pcall(MKMP_Debug_Register_State_Provider, "war_weariness", function()
			if ww_turn_state_valid then return MKMP_War_Weariness_Get_State(), "complete"; end
			return MKMP_War_Weariness_Get_State(), "incomplete", "turn_ledger_invalid";
		end);
	end
	cm:add_listener(
		"FactionTurnStart_WW",
		"FactionTurnStart",
		true,
		function(context) FactionTurnStart_WW(context) end,
		true
	);
	cm:add_listener(
		"BattleCompleted_WW",
		"BattleCompleted",
		true,
		function(context) BattleCompleted_WW(context) end,
		true
	);
	cm:add_listener(
		"FactionLeaderSignsPeaceTreaty_WW",
		"FactionLeaderSignsPeaceTreaty",
		true,
		function(context) FactionLeaderSignsPeaceTreaty_WW(context) end,
		true
	);
	
	-- Attila documents difficulty_level() as the LOCAL faction's difficulty.
	-- MP passive weariness therefore uses the shared content's normal baseline;
	-- SP keeps its selected difficulty. Neither peer's UI setting is authority.
	local difficulty = MK1212_Campaign_Difficulty();

	if difficulty == 1 then -- Easy
		TURN_AT_WAR = TURN_AT_WAR * WW_EASY_MOD;
	elseif difficulty == 0 then -- Normal
		TURN_AT_WAR = TURN_AT_WAR * WW_NORMAL_MOD;
	elseif difficulty == -1 then -- Hard
		TURN_AT_WAR = TURN_AT_WAR * WW_HARD_MOD;
	elseif difficulty == -2 then -- Very Hard
		TURN_AT_WAR = TURN_AT_WAR * WW_VERY_HARD_MOD;
	elseif difficulty == -3 then -- Legendary
		TURN_AT_WAR = TURN_AT_WAR * WW_LEGENDARY_MOD;
	end
	
	if cm:is_new_game() then	
		local faction_list = cm:model():world():faction_list();
		
		for i = 0, faction_list:num_items() - 1 do
			local current_faction = faction_list:item_at(i);
			
			if current_faction:is_null_interface() == false then
				if current_faction:is_human() == true then
					cm:show_message_event(
						current_faction:name(),
						"message_event_text_text_mk_event_mk1212_wwintro_title",
						"message_event_text_text_mk_event_mk1212_wwintro_primary",
						"message_event_text_text_mk_event_mk1212_wwintro_secondary",
						true, 
						723
					);

					cm:apply_effect_bundle("att_bundle_war_weariness_0", current_faction:name(), 0);
				end

				PLAYER_WAR_WEARINESS[current_faction:name()] = 0;
				PLAYER_WAR_WEARINESS_TURNS_AT_WAR[current_faction:name()] = 0;
			end
		end
	end
end

function FactionTurnStart_WW(context)
	local faction = context:faction();
	if not faction or faction:is_null_interface() or not ww_turn_state_valid then
		return;
	end
	local faction_name = faction:name();
	local turn = cm:model():turn_number();
	if ww_last_turn[faction_name] == turn then
		return;
	end
	if ww_last_turn[faction_name] == nil then
		if ww_turn_entries >= 4096 then
			WW_Log("contract_error", {contract = "war_weariness_turn_budget", faction = faction_name});
			return;
		end
		ww_turn_entries = ww_turn_entries + 1;
	end
	-- Claim before the first state/model change. A partially failed callback is
	-- not retried: repeating an additive mutation cannot safely repair it.
	ww_last_turn[faction_name] = turn;

	-- Turn based war weariness increase/decrease depending on war and army locations		
	if faction:at_war() then
		-- AT WAR (DOES NOT AFFECT HORDES IN MK1212)

		if faction:is_horde() == false then
			if PLAYER_WAR_WEARINESS_TURNS_AT_WAR[faction_name] ~= nil then
				if PLAYER_WAR_WEARINESS_TURNS_AT_WAR[faction_name] >= TURN_AT_WAR_DELAY then
					Add_War_Weariness(faction_name, TURN_AT_WAR);

					local troopsAtHome = ArmiesInOwnLands(faction);
				
					if troopsAtHome >= 100 then
						Add_War_Weariness(faction_name, TROOPS_AT_HOME);
					elseif troopsAtHome >= 75 then
						Add_War_Weariness(faction_name, TROOPS_AT_HOME / 2);
					end
				end

				PLAYER_WAR_WEARINESS_TURNS_AT_WAR[faction_name] = PLAYER_WAR_WEARINESS_TURNS_AT_WAR[faction_name] + 1;
			else
				PLAYER_WAR_WEARINESS_TURNS_AT_WAR[faction_name] = 1;
			end
		end
	else
		-- AT PEACE
		PLAYER_WAR_WEARINESS_TURNS_AT_WAR[faction_name] = 0;
		Add_War_Weariness(faction_name, TURN_AT_PEACE);
	end
	
	Update_War_Weariness(faction);
	WW_Log("war_weariness_turn", {
		faction = faction_name, phase = "faction_turn_start", stage = "handler_exit",
		value = PLAYER_WAR_WEARINESS[faction_name],
		turns_at_war = PLAYER_WAR_WEARINESS_TURNS_AT_WAR[faction_name]
	});
end

function Update_War_Weariness(faction)
	if faction:is_null_interface() then
		return;
	end

	local war_weariness = 0;
	local bundle_applied = false;
	
	if PLAYER_WAR_WEARINESS[faction:name()]  then
		war_weariness = PLAYER_WAR_WEARINESS[faction:name()];
	end
	
	-----------------------------------------------------------
	---------------- Apply the correct effects ----------------
	-----------------------------------------------------------
	for i = 0, 100 do
		cm:remove_effect_bundle("att_bundle_war_weariness_"..i, faction:name());
	end
	
	-- Can only handle whole numbers
	war_weariness = math.floor(war_weariness);
	
	if war_weariness > 0 then
		cm:apply_effect_bundle("att_bundle_war_weariness_"..war_weariness, faction:name(), 0);
		bundle_applied = true;
	else
		cm:apply_effect_bundle("att_bundle_war_weariness_0", faction:name(), 0);
	end
	
	-----------------------------------------------------------
	---------------- Handle the message events ----------------
	-----------------------------------------------------------
	local last_shown_event = "DECREASED";
	
	if PLAYER_WAR_WEARINESS_EVENTS[faction:name()]  then
		last_shown_event = PLAYER_WAR_WEARINESS_EVENTS[faction:name()];
	end
	
	if last_shown_event == "DECREASED" then
		if bundle_applied == true then
			Show_War_Weariness_Message(faction:name(), "cha_rel_christianity_increase");
			PLAYER_WAR_WEARINESS_EVENTS[faction:name()] = "INCREASED";
		end
	end
end

function FactionLeaderSignsPeaceTreaty_WW(context)
	if context:character():faction():is_human() then
		Add_War_Weariness(context:character():faction():name(), PEACE_MADE);
	end
end

function BattleCompleted_WW(context)
	local attacker_result = cm:model():pending_battle():attacker_battle_result();
	local defender_result = cm:model():pending_battle():defender_battle_result();
	
	if attacker_result == "close_defeat" and defender_result == "close_defeat" then
		-- They've both had a close defeat, must have been a retreat not a battle!
		return;
	elseif battle_result_values[attacker_result] == nil or battle_result_values[defender_result] == nil then
		-- Both results must be understood before applying either side. An
		-- unknown defender result must not leave an attacker-only update.
		return;
	end

	local attacker_cqi, attacker_force_cqi, attacker_name = cm:pending_battle_cache_get_attacker(1);
	local defender_cqi, defender_force_cqi, defender_name = cm:pending_battle_cache_get_defender(1);
	if type(attacker_name) ~= "string" or attacker_name == ""
		or type(defender_name) ~= "string" or defender_name == "" then
		return;
	end
	local attacker = cm:model():world():faction_by_key(attacker_name);
	local defender = cm:model():world():faction_by_key(defender_name);
	
	if attacker and attacker:is_null_interface() == false then
		--if attacker:is_human() then
			local ww_value = battle_result_values[attacker_result];
			
			Add_War_Weariness(attacker:name(), ww_value);
			Update_War_Weariness(attacker);
		--end
	end
	
	if defender and defender:is_null_interface() == false then
		--if defender:is_human() then
			local ww_value = battle_result_values[defender_result];

			Add_War_Weariness(defender:name(), ww_value);
			Update_War_Weariness(defender);
		--end
	end
end

-------------------------------------------
---------------- Functions ----------------
-------------------------------------------
function Add_War_Weariness(faction, amount)

	if PLAYER_WAR_WEARINESS[faction] == nil then
		PLAYER_WAR_WEARINESS[faction] = MIN_WAR_WEARINESS + amount;
		PLAYER_WAR_WEARINESS[faction] = math.max(PLAYER_WAR_WEARINESS[faction], MIN_WAR_WEARINESS);
		PLAYER_WAR_WEARINESS[faction] = math.min(PLAYER_WAR_WEARINESS[faction], MAX_WAR_WEARINESS);
	else
		PLAYER_WAR_WEARINESS[faction] = PLAYER_WAR_WEARINESS[faction] + amount;
		PLAYER_WAR_WEARINESS[faction] = math.max(PLAYER_WAR_WEARINESS[faction], MIN_WAR_WEARINESS);
		PLAYER_WAR_WEARINESS[faction] = math.min(PLAYER_WAR_WEARINESS[faction], MAX_WAR_WEARINESS);
	end
end

function WarWearinessNerf()
	TURN_AT_WAR = 0;
end

function ArmiesInOwnLands(player)
	local forceCount = player:military_force_list():num_items();
	local trueForces = 0;
	local forcesAtHome = 0;

	for i = 0, forceCount - 1 do
		local force = player:military_force_list():item_at(i);
		
		if force:upkeep() > 0 then
			trueForces = trueForces + 1;
		
			if force:has_general() then
				local general = force:general_character();
				
				if general:has_region() then
					local regionOwner = general:region():owning_faction();
				
					if regionOwner:is_null_interface() == false then
						if regionOwner:name() == player:name() then
							forcesAtHome = forcesAtHome + 1;
						end
					end
				end
			end
		end
	end
	
	if trueForces > 0 then
		local percentAtHome = (forcesAtHome / trueForces) * 100;
		return percentAtHome;
	else
		-- Can't find any armies
		return 0;
	end
end

function Show_War_Weariness_Message(faction_name, event_ID)
	--local event_num = war_weariness_events[event_ID].num;
	local event_text = war_weariness_events[event_ID].text;
	local title = event_texts[event_text].title;
	local primary = event_texts[event_text].primary;
	local secondary = event_texts[event_text].secondary;	

	cm:show_message_event(
		faction_name,
		title,
		primary,
		secondary,
		false,
		723
	);
end

------------------------------------------------
---------------- Saving/Loading ----------------
------------------------------------------------
cm:register_loading_game_callback(
	function(context)
		PLAYER_WAR_WEARINESS = LoadKeyPairTableNumbers(context, "PLAYER_WAR_WEARINESS");
		PLAYER_WAR_WEARINESS_EVENTS = LoadKeyPairTable(context, "PLAYER_WAR_WEARINESS_EVENTS");
		PLAYER_WAR_WEARINESS_TURNS_AT_WAR = LoadKeyPairTableNumbers(context, "PLAYER_WAR_WEARINESS_TURNS_AT_WAR");
		WW_Load_Turn_State(context);
	end
);
cm:register_saving_game_callback(
	function(context)
		SaveKeyPairTable(context, PLAYER_WAR_WEARINESS, "PLAYER_WAR_WEARINESS");
		SaveKeyPairTable(context, PLAYER_WAR_WEARINESS_EVENTS, "PLAYER_WAR_WEARINESS_EVENTS");
		SaveKeyPairTable(context, PLAYER_WAR_WEARINESS_TURNS_AT_WAR, "PLAYER_WAR_WEARINESS_TURNS_AT_WAR");
		WW_Save_Turn_State(context);
	end
);

------------------------------------------------
-------------- Event Text Strings --------------
------------------------------------------------
war_weariness_events = {
	["cha_rel_christianity_increase"] = {num = 401, text = "increase"},
	["cha_rel_christianity_decrease"] = {num = 403, text = "decrease"},
};
event_texts = {
	["increase"] = {
	title = "event_feed_strings_text_att_event_feed_string_scripted_event_war_weariness_increase_title",
	primary = "event_feed_strings_text_att_event_feed_string_scripted_event_war_weariness_increase_primary_detail",
	secondary = "event_feed_strings_text_att_event_feed_string_scripted_event_war_weariness_increase_secondary_detail"
	},
	["decrease"] = {
	title = "event_feed_strings_text_att_event_feed_string_scripted_event_war_weariness_decrease_title",
	primary = "event_feed_strings_text_att_event_feed_string_scripted_event_war_weariness_decrease_primary_detail",
	secondary = "event_feed_strings_text_att_event_feed_string_scripted_event_war_weariness_decrease_secondary_detail"
	}
};
