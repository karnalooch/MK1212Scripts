-------------------------------------------------------------------------------------------------------------
-------------------------------------------------------------------------------------------------------------
--
-- 	MEDIEVAL KINGDOMS 1212 - MECHANICS: REGION TRADING
-- 	By: DETrooper
--
-------------------------------------------------------------------------------------------------------------
-------------------------------------------------------------------------------------------------------------

local min_gift_value = 1500; -- Minimum value of a region before the AI will accept it as a gift.
local regions_giving = {}; -- Regions being given to the AI.
local regions_recieving = {}; -- Regions being demanded by the player.
local region_trade_panel_open = false;
local region_trade_initialized = false;
local region_trade_pending = {};
local REGION_TRADE_KEY = "MKMP_REGION_TRADE_PENDING";
local REGION_TRADE_MAX_PENDING = 32;
local REGION_TRADE_MAX_BYTES = 131072;

local function Region_Trade_Key(value)
	return type(value) == "string" and #value > 0 and #value <= 256
		and string.match(value, "^[A-Za-z0-9_]+$") ~= nil;
end

local function Region_Trade_Log(claim, stage)
	if MKMP_Debug_Trace then
		pcall(MKMP_Debug_Trace, "shared_candidate", "region_trade", {
			action_id = claim.id, actor = claim.actor, target = claim.payload.target,
			stage = stage, phase = claim.phase, native_delivery = "unproven"
		});
	end
end

local function Region_Trade_Serialize(claims)
	local keys = MK1212_SaveSortedKeys(claims);
	if #keys > REGION_TRADE_MAX_PENDING then error("region trade pending budget"); end
	local parts = {};
	for i = 1, #keys do
		local id, claim = keys[i], claims[keys[i]];
		local payload = claim.payload;
		if type(id) ~= "string" or #id > 512 or claim.id ~= id or not Region_Trade_Key(claim.actor)
			or type(payload) ~= "table" or #MK1212_SaveSortedKeys(payload) ~= 4
			or not Region_Trade_Key(payload.target) or claim.actor == payload.target
			or not MK1212_IsFiniteNumber(payload.turn) or payload.turn < 1 or payload.turn > cm:model():turn_number()
			or payload.turn ~= math.floor(payload.turn) or (claim.phase ~= "requested" and claim.phase ~= "uncertain") then
			error("invalid region trade pending claim");
		end
		local prefix = "sp:"..claim.actor..":";
		local serial_text = string.sub(id, #prefix + 1);
		local serial = tonumber(serial_text);
		if string.sub(id, 1, #prefix) ~= prefix or not MK1212_IsFiniteNumber(serial) or serial < 1
			or serial > 1000000 or serial ~= math.floor(serial) or tostring(serial) ~= serial_text then
			error("invalid region trade action identity");
		end
		local giving = MK1212_SaveDenseLength(payload.giving, 32);
		local receiving = MK1212_SaveDenseLength(payload.receiving, 32);
		if giving + receiving == 0 then error("empty region trade claim"); end
		MK1212_SaveAppend(parts, id, ",");
		MK1212_SaveAppend(parts, claim.actor, ",");
		MK1212_SaveAppend(parts, payload.target, ",");
		MK1212_SaveAppend(parts, payload.turn, ",");
		MK1212_SaveAppend(parts, claim.phase, ",");
		MK1212_SaveAppend(parts, giving, ",");
		MK1212_SaveAppend(parts, receiving, ",");
		local seen = {};
		for _, list in ipairs({payload.giving, payload.receiving}) do
			for j = 1, #list do
				local key = list[j];
				if not Region_Trade_Key(key) or seen[key] then error("invalid/duplicate region trade region"); end
				seen[key] = true;
				MK1212_SaveAppend(parts, key, ",");
			end
		end
		MK1212_SaveEndRow(parts);
	end
	local payload = table.concat(parts);
	if #payload > REGION_TRADE_MAX_BYTES then error("region trade pending save budget"); end
	return payload, #keys;
end

local function Region_Trade_Ownership_Observed(claim)
	local world = cm:model():world();
	local lists, targets = {claim.payload.giving, claim.payload.receiving}, {claim.payload.target, claim.actor};
	for side = 1, 2 do
		for i = 1, #lists[side] do
			local region = world:region_manager():region_by_key(lists[side][i]);
			if not region or region:is_null_interface() then return false; end
			local owner = region:owning_faction();
			if not owner or owner:is_null_interface() or owner:name() ~= targets[side] then return false; end
		end
	end
	return true;
end

function MKMP_Region_Trade_Observe()
	if cm:is_multiplayer() then return; end
	local ids = MK1212_SaveSortedKeys(region_trade_pending);
	for i = 1, #ids do
		local claim = region_trade_pending[ids[i]];
		local matches = MKMP_Actions_Matches and MKMP_Actions_Matches(claim.id, "region_trade", claim.actor, claim.payload);
		if matches then
			local ok, observed = pcall(Region_Trade_Ownership_Observed, claim);
			if ok and observed and MKMP_Actions_Confirm(claim.id, "confirmed") then
				-- Observation retires only this exact captured operation. It never
				-- issues another region transfer or consumes a sidecar ACK.
				region_trade_pending[claim.id] = nil;
				Region_Trade_Log(claim, "ownership_observed");
			end
		end
	end
end

function MKMP_Region_Trade_Get_State()
	return MKMP_Diagnostic_Copy({schema = 1, enabled = region_trade_initialized, pending = region_trade_pending}), "complete";
end

function Add_Region_Trading_Listeners()
	if region_trade_initialized then return; end
	region_trade_initialized = true;
	MKMP_Actions_Register("region_trade", {validate = MKMP_Region_Trade_Validate, execute = MKMP_Region_Trade_Execute});
	cm:add_listener(
		"OnComponentLClickUp_Region_Trading_UI",
		"ComponentLClickUp",
		true,
		function(context) OnComponentLClickUp_Region_Trading_UI(context) end,
		true
	);
	cm:add_listener(
		"OnPanelOpenedCampaign_Region_Trading_UI",
		"PanelOpenedCampaign",
		true,
		function(context) OnPanelOpenedCampaign_Region_Trading_UI(context) end,
		true
	);
	cm:add_listener(
		"TimeTrigger_Region_Trading_UI",
		"TimeTrigger",
		true,
		function(context) TimeTrigger_Region_Trading_UI(context) end,
		true
	);
	cm:add_listener("FactionTurnStart_Region_Trade_Observe", "FactionTurnStart", true,
		function() MKMP_Region_Trade_Observe(); end, true);
end

local function Calculate_Region_Value(region, purchaser_name)
	local buildings_list = region:garrison_residence():buildings();
	local owner = region:owning_faction();
	local regionX = region:settlement():logical_position_x();
	local regionY = region:settlement():logical_position_y();
	local farthest_region_distance;
	local value = 0; -- Value of the region.

	-- Increase the value of the region by the sum of the monetary value of its buildings.
	for i = 0, buildings_list:num_items() - 1 do
		local building_value = REGION_TRADING_BUILDING_VALUES[buildings_list:item_at(i):name()] or 0;

		value = value + building_value;
	end

	if purchaser_name then -- Region belongs to the player.
		local purchaser_faction = cm:model():world():faction_by_key(purchaser_name);
		local purchaser_region_list = purchaser_faction:region_list();

		-- Modify value based off the region owner's attitude towards the purchasing faction.
		local stance = cm:model():campaign_ai():strategic_stance_between_factions(owner:name(), purchaser_name);

		if REGION_TRADING_STANCE_MODIFIERS[tostring(stance)] then
			value = value + REGION_TRADING_STANCE_MODIFIERS[tostring(stance)];
		end

		-- Decrease the value of the region by its distance from the purchasing faction's borders.
		for i = 0, purchaser_region_list:num_items() - 1 do
			local purchaser_region = purchaser_region_list:item_at(i);
			local purchaser_region_adjacent_region_list = purchaser_region:adjacent_region_list();
			local purchaser_regionX = purchaser_region:settlement():logical_position_x();
			local purchaser_regionY = purchaser_region:settlement():logical_position_y();
			local purchaser_region_distance = ((purchaser_regionX - regionX) ^ 2 + (purchaser_regionY - regionY) ^ 2) ^ 0.5;

			-- If any of the purchasing faction's regions are adjacent to the traded region, skip the penalty.
			if purchaser_region_adjacent_region_list:num_items() > 0 then
				for k = 0, purchaser_region_adjacent_region_list:num_items() - 1 do
					local adjacent_region = purchaser_region_adjacent_region_list:item_at(k);

					if adjacent_region:name() == region:name() or purchaser_region_distance < 50 then
						farthest_region_distance = "adjacent";
						break;
					end
				end

				if farthest_region_distance == "adjacent" then
					break;
				end
			end

			if not farthest_region_distance or farthest_region_distance < purchaser_region_distance then
				farthest_region_distance = purchaser_region_distance;
			end
		end

		if farthest_region_distance and farthest_region_distance ~= "adjacent" then
			local distance_penalty = math.floor(farthest_region_distance * (value / 500));

			--dev.log(region:name().." pre-penalty value: "..tostring(value));
			value = value - distance_penalty;
			--dev.log(region:name().." post-penalty value: "..tostring(value));
		end
	end

	return value;
end

local function Calculate_Region_Trade_Value()
	local root = cm:ui_root();
	local diplomacy_dropdown_uic = UIComponent(root:Find("diplomacy_dropdown"));
	local offers_panel_uic = UIComponent(diplomacy_dropdown_uic:Find("offers_panel"));
	local offers_list_panel_uic = UIComponent(offers_panel_uic:Find("offers_list_panel"));
	local list_offers_uic = UIComponent(offers_list_panel_uic:Find("list_offers"));
	local list_offers_list_box_uic = UIComponent(list_offers_uic:Find("list_box"));
	local list_demands_uic = UIComponent(offers_list_panel_uic:Find("list_demands"));
	local list_demands_list_box_uic = UIComponent(list_demands_uic:Find("list_box"));
	local button_set1_uic = UIComponent(offers_panel_uic:Find("button_set1"));
	local tx_likelihood_uic = UIComponent(offers_list_panel_uic:Find("tx_likelihood_of_success"));
	local dy_chance_uic = UIComponent(tx_likelihood_uic:Find("dy_chance"));
	local current_trade_weight = 0; -- Current trade weight from the player's side.
	local current_trade_value_other = 0; -- Trade weight of the other faction in diplomacy.
	local regions_checked = 0;

	regions_giving = {}; -- clear table
	regions_recieving = {}; -- clear table

	for i = 0, list_offers_list_box_uic:ChildCount() - 1 do
		local child = UIComponent(list_offers_list_box_uic:Find(i));
		local checkbox_uic = UIComponent(child:Find("checkbox"));

		if checkbox_uic:CurrentState() == "selected" or checkbox_uic:CurrentState() == "selected_hover" or checkbox_uic:CurrentState() == "down" then
			local region = cm:model():world():region_manager():region_by_key(child:Id());

			current_trade_weight = current_trade_weight + Calculate_Region_Value(region, DIPLOMACY_SELECTED_FACTION);

			table.insert(regions_giving, region:name());

			regions_checked = regions_checked + 1;
		end
	end;

	for i = 0, list_demands_list_box_uic:ChildCount() - 1 do
		local child = UIComponent(list_demands_list_box_uic:Find(i));
		local checkbox_uic = UIComponent(child:Find("checkbox"));

		if checkbox_uic:CurrentState() == "selected" or checkbox_uic:CurrentState() == "selected_hover" or checkbox_uic:CurrentState() == "down" then
			local region = cm:model():world():region_manager():region_by_key(child:Id());

			current_trade_value_other = current_trade_value_other + Calculate_Region_Value(region);

			table.insert(regions_recieving, region:name());

			regions_checked = regions_checked + 1;
		end
	end;

	if regions_checked > 0 then
		if current_trade_weight < current_trade_value_other - min_gift_value or (current_trade_weight < min_gift_value and current_trade_value_other <= 0) then
			dy_chance_uic:SetState("low");
			UIComponent(button_set1_uic:Find("button_send")):SetState("inactive");
		elseif current_trade_weight < current_trade_value_other then
			dy_chance_uic:SetState("moderate");
			UIComponent(button_set1_uic:Find("button_send")):SetState("inactive");
		elseif current_trade_weight >= current_trade_value_other and current_trade_weight < current_trade_value_other + (min_gift_value * 2) then
			dy_chance_uic:SetState("moderate");
			UIComponent(button_set1_uic:Find("button_send")):SetState("active");
		elseif current_trade_weight >= current_trade_value_other + (min_gift_value * 2) then
			dy_chance_uic:SetState("high");
			UIComponent(button_set1_uic:Find("button_send")):SetState("active");
		end

		tx_likelihood_uic:SetVisible(true);
	else
		tx_likelihood_uic:SetVisible(false);
		UIComponent(button_set1_uic:Find("button_send")):SetState("inactive");
	end
end

function MKMP_Region_Trade_Validate(actor, payload)
	if #MK1212_SaveSortedKeys(payload) ~= 4 or not Region_Trade_Key(payload.target) or actor == payload.target
		or payload.turn ~= cm:model():turn_number() then return false, "trade_actor_or_turn"; end
	local world = cm:model():world();
	local source, target = world:faction_by_key(actor), world:faction_by_key(payload.target);
	if not source or source:is_null_interface() or not target or target:is_null_interface()
		or source:is_horde() or target:is_horde() or source:at_war_with(target) then return false, "trade_relation"; end
	if FACTIONS_VASSALIZED_ANNEXING and FACTIONS_VASSALIZED_ANNEXING[payload.target] then return false, "trade_annexing"; end
	local ids = MK1212_SaveSortedKeys(region_trade_pending);
	if #ids >= REGION_TRADE_MAX_PENDING then return false, "trade_pending_budget"; end
	for i = 1, #ids do
		if region_trade_pending[ids[i]].actor == actor then return false, "trade_prior_ownership_unconfirmed"; end
	end
	local seen, count, values = {}, 0, {0, 0};
	local lists, owners = {payload.giving, payload.receiving}, {source, target};
	for side = 1, 2 do
		local length = MK1212_SaveDenseLength(lists[side], 32);
		for i = 1, length do
			local key = lists[side][i];
			if type(key) ~= "string" or seen[key] then return false, "trade_duplicate_region"; end
			seen[key], count = true, count + 1;
			local region = world:region_manager():region_by_key(key);
			if not region or region:is_null_interface() or region:owning_faction():name() ~= owners[side]:name()
				or (owners[side]:has_home_region() and owners[side]:home_region():name() == key)
				or region:garrison_residence():is_under_siege() then return false, "trade_region_changed"; end
			values[side] = values[side] + Calculate_Region_Value(region, side == 1 and payload.target or nil);
		end
	end
	if count == 0 or #REGIONS_TO_TRANSFER + count > MAX_PENDING_REGION_TRANSFERS then return false, "trade_queue_budget"; end
	if values[1] < values[2] or (values[2] <= 0 and values[1] < min_gift_value) then return false, "trade_value_changed"; end
	return true;
end

function MKMP_Region_Trade_Execute(actor, payload, action_id)
	local claim = {id = action_id, actor = actor, payload = MKMP_Actions_Copy(payload), phase = "uncertain"};
	if region_trade_pending[action_id] or not MKMP_Actions_Matches(action_id, "region_trade", actor, payload) then
		return false, "trade_action_identity";
	end
	region_trade_pending[action_id] = claim;
	if not pcall(Region_Trade_Serialize, region_trade_pending) then
		region_trade_pending[action_id] = nil;
		return false, "trade_pending_save_budget";
	end
	Region_Trade_Log(claim, "claimed_before_command");
	local ok, accepted = pcall(function()
		local lists, targets = {payload.giving, payload.receiving}, {payload.target, actor};
		for side = 1, 2 do
			for i = 1, #lists[side] do
				if Transfer_Region_To_Faction(lists[side][i], targets[side]) ~= true then return false; end
			end
		end
		return true;
	end);
	if not ok or not accepted then
		Region_Trade_Log(claim, "uncertain");
		return false, "trade_transfer_unknown";
	end
	claim.phase = "requested";
	MKMP_Region_Trade_Observe();
	return true, region_trade_pending[action_id] and "requested" or "confirmed";
end

local function Process_Region_Trade()
	local root = cm:ui_root();
	local diplomacy_dropdown_uic = UIComponent(root:Find("diplomacy_dropdown"));
	local offers_panel_uic = UIComponent(diplomacy_dropdown_uic:Find("offers_panel"));
	local offers_list_panel_uic = UIComponent(offers_panel_uic:Find("offers_list_panel"));
	local list_offers_uic = UIComponent(offers_list_panel_uic:Find("list_offers"));
	local list_offers_list_box_uic = UIComponent(list_offers_uic:Find("list_box"));
	local list_demands_uic = UIComponent(offers_list_panel_uic:Find("list_demands"));
	local list_demands_list_box_uic = UIComponent(list_demands_uic:Find("list_box"));
	local tx_likelihood_uic = UIComponent(offers_list_panel_uic:Find("tx_likelihood_of_success"));
	local button_set1_uic = UIComponent(offers_panel_uic:Find("button_set1"));
	local faction_name = cm:get_local_faction();

	local giving = MKMP_Actions_Copy(regions_giving);
	local receiving = MKMP_Actions_Copy(regions_recieving);
	table.sort(giving, MK1212_SaveByteLess);
	table.sort(receiving, MK1212_SaveByteLess);
	local accepted, reason = MKMP_Actions_Submit_Local("region_trade", faction_name,
		{target = DIPLOMACY_SELECTED_FACTION, giving = giving, receiving = receiving, turn = cm:model():turn_number()});
	if not accepted then
		MKMP_Actions_UI_Feedback(button_set1_uic:Find("button_send"), reason);
		return false;
	end

	UIComponent(button_set1_uic:Find("button_counteroffer")):SetVisible(true);
	list_offers_list_box_uic:DestroyChildren();
	list_offers_uic:SetVisible(false);
	list_demands_list_box_uic:DestroyChildren();
	list_demands_uic:SetVisible(false);
	tx_likelihood_uic:SetVisible(false);
	return true;
end

local function Open_Region_Trading_Panel()
	local root = cm:ui_root();
	local diplomacy_dropdown_uic = UIComponent(root:Find("diplomacy_dropdown"));
	local offers_panel_uic = UIComponent(diplomacy_dropdown_uic:Find("offers_panel"));
	local offers_list_panel_uic = UIComponent(offers_panel_uic:Find("offers_list_panel"));
	local button_set1_uic = UIComponent(offers_panel_uic:Find("button_set1"));
	
	UIComponent(offers_panel_uic:Find("current_treaties")):SetVisible(false);
	UIComponent(offers_panel_uic:Find("their_offers")):SetVisible(false);
	UIComponent(offers_panel_uic:Find("your_offers")):SetVisible(false);
	UIComponent(button_set1_uic:Find("button_counteroffer")):SetVisible(false);

	local diplomacy_faction = cm:model():world():faction_by_key(DIPLOMACY_SELECTED_FACTION);
	local diplomacy_faction_capital = diplomacy_faction:home_region():name();
	local diplomacy_faction_regions = diplomacy_faction:region_list();
	local faction = cm:model():world():faction_by_key(cm:get_local_faction());
	local faction_capital = faction:home_region():name();
	local faction_regions = faction:region_list();
	local list_offers_uic = UIComponent(offers_list_panel_uic:Find("list_offers"));
	local list_offers_list_box_uic = UIComponent(list_offers_uic:Find("list_box"));
	local list_demands_uic = UIComponent(offers_list_panel_uic:Find("list_demands"));
	local list_demands_list_box_uic = UIComponent(list_demands_uic:Find("list_box"));
	local tx_likelihood_uic = UIComponent(offers_list_panel_uic:Find("tx_likelihood_of_success"));

	list_offers_list_box_uic:DestroyChildren();
	list_demands_list_box_uic:DestroyChildren();

	for i = 0, faction_regions:num_items() - 1 do
		local region = faction_regions:item_at(i);
		local region_name = region:name();

		if region_name ~= faction_capital and region:garrison_residence():is_under_siege() ~= true then
			UIComponent(list_offers_list_box_uic:CreateComponent(region_name, "ui/new/template_region_list_item")):SetStateText(REGIONS_NAMES_LOCALISATION[region_name]);
		end
	end

	for i = 0, diplomacy_faction_regions:num_items() - 1 do
		local region = diplomacy_faction_regions:item_at(i);
		local region_name = region:name();

		if region_name ~= diplomacy_faction_capital and region:garrison_residence():is_under_siege() ~= true then
			UIComponent(list_demands_list_box_uic:CreateComponent(region_name, "ui/new/template_region_list_item")):SetStateText(REGIONS_NAMES_LOCALISATION[region_name]);
		end
	end

	list_offers_list_box_uic:Layout();
	list_offers_uic:SetVisible(true);
	list_demands_list_box_uic:Layout();
	list_demands_uic:SetVisible(true);
	tx_likelihood_uic:SetVisible(false);
end

function OnComponentLClickUp_Region_Trading_UI(context)
	if context.string == "button_trade_regions" then
		local diplomacy_faction = cm:model():world():faction_by_key(DIPLOMACY_SELECTED_FACTION);

		if diplomacy_faction then
			local faction_panel_uic = UIComponent(UIComponent(context.component):Parent());

			region_trade_panel_open = true;

			UIComponent(faction_panel_uic:Find("button_ok")):SimulateClick();

			cm:add_time_trigger("region_trading_open_panel", 0);
		end
	elseif DIPLOMACY_PANEL_OPEN == true then
		if not region_trade_panel_open then
			if context.string == "map" or context.string == "button_icon" or context.string == "flag" or string.find(context.string, "faction_row_entry_") then
				local root = cm:ui_root();
				local diplomacy_dropdown_uic = UIComponent(root:Find("diplomacy_dropdown"));
				local button_trade_regions_uic = UIComponent(diplomacy_dropdown_uic:Find("button_trade_regions"));

				button_trade_regions_uic:SetState("inactive");

				cm:add_time_trigger("region_trading_diplo_hud_check", 0.1);
			end
		else
			if context.string == "button_cancel" then
				local root = cm:ui_root();
				local diplomacy_dropdown_uic = UIComponent(root:Find("diplomacy_dropdown"));
				local offers_panel_uic = UIComponent(diplomacy_dropdown_uic:Find("offers_panel"));
				local offers_list_panel_uic = UIComponent(offers_panel_uic:Find("offers_list_panel"));
				local list_offers_uic = UIComponent(offers_list_panel_uic:Find("list_offers"));
				local list_offers_list_box_uic = UIComponent(list_offers_uic:Find("list_box"));
				local list_demands_uic = UIComponent(offers_list_panel_uic:Find("list_demands"));
				local list_demands_list_box_uic = UIComponent(list_demands_uic:Find("list_box"));
				local tx_likelihood_uic = UIComponent(offers_list_panel_uic:Find("tx_likelihood_of_success"));
				local button_set1_uic = UIComponent(offers_panel_uic:Find("button_set1"));
				local button_trade_regions_uic = UIComponent(diplomacy_dropdown_uic:Find("button_trade_regions"));

				UIComponent(button_set1_uic:Find("button_counteroffer")):SetVisible(true);

				list_offers_list_box_uic:DestroyChildren();
				list_offers_uic:SetVisible(false);
				list_demands_list_box_uic:DestroyChildren();
				list_demands_uic:SetVisible(false);
				tx_likelihood_uic:SetVisible(false);

				if button_trade_regions_uic:CurrentState() == "down" then
					button_trade_regions_uic:SetState("active");
				end

				region_trade_panel_open = false;
			elseif context.string == "button_send" then
				if Process_Region_Trade() then region_trade_panel_open = false; end
			elseif context.string == "checkbox" then
				Calculate_Region_Trade_Value();
			end
		end
	end
end

function OnPanelOpenedCampaign_Region_Trading_UI(context)
	if context.string == "diplomacy_dropdown" then
		cm:add_time_trigger("region_trading_diplo_hud_check", 0.1);
	end
end

function TimeTrigger_Region_Trading_UI(context)
	if context.string == "region_trading_diplo_hud_check" then
		local root = cm:ui_root();
		local diplomacy_dropdown_uic = UIComponent(root:Find("diplomacy_dropdown"));

		if diplomacy_dropdown_uic then
			local button_trade_regions_uic = UIComponent(diplomacy_dropdown_uic:Find("button_trade_regions"));

			button_trade_regions_uic:SetState("inactive");
			button_trade_regions_uic:SetVisible(true);

			if DIPLOMACY_SELECTED_FACTION then
				local diplomacy_faction = cm:model():world():faction_by_key(DIPLOMACY_SELECTED_FACTION);
				local faction = cm:model():world():faction_by_key(cm:get_local_faction());

				if diplomacy_faction then
					if diplomacy_faction:is_horde() or faction:is_horde() then
						-- Hordes cannot trade regions!
						return;
					end

					if diplomacy_faction:at_war_with(faction) ~= true then
						if FACTIONS_VASSALIZED_ANNEXING and FACTIONS_VASSALIZED_ANNEXING[DIPLOMACY_SELECTED_FACTION] == true then
							return;
						end

						button_trade_regions_uic:SetState("active");
					end
				end
			end
		end
	elseif context.string == "region_trading_open_panel" then
		Open_Region_Trading_Panel();
	end
end

-- New saves retain the exact operation payload only while ownership has not
-- been observed. Legacy saves have no such claim; local UI selection is never
-- migrated into a pending command. Loading never submits any region transfer.
cm:register_saving_game_callback(function(context)
	local payload, count = Region_Trade_Serialize(region_trade_pending);
	MK1212_SaveCommitString(context, REGION_TRADE_KEY, payload, count);
	cm:save_value(REGION_TRADE_KEY.."_VERSION", 1, context);
end);

cm:register_loading_game_callback(function(context)
	local version = cm:load_value(REGION_TRADE_KEY.."_VERSION", 0, context);
	local raw = cm:load_value(REGION_TRADE_KEY, "", context);
	local outer = cm:load_value(REGION_TRADE_KEY.."__schema", 0, context);
	local claims = {};
	if version == 0 and raw == "" and outer == 0 then
		-- No owner-managed trade observation state in pre-N4 saves.
	elseif version == 1 and outer == 3 and type(raw) == "string" and raw ~= "" then
		local rows = MK1212_LoadSaveRows(context, REGION_TRADE_KEY);
		if #rows > REGION_TRADE_MAX_PENDING then error("region trade pending budget"); end
		for i = 1, #rows do
			local row = rows[i];
			if #row < 8 or #row > 71 or claims[row[1]] then error("invalid region trade pending row"); end
			local giving = MK1212_SaveNumber(row[6], REGION_TRADE_KEY);
			local receiving = MK1212_SaveNumber(row[7], REGION_TRADE_KEY);
			if giving < 0 or receiving < 0 or giving > 32 or receiving > 32
				or giving ~= math.floor(giving) or receiving ~= math.floor(receiving)
				or giving + receiving == 0 or #row ~= 7 + giving + receiving
				or (row[5] ~= "requested" and row[5] ~= "uncertain") then error("invalid region trade pending shape"); end
			local payload = {target = row[3], turn = MK1212_SaveNumber(row[4], REGION_TRADE_KEY), giving = {}, receiving = {}};
			for j = 1, giving do payload.giving[j] = row[7 + j]; end
			for j = 1, receiving do payload.receiving[j] = row[7 + giving + j]; end
			claims[row[1]] = {id = row[1], actor = row[2], phase = "uncertain", payload = payload};
		end
		Region_Trade_Serialize(claims); -- Validate the entire next snapshot first.
	else
		error("MK1212 load refused: region trade pending schema");
	end
	region_trade_pending = claims;
	regions_giving, regions_recieving, region_trade_panel_open = {}, {}, false;
end);
