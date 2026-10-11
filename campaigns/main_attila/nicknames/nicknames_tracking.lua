-------------------------------------------------------------------------------------------
-------------------------------------------------------------------------------------------
--
-- 	MEDIEVAL KINGDOMS 1212 - NICKNAMES: TRACKING
-- 	By: DETrooper
--
-------------------------------------------------------------------------------------------
-------------------------------------------------------------------------------------------

CHARACTERS_TO_NICKNAMES = {};
CHARACTERS_TO_NICKNAME_STATS = {};

local nicknames_initialized = false;
local nickname_trait_keys = nil;
local nickname_last_turn = {};
local nickname_turn_valid = true;
local nickname_turn_raw = "";
local nickname_turn_prefix = "MKMP_NICKNAME_TURNS_V1;";

local function Nicknames_Log(stage, faction_name)
	if MKMP_Debug_Log then
		pcall(MKMP_Debug_Log, "nickname_phase", {domain = "shared_candidate", stage = stage,
			actor = faction_name, phase = "faction_turn_start", shared_delivery = "unproven"});
	end
end

local function Nicknames_Ordered_Characters(faction)
	local character_list = faction:character_list();
	local characters, seen = {}, {};
	for i = 0, character_list:num_items() - 1 do
		local character = character_list:item_at(i);
		if not character or character:is_null_interface() then return nil; end
		local cqi = character:cqi();
		if not MK1212_IsFiniteNumber(cqi) or cqi < 0 or cqi > 16777215
			or cqi ~= math.floor(cqi) or seen[cqi] or #characters >= 4096 then return nil; end
		seen[cqi] = true;
		characters[#characters + 1] = character;
	end
	table.sort(characters, function(a, b) return a:cqi() < b:cqi(); end);
	return characters;
end

local function Nicknames_Save_Turns(context)
	if not nickname_turn_valid then
		cm:save_value("MKMP_NICKNAME_TURNS", nickname_turn_raw, context);
		return;
	end
	local keys = MK1212_SaveSortedKeys(nickname_last_turn);
	if #keys > 4096 then error("MK1212 nickname turn faction budget exceeded"); end
	local rows = {nickname_turn_prefix};
	for i = 1, #keys do
		rows[#rows + 1] = keys[i]..","..string.format("%.0f", nickname_last_turn[keys[i]])..";";
	end
	local payload = table.concat(rows);
	if #payload > 262144 then error("MK1212 nickname turn byte budget exceeded"); end
	cm:save_value("MKMP_NICKNAME_TURNS", payload, context);
end

local function Nicknames_Load_Turns(context)
	local raw = cm:load_value("MKMP_NICKNAME_TURNS", "", context);
	nickname_turn_raw = raw;
	nickname_last_turn, nickname_turn_valid = {}, false;
	if raw == "" then nickname_turn_valid = true; return; end -- Legacy: no phase replay on load.
	if type(raw) ~= "string" or #raw > 262144 or string.sub(raw, 1, #nickname_turn_prefix) ~= nickname_turn_prefix then return; end
	local turns, count = {}, 0;
	local cursor = #nickname_turn_prefix + 1;
	while cursor <= #raw do
		local first, last, faction_name, encoded_turn = string.find(raw, "([A-Za-z0-9_%.%-]+),(%d+);", cursor);
		local round = tonumber(encoded_turn);
		if first ~= cursor or #faction_name > 128 or turns[faction_name] or count >= 4096
			or not MK1212_IsFiniteNumber(round) or round < 0 or round > 16777215
			or round ~= math.floor(round) or round > cm:model():turn_number() then return; end
		local faction = cm:model():world():faction_by_key(faction_name);
		if not faction or faction:is_null_interface() then return; end
		turns[faction_name] = round;
		count = count + 1;
		cursor = last + 1;
	end
	nickname_last_turn, nickname_turn_valid = turns, true;
end

function MKMP_Nicknames_Get_State()
	local function copy(value)
		if type(value) ~= "table" then return value; end
		local result, keys = {}, MK1212_SaveSortedKeys(value);
		if #keys > 20000 then error("Nickname diagnostic snapshot exceeds entry budget"); end
		for i = 1, #keys do result[keys[i]] = copy(value[keys[i]]); end
		return result;
	end
	return {schema = 1, complete = nickname_turn_valid, last_turn = copy(nickname_last_turn),
		names = copy(CHARACTERS_TO_NICKNAMES), stats = copy(CHARACTERS_TO_NICKNAME_STATS)};
end

function Add_Nicknames_Tracking_Listeners()
	if nicknames_initialized then return; end
	nicknames_initialized = true;
	if MKMP_Debug_Register_State_Provider then
		pcall(MKMP_Debug_Register_State_Provider, "nicknames", function()
			local data = MKMP_Nicknames_Get_State();
			if data.complete then return data, "complete"; end
			return data, "incomplete", "nickname_turn_state_invalid";
		end);
	end
	cm:add_listener(
		"FactionTurnStart_Nicknames",
		"FactionTurnStart",
		true,
		function(context) FactionTurnStart_Nicknames(context) end,
		true
	);
	cm:add_listener(
		"BattleCompleted_Nicknames",
		"BattleCompleted",
		true,
		function(context) BattleCompleted_Nicknames(context) end,
		true
	);
	cm:add_listener(
		"CharacterPerformsOccupationDecisionLoot_Nicknames",
		"CharacterPerformsOccupationDecisionLoot",
		true,
		function(context) CharacterPerformsOccupationDecision_Nicknames(context) end,
		true
	);
	cm:add_listener(
		"CharacterPerformsOccupationDecisionOccupy_Nicknames",
		"CharacterPerformsOccupationDecisionOccupy",
		true,
		function(context) CharacterPerformsOccupationDecision_Nicknames(context) end,
		true
	);
	cm:add_listener(
		"CharacterPostBattleSlaughter_Nicknames",
		"CharacterPostBattleSlaughter",
		true,
		function(context) CharacterPostBattle_Nicknames(context, "SLAUGHTER") end,
		true
	);
	cm:add_listener(
		"FactionReligionConverted_Nicknames",
		"FactionReligionConverted",
		true,
		function(context) FactionReligionConverted_Nicknames(context) end,
		true
	);
	cm:add_listener(
		"RegionRebels_Nicknames",
		"RegionRebels",
		true,
		function(context) RegionRebels_Nicknames(context) end,
		true
	);

	if cm:is_new_game() then
		local historical_keys = MK1212_SaveSortedKeys(HISTORICAL_CHARACTERS_TO_NICKNAMES);
		for i = 1, #historical_keys do
			local k = historical_keys[i];
			local v = HISTORICAL_CHARACTERS_TO_NICKNAMES[k];
			if string.find(k, "mk_fact_") then
				local faction = cm:model():world():faction_by_key(k);

				if not faction:is_null_interface() then
					local cqi = faction:faction_leader():cqi();

					Add_Character_Nickname(cqi, v, true);
				end
			elseif tonumber(k) then
				Add_Character_Nickname(tonumber(k), v, true);
			end
		end

		local faction_list = cm:model():world():faction_list();
		local factions = {};
		for i = 0, faction_list:num_items() - 1 do
			factions[#factions + 1] = faction_list:item_at(i);
		end
		table.sort(factions, function(a, b) return MK1212_SaveByteLess(a:name(), b:name()); end);
		for i = 1, #factions do
			local characters = Nicknames_Ordered_Characters(factions[i]);
			if characters then
				for j = 1, #characters do Check_Character_Nickname(characters[j]); end
			else
				Nicknames_Log("invalid_initial_characters", factions[i]:name());
			end
		end
	end
end

function FactionTurnStart_Nicknames(context)
	local faction = context:faction();
	if not faction or faction:is_null_interface() or not nickname_turn_valid then return; end
	local name, round = faction:name(), cm:model():turn_number();
	if type(name) ~= "string" or #name > 128 or not string.match(name, "^[A-Za-z0-9_%.%-]+$")
		or not MK1212_IsFiniteNumber(round) or round < 0 or round > 16777215 or round ~= math.floor(round) then return; end
	if nickname_last_turn[name] == round then Nicknames_Log("duplicate", name); return; end
	if nickname_last_turn[name] == nil and #MK1212_SaveSortedKeys(nickname_last_turn) >= 4096 then return; end
	local characters = Nicknames_Ordered_Characters(faction);
	if not characters then Nicknames_Log("invalid_characters", name); return; end
	-- Distinct from the historical/new-game pass. Claim before the first RNG
	-- draw or stat increment, and persist so reload cannot repeat this phase.
	nickname_last_turn[name] = round;
	Nicknames_Log("claimed", name);
	for i = 1, #characters do Check_Character_Nickname(characters[i]); end
	Nicknames_Log("requested", name);
end

function BattleCompleted_Nicknames(context)
	local attacker_result = cm:model():pending_battle():attacker_battle_result();
	local defender_result = cm:model():pending_battle():defender_battle_result();
	
	if attacker_result == "close_defeat" and defender_result == "close_defeat" then
		-- They've both had a close defeat, must have been a retreat not a battle!
		return;
	elseif attacker_result == nil or defender_result == nil then
		return;
	end

	local attacker_cqi, attacker_force_cqi, attacker_name = cm:pending_battle_cache_get_attacker(1);
	local defender_cqi, defender_force_cqi, defender_name = cm:pending_battle_cache_get_defender(1);
	local attacker = cm:model():world():faction_by_key(attacker_name);
	local defender = cm:model():world():faction_by_key(defender_name);
	
	if attacker:is_null_interface() == false then
		if attacker_result == "heroic_victory" then
			Increase_Character_Nickname_Stat(attacker_cqi, "heroic_victories", 1);
		end
	end
	
	if defender:is_null_interface() == false then
		if defender_result == "heroic_victory" then
			Increase_Character_Nickname_Stat(defender_cqi, "heroic_victories", 1);
		end
	end
end

function CharacterPerformsOccupationDecision_Nicknames(context)
	Increase_Character_Nickname_Stat(context:character():cqi(), "regions_taken", 1);
end

function CharacterPostBattle_Nicknames(context, type)
	if type == "SLAUGHTER" then
		Increase_Character_Nickname_Stat(context:character():cqi(), "captives_killed", 1);
	end
end

function FactionReligionConverted_Nicknames(context)
	local faction_leader = context:faction():faction_leader();

	if faction_leader then
		local state_religion = context:faction():state_religion();

		Add_Character_Nickname(faction_leader:cqi(), RELIGIONS_TO_NICKNAMES[state_religion], false);
	end
end

function RegionRebels_Nicknames(context)
	local region_owning_faction_leader = context:region():owning_faction():faction_leader();

	if region_owning_faction_leader then
		Set_Character_Nickname_Stat(region_owning_faction_leader:cqi(), "turns_without_revolt", 0);
	end
end

function Check_Character_Nickname(character)
	-- For now only generals will have nicknames, since most nicknames only really concern them.
	if character:character_type("general") then
		--dev.log("Checking character "..tostring(character:cqi()).." for faction "..character:faction():name());
		local age = character:age();
		local cqi = character:cqi();
		local cqi_str = tostring(cqi);

		if age >= 90 then
			Add_Character_Nickname(cqi, "the_undying", false);
		elseif age >= 65 then
			Add_Character_Nickname(cqi, "the_old", false);
		end

		if nickname_trait_keys == nil then nickname_trait_keys = MK1212_SaveSortedKeys(TRAITS_TO_NICKNAMES); end
		for i = 1, #nickname_trait_keys do
			local trait = nickname_trait_keys[i];
			local nickname = TRAITS_TO_NICKNAMES[trait];
			if character:has_trait(trait) then
				-- Make sure the character actually has the trait and it isn't just invisible.
				if character:trait_points(trait) >= 4 then
					-- 100% chance past this threshold (4 points is generally level 2 trait).
					Add_Character_Nickname(cqi, nickname, false);
				elseif character:trait_points(trait) >= 2 then
					if MK1212_Random_Int(1, 10, "nicknames.trait:"..cqi_str..":"..trait) == 1 then
						Add_Character_Nickname(cqi, nickname, false);
					end
				end
			end
		end

		Validate_Characker_Nickname_Stats(cqi_str);

		if character:is_faction_leader() then
			local faction_region_list = character:faction():region_list();

			if faction_region_list:num_items() > 4 then
				CHARACTERS_TO_NICKNAME_STATS[cqi_str].turns_without_revolt = CHARACTERS_TO_NICKNAME_STATS[cqi_str].turns_without_revolt + 1;
			end
		end

		if CHARACTERS_TO_NICKNAME_STATS[cqi_str].regions_taken >= 25 then
			Add_Character_Nickname(cqi, "the_great", false);
		elseif CHARACTERS_TO_NICKNAME_STATS[cqi_str].regions_taken >= 10 then
			Add_Character_Nickname(cqi, "the_conqueror", false);
		end

		if CHARACTERS_TO_NICKNAME_STATS[cqi_str].captives_killed >= 15 then
			Add_Character_Nickname(cqi, "the_merciless", false);
		elseif CHARACTERS_TO_NICKNAME_STATS[cqi_str].captives_killed >= 5 then
			Add_Character_Nickname(cqi, "the_cruel", false);
		end

		if CHARACTERS_TO_NICKNAME_STATS[cqi_str].times_excommunicated >= 2 then
			Add_Character_Nickname(cqi, "the_wicked", false);
		end

		if CHARACTERS_TO_NICKNAME_STATS[cqi_str].turns_without_revolt >= 40 then
			Add_Character_Nickname(cqi, "the_fair", false);
		end

		if CHARACTERS_TO_NICKNAME_STATS[cqi_str].heroic_victories >= 5 then
			Add_Character_Nickname(cqi, "the_hero", false);
		end

		if character:offensive_ambush_battles_won() >= 5 then
			Add_Character_Nickname(cqi, "the_bold", false);
		end

		if character:battles_won() >= 25 then
			if character:battles_won() == character:battles_fought() then
				Add_Character_Nickname(cqi, "the_undefeated", true);
			else
				Add_Character_Nickname(cqi, "the_victorious", false);
			end
		end
	end
end

function Decrease_Character_Nickname_Stat(cqi, stat, amount)
	local cqi_str = tostring(cqi);
	--dev.log("Decreasing char nickname stat "..stat.." for "..cqi_str.." for faction "..character:faction():name());

	Validate_Characker_Nickname_Stats(cqi_str);

	CHARACTERS_TO_NICKNAME_STATS[cqi_str][stat] = CHARACTERS_TO_NICKNAME_STATS[cqi_str][stat] - amount;

	if CHARACTERS_TO_NICKNAME_STATS[cqi_str][stat] < 0 then
		CHARACTERS_TO_NICKNAME_STATS[cqi_str][stat] = 0;
	end
end

function Increase_Character_Nickname_Stat(cqi, stat, amount)
	local cqi_str = tostring(cqi);
	--dev.log("Increasing char nickname stat "..stat.." for "..cqi_str.." for faction "..character:faction():name());

	Validate_Characker_Nickname_Stats(cqi_str);

	CHARACTERS_TO_NICKNAME_STATS[cqi_str][stat] = CHARACTERS_TO_NICKNAME_STATS[cqi_str][stat] + amount;
end

function Set_Character_Nickname_Stat(cqi, stat, value)
	local cqi_str = tostring(cqi);
	--dev.log("Increasing char nickname stat "..stat.." for "..cqi_str.." for faction "..character:faction():name());

	Validate_Characker_Nickname_Stats(cqi_str);

	CHARACTERS_TO_NICKNAME_STATS[cqi_str][stat] = value;
end

function Validate_Characker_Nickname_Stats(cqi_str)
	if not CHARACTERS_TO_NICKNAME_STATS[cqi_str] then
		CHARACTERS_TO_NICKNAME_STATS[cqi_str] = {
			["regions_taken"] = 0,
			["captives_killed"] = 0,
			["times_excommunicated"] = 0,
			["turns_without_revolt"] = 0,
			["heroic_victories"] = 0,
		};
	end
end

------------------------------------------------
---------------- Saving/Loading ----------------
------------------------------------------------
cm:register_saving_game_callback(
	function(context)
		SaveKeyPairTable(context, CHARACTERS_TO_NICKNAMES, "CHARACTERS_TO_NICKNAMES");
		SaveNicknamesStatsTable(context, CHARACTERS_TO_NICKNAME_STATS, "CHARACTERS_TO_NICKNAME_STATS");
		Nicknames_Save_Turns(context);
	end
);

cm:register_loading_game_callback(
	function(context)
		local nicknames = LoadKeyPairTable(context, "CHARACTERS_TO_NICKNAMES");
		local stats = LoadNicknamesStatsTable(context, "CHARACTERS_TO_NICKNAME_STATS");
		Nicknames_Load_Turns(context);
		CHARACTERS_TO_NICKNAMES, CHARACTERS_TO_NICKNAME_STATS = nicknames, stats;
	end
);

local nickname_save_fields = {"regions_taken", "captives_killed", "times_excommunicated", "turns_without_revolt", "heroic_victories"};

function SaveNicknamesStatsTable(context, tab, savename)
	local parts = {};
	local keys = MK1212_SaveSortedKeys(tab);
	for i = 1, #keys do
		local key = keys[i];
		local values = tab[key];
		if type(values) ~= "table" then error("MK1212 save refused: invalid nickname record"); end
		MK1212_SaveAppend(parts, key, ",");
		for j = 1, #nickname_save_fields do
			local value = values[nickname_save_fields[j]];
			if not MK1212_IsFiniteNumber(value) then error("MK1212 save refused: invalid nickname number"); end
			MK1212_SaveAppend(parts, value, ",");
		end
		MK1212_SaveEndRow(parts);
	end
	MK1212_SaveCommitString(context, savename, table.concat(parts), #keys);
end

function LoadNicknamesStatsTable(context, savename)
	local rows = MK1212_LoadSaveRows(context, savename);
	local tab = {};
	for i = 1, #rows do
		local row = rows[i];
		local key = MK1212_SaveUniqueRow(tab, row, 6, savename);
		local values = {};
		for j = 1, #nickname_save_fields do values[nickname_save_fields[j]] = MK1212_SaveNumber(row[j + 1], savename); end
		tab[key] = values;
	end
	return tab;
end
