-----------------------------------------------------------------------------------------------------------------------
-----------------------------------------------------------------------------------------------------------------------
--
-- 	MEDIEVAL KINGDOMS 1212 - MECHANICS: ANNEX VASSALS
-- 	By: DETrooper
--
-----------------------------------------------------------------------------------------------------------------------
-----------------------------------------------------------------------------------------------------------------------

ANNEX_TURN_REQUIREMENT = 20; -- How long until annexation can begin when you've made a new vassal?
ANNEX_TURNS_PER_REGION = 3; -- Once annexation process has started, how many turns per region should it take to complete?

FACTIONS_VASSALIZED_ANNEXING = {};
FACTIONS_VASSALIZED_ANNEXATION_TIME = {};
FACTIONS_VASSALIZED_DELAYS = {};
local annex_initialized = false;
local annex_turn_ledger = {};
local annex_handover_claims = {};
local ANNEX_HANDOVER_KEY = "MKMP_ANNEX_HANDOVERS";
local ANNEX_MAX_HANDOVERS = 128;
local ANNEX_MAX_REGIONS = 128;
local ANNEX_MAX_CLAIM_BYTES = 131072;

local function Annex_Key(value)
	return type(value) == "string" and #value > 0 and #value <= 256
		and string.match(value, "^[A-Za-z0-9_]+$") ~= nil;
end

local function Annex_Claim_Phase(value)
	return value == "requested" or value == "uncertain" or value == "script_complete"
		or value == "ownership_observed";
end

local function Annex_Claim_Log(claim, stage)
	if MKMP_Debug_Trace then
		pcall(MKMP_Debug_Trace, "shared_candidate", "annex_handover", {
			actor = claim.actor, target = claim.target, stage = stage, phase = claim.phase,
			operation_turn = claim.turn, native_completion = "unproven"
		});
	end
end

local function Annex_Serialize_Claims(claims)
	local keys = MK1212_SaveSortedKeys(claims);
	if #keys > ANNEX_MAX_HANDOVERS then error("annex handover claim budget"); end
	local parts = {};
	for i = 1, #keys do
		local key, claim = keys[i], claims[keys[i]];
		if not Annex_Key(key) or not Annex_Key(claim.actor) or claim.target ~= key or claim.actor == key
			or not MK1212_IsFiniteNumber(claim.turn) or claim.turn < 1 or claim.turn > cm:model():turn_number()
			or claim.turn ~= math.floor(claim.turn) or not Annex_Claim_Phase(claim.phase) then
			error("invalid annex handover claim");
		end
		local count = MK1212_SaveDenseLength(claim.regions, ANNEX_MAX_REGIONS);
		if count < 1 then error("empty annex handover ownership claim"); end
		MK1212_SaveAppend(parts, key, ",");
		MK1212_SaveAppend(parts, claim.actor, ",");
		MK1212_SaveAppend(parts, claim.turn, ",");
		MK1212_SaveAppend(parts, claim.phase, ",");
		local previous = nil;
		for j = 1, count do
			local region = claim.regions[j];
			if not Annex_Key(region) or (previous and not MK1212_SaveByteLess(previous, region)) then
				error("invalid annex handover region order");
			end
			MK1212_SaveAppend(parts, region, j == count and ",;" or ",");
			previous = region;
		end
	end
	local payload = table.concat(parts);
	if #payload > ANNEX_MAX_CLAIM_BYTES then error("annex handover save budget"); end
	return payload, #keys;
end

local function Annex_Observe_Claim(claim)
	if claim.phase == "ownership_observed" then return; end
	local ok, observed = pcall(function()
		local manager = cm:model():world():region_manager();
		for i = 1, #claim.regions do
			local region = manager:region_by_key(claim.regions[i]);
			if not region or region:is_null_interface() then return false; end
			local owner = region:owning_faction();
			if not owner or owner:is_null_interface() or owner:name() ~= claim.actor then return false; end
		end
		return true;
	end);
	if ok and observed then
		-- This proves the captured regions' owners, not the complete native
		-- handover (armies, characters or remote command delivery).
		claim.phase = "ownership_observed";
		Annex_Claim_Log(claim, "ownership_observed");
	end
end

local function Annex_Claim_Handover(actor, target, faction)
	if annex_handover_claims[target] then return nil; end
	local regions, seen = {}, {};
	local list = faction:region_list();
	local count = list:num_items();
	if count < 1 or count > ANNEX_MAX_REGIONS then return nil; end
	for i = 0, count - 1 do
		local region = list:item_at(i);
		if not region or region:is_null_interface() then return nil; end
		local key, owner = region:name(), region:owning_faction();
		if not Annex_Key(key) or seen[key] or not owner or owner:is_null_interface() or owner:name() ~= target then return nil; end
		regions[#regions + 1], seen[key] = key, true;
	end
	table.sort(regions, MK1212_SaveByteLess);
	local claim = {actor = actor, target = target, turn = cm:model():turn_number(), phase = "requested", regions = regions};
	annex_handover_claims[target] = claim;
	if not pcall(Annex_Serialize_Claims, annex_handover_claims) then
		annex_handover_claims[target] = nil;
		return nil;
	end
	Annex_Claim_Log(claim, "claimed_before_command");
	return claim;
end

function Add_Annex_Vassals_Listeners()
	if annex_initialized then return; end
	annex_initialized = true;
	MKMP_Actions_Register("annex_vassal", {validate = MKMP_Annex_Validate, execute = MKMP_Annex_Execute});
	cm:add_listener(
		"FactionTurnStart_Annex",
		"FactionTurnStart",
		true,
		function(context) FactionTurnStart_Annex(context) end,
		true
	);
	cm:add_listener(
		"FactionUnvassalized_Annex",
		"FactionUnvassalized",
		true,
		function(context) FactionUnvassalized_Annex(context) end,
		true
	);
	cm:add_listener(
		"FactionVassalized_Annex",
		"FactionVassalized",
		true,
		function(context) FactionVassalized_Annex(context) end,
		true
	);
	cm:add_listener(
		"OnComponentMouseOn_Annex_UI",
		"ComponentMouseOn",
		true,
		function(context) OnComponentMouseOn_Annex_UI(context) end,
		true
	);
	cm:add_listener(
		"OnComponentLClickUp_Annex_UI",
		"ComponentLClickUp",
		true,
		function(context) OnComponentLClickUp_Annex_UI(context) end,
		true
	);
	cm:add_listener(
		"OnPanelOpenedCampaign_Annex_UI",
		"PanelOpenedCampaign",
		true,
		function(context) OnPanelOpenedCampaign_Annex_UI(context) end,
		true
	);
	cm:add_listener(
		"TimeTrigger_Annex_UI",
		"TimeTrigger",
		true,
		function(context) TimeTrigger_Annex_UI(context) end,
		true
	);

	if cm:is_new_game() then
		AnnexVassalsSetup();
	end
end

function AnnexVassalsSetup()
	local faction_list = cm:model():world():faction_list();

	for i = 0, faction_list:num_items() - 1 do
		local faction = faction_list:item_at(i);
		local faction_name = faction:name();

		FACTIONS_VASSALIZED_ANNEXING[faction_name] = false;

		if FACTIONS_VASSALIZED_ANNEXATION_TIME[faction_name] == nil then
			FACTIONS_VASSALIZED_ANNEXATION_TIME[faction_name] = -1;
		end

		if FACTIONS_TO_FACTIONS_VASSALIZED_START[faction_name] then
			for j = 1, #FACTIONS_TO_FACTIONS_VASSALIZED_START[faction_name] do
				local vassalized_faction_name = FACTIONS_TO_FACTIONS_VASSALIZED_START[faction_name][j];

				FACTIONS_VASSALIZED_ANNEXATION_TIME[vassalized_faction_name] = cm:model():world():faction_by_key(vassalized_faction_name):region_list():num_items() * ANNEX_TURNS_PER_REGION;
				FACTIONS_VASSALIZED_DELAYS[vassalized_faction_name] = ANNEX_TURN_REQUIREMENT;
			end
		end
	end
end

function FactionTurnStart_Annex(context)
	local turn = cm:model():turn_number();
	local actor = context:faction():name();
	if annex_turn_ledger[actor] == turn then return; end
	annex_turn_ledger[actor] = turn; -- Claim before any potentially partial handover.
	local claim_keys = MK1212_SaveSortedKeys(annex_handover_claims);
	for i = 1, #claim_keys do
		local claim = annex_handover_claims[claim_keys[i]];
		if claim.actor == actor then Annex_Observe_Claim(claim); end
	end
	local faction_name = context:faction():name();
	local faction_is_human = context:faction():is_human();

	if FACTIONS_TO_FACTIONS_VASSALIZED[faction_name] == nil then
		FACTIONS_TO_FACTIONS_VASSALIZED[faction_name] = {};
	end

	local delay_keys = MK1212_SaveSortedKeys(FACTIONS_VASSALIZED_DELAYS);
	for index = 1, #delay_keys do
		local k = delay_keys[index];
		local v = FACTIONS_VASSALIZED_DELAYS[k];
		if HasValue(FACTIONS_TO_FACTIONS_VASSALIZED[faction_name], k) then
			if v > 0 then
				FACTIONS_VASSALIZED_DELAYS[k] = v - 1;
			end
		end
	end

	-- Handover callbacks can remove entries from the live relation array. Iterate
	-- a captured byte-sorted list so one completed annexation cannot skip another.
	local vassal_keys = {};
	for i = 1, #FACTIONS_TO_FACTIONS_VASSALIZED[faction_name] do
		vassal_keys[i] = FACTIONS_TO_FACTIONS_VASSALIZED[faction_name][i];
	end
	table.sort(vassal_keys, MK1212_SaveByteLess);
	for i = 1, #vassal_keys do
		local vassalized_faction_name = vassal_keys[i];
		local vassal_faction = cm:model():world():faction_by_key(vassalized_faction_name);

		if FACTIONS_VASSALIZED_ANNEXATION_TIME[vassalized_faction_name] == nil or FACTIONS_VASSALIZED_ANNEXING[vassalized_faction_name] == false then
			FACTIONS_VASSALIZED_ANNEXATION_TIME[vassalized_faction_name] = vassal_faction:region_list():num_items() * ANNEX_TURNS_PER_REGION;
		end

		if FACTIONS_VASSALIZED_ANNEXING[vassalized_faction_name] == true then
			local annexation_turns_left = FACTIONS_VASSALIZED_ANNEXATION_TIME[vassalized_faction_name];

			if vassal_faction:has_home_region() == true then
				if annexation_turns_left > 0 then
					FACTIONS_VASSALIZED_ANNEXATION_TIME[vassalized_faction_name] = annexation_turns_left - 1;
				end

				if FACTIONS_VASSALIZED_ANNEXATION_TIME[vassalized_faction_name] == 0 then
					local claim = Annex_Claim_Handover(faction_name, vassalized_faction_name, vassal_faction);
					if claim then
						local applied = pcall(function()
							cm:grant_faction_handover(faction_name, vassalized_faction_name, cm:model():turn_number() - 1, cm:model():turn_number() - 1, context);

							if MKMP_Population_Is_Active and MKMP_Population_Is_Active() then
								local regions = context:faction():region_list();

								for i = 0, regions:num_items() - 1 do
									local region = regions:item_at(i);

									cm:apply_effect_bundle_to_region("mk_bundle_population_bundle_region", region:name(), 0);
								end

								Apply_Region_Economy_Factionwide(context:faction());
							end

							local faction_string = "factions_screen_name_"..vassalized_faction_name;

							if FACTIONS_DFN_LEVEL[vassalized_faction_name]  then
								if FACTIONS_DFN_LEVEL[vassalized_faction_name] > 1 then
									faction_string = "campaign_localised_strings_string_"..vassalized_faction_name.."_lvl"..tostring(FACTIONS_DFN_LEVEL[vassalized_faction_name]);
								end
							end

							cm:show_message_event(
								faction_name,
								"message_event_text_text_mk_event_annexed_vassal_title",
								faction_string,
								"message_event_text_text_mk_event_annexed_vassal_secondary",
								true,
								704
							);

							for i = 1, #FACTIONS_TO_FACTIONS_VASSALIZED[faction_name] do
								if FACTIONS_TO_FACTIONS_VASSALIZED[faction_name][i] == vassalized_faction_name then
									table.remove(FACTIONS_TO_FACTIONS_VASSALIZED[faction_name], i);
									break;
								end
							end

							Stop_Annexing_Vassal(faction_name, vassalized_faction_name);
						end);
						claim.phase = applied and "script_complete" or "uncertain";
						Annex_Claim_Log(claim, claim.phase);
						Annex_Observe_Claim(claim);
					end
				end
			else
				local faction_string = "factions_screen_name_"..vassalized_faction_name;

				if FACTIONS_DFN_LEVEL[vassalized_faction_name]  then
					if FACTIONS_DFN_LEVEL[vassalized_faction_name] > 1 then
						faction_string = "campaign_localised_strings_string_"..vassalized_faction_name.."_lvl"..tostring(FACTIONS_DFN_LEVEL[vassalized_faction_name]);
					end
				end

				cm:show_message_event(
					faction_name,
					"message_event_text_text_mk_event_annexation_aborted_title",
					faction_string,
					"message_event_text_text_mk_event_annexation_aborted_secondary",
					true,
					704
				);

				for i = 1, #FACTIONS_TO_FACTIONS_VASSALIZED[faction_name] do
					if FACTIONS_TO_FACTIONS_VASSALIZED[faction_name][i] == vassalized_faction_name then
						table.remove(FACTIONS_TO_FACTIONS_VASSALIZED[faction_name], i);
						break;
					end
				end

				Stop_Annexing_Vassal(faction_name, vassalized_faction_name);
			end
		elseif not faction_is_human and not vassal_faction:is_human() then
			if FACTIONS_VASSALIZED_DELAYS[vassalized_faction_name] == 0 and not Get_Vassal_Currently_Annexing(faction_name) then
				-- Todo: Add personality check?

				Start_Annexing_Vassal(faction_name, vassalized_faction_name);
			end
		end
	end
end

function FactionUnvassalized_Annex(context)
	local master_faction_name = context:faction():name();
	local vassalized_faction_name = context:other_faction():name();

	if FACTIONS_VASSALIZED_ANNEXING[vassalized_faction_name] == true then
		local faction_string = "factions_screen_name_"..vassalized_faction_name;

		if FACTIONS_DFN_LEVEL[vassalized_faction_name]  then
			if FACTIONS_DFN_LEVEL[vassalized_faction_name] > 1 then
				faction_string = "campaign_localised_strings_string_"..vassalized_faction_name.."_lvl"..tostring(FACTIONS_DFN_LEVEL[vassalized_faction_name]);
			end
		end

		if context:faction():is_human() then
			cm:show_message_event(
				master_faction_name,
				"message_event_text_text_mk_event_annexation_aborted_title",
				faction_string,
				"message_event_text_text_mk_event_annexation_aborted_secondary",
				true,
				704
			);
		end

		Stop_Annexing_Vassal(master_faction_name, vassalized_faction_name);
	else
		FACTIONS_VASSALIZED_DELAYS[vassalized_faction_name] = nil;
	end
end

function FactionVassalized_Annex(context)
	local master_faction_name = context:faction():name();
	local vassalized_faction_name = context:other_faction():name();

	FACTIONS_VASSALIZED_ANNEXING[vassalized_faction_name] = false;
	FACTIONS_VASSALIZED_ANNEXATION_TIME[vassalized_faction_name] = context:other_faction():region_list():num_items() * ANNEX_TURNS_PER_REGION;
	FACTIONS_VASSALIZED_DELAYS[vassalized_faction_name] = ANNEX_TURN_REQUIREMENT;
end

function OnComponentMouseOn_Annex_UI(context)
	if context.string == "button_annex_vassal" then
		local faction_name = cm:get_local_faction();
		local vassal_string = Get_DFN_Localisation(DIPLOMACY_SELECTED_FACTION);
		local cost = "n";
		local turns = "n";

		if HasValue(FACTIONS_TO_FACTIONS_VASSALIZED[faction_name], DIPLOMACY_SELECTED_FACTION) then
			if FACTIONS_VASSALIZED_ANNEXING[DIPLOMACY_SELECTED_FACTION] == false then
				for i = 1, #ANNEX_VASSALS_SIZES do
					if cm:model():world():faction_by_key(DIPLOMACY_SELECTED_FACTION):region_list():num_items() >= tonumber(ANNEX_VASSALS_SIZES[i]) then
						cost = ANNEX_VASSALS_PERCENTAGES[i];
						break;
					end
				end

				turns = FACTIONS_VASSALIZED_ANNEXATION_TIME[DIPLOMACY_SELECTED_FACTION];

				UIComponent(context.component):SetTooltipText(UI_LOCALISATION["annex_vassal_tooltip_pt1"]..vassal_string..UI_LOCALISATION["annex_vassal_tooltip_pt2"]..cost..UI_LOCALISATION["annex_vassal_tooltip_pt3"]..turns..UI_LOCALISATION["annex_vassal_tooltip_pt4"]);
			else
				UIComponent(context.component):SetTooltipText(UI_LOCALISATION["annex_vassal_annexing_tooltip_pt1"]..vassal_string..UI_LOCALISATION["annex_vassal_annexing_tooltip_pt2"]..FACTIONS_VASSALIZED_ANNEXATION_TIME[DIPLOMACY_SELECTED_FACTION]..UI_LOCALISATION["annex_vassal_annexing_tooltip_pt3"]);
			end
		else
			UIComponent(context.component):SetTooltipText(UI_LOCALISATION["annex_vassal_not_vassal_tooltip_pt1"]..vassal_string..UI_LOCALISATION["annex_vassal_not_vassal_tooltip_pt2"]);
		end
	elseif string.find(context.string, "mk_bundle_annex_vassal_regions_") then
		local vassalized_faction_name = Get_Vassal_Currently_Annexing(cm:get_local_faction());
		local root = cm:ui_root();
		local TechTooltipPopup = UIComponent(root:Find("TechTooltipPopup"));
		local description_window_uic = UIComponent(TechTooltipPopup:Find("description_window"));
		local vassal_string = Get_DFN_Localisation(vassalized_faction_name);

		description_window_uic:SetStateText(UI_LOCALISATION["annex_vassal_bundle_tooltip_pt1"]..vassal_string..UI_LOCALISATION["annex_vassal_bundle_tooltip_pt2"]..tostring(FACTIONS_VASSALIZED_ANNEXATION_TIME[vassalized_faction_name]));
	end
end

function OnComponentLClickUp_Annex_UI(context)
	if context.string == "button_annex_vassal" then
		local faction_name = cm:get_local_faction();

		local target = DIPLOMACY_SELECTED_FACTION;
		local mode = FACTIONS_VASSALIZED_ANNEXING[target] == true and "cancel" or "start";
		local accepted, reason = MKMP_Actions_Submit_Local("annex_vassal", faction_name,
			{target = target, mode = mode, turn = cm:model():turn_number()});
		if not accepted then
			MKMP_Actions_UI_Feedback(context.component, reason);
			return;
		end

		local vassal_string = Get_DFN_Localisation(DIPLOMACY_SELECTED_FACTION);
		local cost = "n";
		local turns = "n";

		if HasValue(FACTIONS_TO_FACTIONS_VASSALIZED[faction_name], DIPLOMACY_SELECTED_FACTION) then
			if FACTIONS_VASSALIZED_ANNEXING[DIPLOMACY_SELECTED_FACTION] == false then
				for i = 1, #ANNEX_VASSALS_SIZES do
					if cm:model():world():faction_by_key(DIPLOMACY_SELECTED_FACTION):region_list():num_items() >= tonumber(ANNEX_VASSALS_SIZES[i]) then
						cost = ANNEX_VASSALS_PERCENTAGES[i];
						break;
					end
				end

				turns = FACTIONS_VASSALIZED_ANNEXATION_TIME[DIPLOMACY_SELECTED_FACTION];

				UIComponent(context.component):SetStateText("");
				UIComponent(context.component):SetTooltipText(UI_LOCALISATION["annex_vassal_tooltip_pt1"]..vassal_string..UI_LOCALISATION["annex_vassal_tooltip_pt2"]..cost..UI_LOCALISATION["annex_vassal_tooltip_pt3"]..turns..UI_LOCALISATION["annex_vassal_tooltip_pt4"]);
			else
				UIComponent(context.component):SetStateText("");
				UIComponent(context.component):SetTooltipText(UI_LOCALISATION["annex_vassal_annexing_tooltip_pt1"]..vassal_string..UI_LOCALISATION["annex_vassal_annexing_tooltip_pt2"]..FACTIONS_VASSALIZED_ANNEXATION_TIME[DIPLOMACY_SELECTED_FACTION]..UI_LOCALISATION["annex_vassal_annexing_tooltip_pt3"]);
			end
		else
			UIComponent(context.component):SetStateText("");
			UIComponent(context.component):SetTooltipText(UI_LOCALISATION["annex_vassal_not_vassal_tooltip_pt1"]..vassal_string..UI_LOCALISATION["annex_vassal_not_vassal_tooltip_pt2"]);
		end
	elseif DIPLOMACY_PANEL_OPEN == true then
		if context.string == "map" or context.string == "button_icon" or context.string == "flag" or string.find(context.string, "faction_row_entry_") then
			local root = cm:ui_root();
			local diplomacy_dropdown_uic = UIComponent(root:Find("diplomacy_dropdown"));
			local button_annex_vassal_uic = UIComponent(diplomacy_dropdown_uic:Find("button_annex_vassal"));

			button_annex_vassal_uic:SetStateText("");
			button_annex_vassal_uic:SetState("inactive");

			cm:add_time_trigger("annex_diplo_hud_check", 0.1);
		end
	end
end

function OnPanelOpenedCampaign_Annex_UI(context)
	if context.string == "diplomacy_dropdown" then
		cm:add_time_trigger("annex_diplo_hud_check", 0.1);
	end
end

function TimeTrigger_Annex_UI(context)
	if context.string == "annex_diplo_hud_check" then
		local root = cm:ui_root();
		local diplomacy_dropdown_uic = UIComponent(root:Find("diplomacy_dropdown"));
		local button_annex_vassal_uic = UIComponent(diplomacy_dropdown_uic:Find("button_annex_vassal"));
		--local faction_left_status_panel_uic = UIComponent(diplomacy_dropdown_uic:Find("faction_left_status_panel"));
		--local diplomatic_relations_uic = UIComponent(faction_left_status_panel_uic:Find("diplomatic_relations"));
		--local icon_vassals_uic = UIComponent( diplomatic_relations_uic:Find("icon_vassals"));
	
		local annexing_faction = Get_Vassal_Currently_Annexing(cm:get_local_faction());

		button_annex_vassal_uic:SetState("inactive");
		button_annex_vassal_uic:SetVisible(true);

		if not annexing_faction or annexing_faction == DIPLOMACY_SELECTED_FACTION then
			if FACTIONS_VASSALIZED_ANNEXING[DIPLOMACY_SELECTED_FACTION] == false then
				if HasValue(FACTIONS_TO_FACTIONS_VASSALIZED[cm:get_local_faction()], DIPLOMACY_SELECTED_FACTION) then
					DIPLOMACY_SELECTED_FACTION = DIPLOMACY_SELECTED_FACTION;
		
					if FACTIONS_VASSALIZED_DELAYS[DIPLOMACY_SELECTED_FACTION] == 0 then
						button_annex_vassal_uic:SetState("active"); 
					else
						button_annex_vassal_uic:SetStateText(tostring(FACTIONS_VASSALIZED_DELAYS[DIPLOMACY_SELECTED_FACTION]));
					end
				end
			elseif HasValue(FACTIONS_TO_FACTIONS_VASSALIZED[cm:get_local_faction()], DIPLOMACY_SELECTED_FACTION) then
				button_annex_vassal_uic:SetState("active");
			end
		end

		-- (Doesn't work) Having a true vassal (i.e. one released using the buffer state mechanic) will overwrite client states on the UI, so we need to fix that.
		--[[if icon_vassals_uic:CurrentState() == "vassal" then
			icon_vassals_uic:SetState("client_state");
		end]]--
	end
end

function MKMP_Annex_Validate(actor, payload)
	if type(payload.target) ~= "string" or payload.target == actor or payload.turn ~= cm:model():turn_number()
		or (payload.mode ~= "start" and payload.mode ~= "cancel") then return false, "annex_arguments"; end
	local world = cm:model():world();
	local master, vassal = world:faction_by_key(actor), world:faction_by_key(payload.target);
	if not master or master:is_null_interface() or not vassal or vassal:is_null_interface()
		or not vassal:has_home_region() or not HasValue(FACTIONS_TO_FACTIONS_VASSALIZED[actor] or {}, payload.target) then
		return false, "annex_relation_changed";
	end
	if payload.mode == "cancel" then return FACTIONS_VASSALIZED_ANNEXING[payload.target] == true, "annex_not_active"; end
	local prior = annex_handover_claims[payload.target];
	if prior and prior.phase ~= "ownership_observed" then return false, "annex_handover_uncertain"; end
	return FACTIONS_VASSALIZED_DELAYS[payload.target] == 0
		and FACTIONS_VASSALIZED_ANNEXING[payload.target] ~= true
		and not Get_Vassal_Currently_Annexing(actor), "annex_not_available";
end

function MKMP_Annex_Execute(actor, payload)
	if payload.mode == "start" then Start_Annexing_Vassal(actor, payload.target);
	else Stop_Annexing_Vassal(actor, payload.target); end
	if FACTIONS_VASSALIZED_ANNEXING[payload.target] ~= (payload.mode == "start") then return false, "annex_flags_unconfirmed"; end
	return true, "script_complete"; -- Local bookkeeping only; not native bundle confirmation.
end

function MKMP_Annex_Get_State()
	return MKMP_Diagnostic_Copy({schema = 1, enabled = annex_initialized,
		active = FACTIONS_VASSALIZED_ANNEXING, remaining = FACTIONS_VASSALIZED_ANNEXATION_TIME,
		delays = FACTIONS_VASSALIZED_DELAYS, turns = annex_turn_ledger, handovers = annex_handover_claims}), "complete";
end

function Start_Annexing_Vassal(master_faction_name, vassalized_faction_name)
	if not Get_Vassal_Currently_Annexing(master_faction_name) then
		local vassal = cm:model():world():faction_by_key(vassalized_faction_name);
		if not vassal or vassal:is_null_interface() or not vassal:has_home_region() then return false; end
		local prior = annex_handover_claims[vassalized_faction_name];
		if prior then
			if prior.phase ~= "ownership_observed" then return false; end
			-- A later validated annexation cycle may replace a completed claim.
			-- Uncertain native work is never cleared by a turn or duplicate event.
			annex_handover_claims[vassalized_faction_name] = nil;
		end
		FACTIONS_VASSALIZED_ANNEXING[vassalized_faction_name] = true;

		for i = 1, #ANNEX_VASSALS_SIZES do
			if cm:model():world():faction_by_key(vassalized_faction_name):region_list():num_items() >= tonumber(ANNEX_VASSALS_SIZES[i]) then
				cm:apply_effect_bundle("mk_bundle_annex_vassal_regions_"..ANNEX_VASSALS_SIZES[i], master_faction_name, 0);
				break;
			end
		end
	end
end

function Stop_Annexing_Vassal(master_faction_name, vassalized_faction_name)
	FACTIONS_VASSALIZED_ANNEXING[vassalized_faction_name] = false;

	if FactionIsAlive(vassalized_faction_name) then
		FACTIONS_VASSALIZED_ANNEXATION_TIME[vassalized_faction_name] = cm:model():world():faction_by_key(vassalized_faction_name):region_list():num_items() * ANNEX_TURNS_PER_REGION;
	else
		FACTIONS_VASSALIZED_ANNEXATION_TIME[vassalized_faction_name] = -1;
	end

	for i = 1, #ANNEX_VASSALS_SIZES do
		cm:remove_effect_bundle("mk_bundle_annex_vassal_regions_"..ANNEX_VASSALS_SIZES[i], master_faction_name);
	end
end

function Get_Vassal_Currently_Annexing(faction_name)
	if FACTIONS_TO_FACTIONS_VASSALIZED[faction_name] == nil then return; end

	for i = 1, #FACTIONS_TO_FACTIONS_VASSALIZED[faction_name] do
		local vassalized_faction_name = FACTIONS_TO_FACTIONS_VASSALIZED[faction_name][i];

		if FACTIONS_VASSALIZED_ANNEXING[vassalized_faction_name] == true then
			return vassalized_faction_name;
		end
	end
end

------------------------------------------------
---------------- Saving/Loading ----------------
------------------------------------------------
cm:register_loading_game_callback(
	function(context)
		local schema = cm:load_value("MKMP_ANNEX_TURNS_VERSION", 0, context);
		if schema ~= 0 and schema ~= 1 then error("MK1212 load refused: annex turn version"); end
		local active = LoadBooleanPairTable(context, "FACTIONS_VASSALIZED_ANNEXING");
		local remaining = LoadKeyPairTableNumbers(context, "FACTIONS_VASSALIZED_ANNEXATION_TIME");
		local delays = LoadKeyPairTableNumbers(context, "FACTIONS_VASSALIZED_DELAYS");
		local turns = LoadKeyPairTableNumbers(context, "MKMP_ANNEX_TURNS");
		local claim_version = cm:load_value(ANNEX_HANDOVER_KEY.."_VERSION", 0, context);
		local raw = cm:load_value(ANNEX_HANDOVER_KEY, "", context);
		local outer = cm:load_value(ANNEX_HANDOVER_KEY.."__schema", 0, context);
		local claims = {};
		if claim_version == 0 and raw == "" and outer == 0 then
			-- Legacy saves contain no evidence of an in-flight handover.
		elseif claim_version == 1 and outer == 3 and type(raw) == "string" and raw ~= "" then
			local rows = MK1212_LoadSaveRows(context, ANNEX_HANDOVER_KEY);
			if #rows > ANNEX_MAX_HANDOVERS then error("annex handover claim budget"); end
			for i = 1, #rows do
				local row = rows[i];
				if #row < 5 or #row > ANNEX_MAX_REGIONS + 4 or claims[row[1]] then error("invalid annex handover row"); end
				local regions = {};
				for j = 5, #row do regions[#regions + 1] = row[j]; end
				claims[row[1]] = {target = row[1], actor = row[2], turn = MK1212_SaveNumber(row[3], ANNEX_HANDOVER_KEY),
					phase = row[4], regions = regions};
			end
			Annex_Serialize_Claims(claims); -- Full snapshot validation before any swap.
		else
			error("MK1212 load refused: annex handover schema");
		end
		local keys = MK1212_SaveSortedKeys(turns);
		for i = 1, #keys do
			local turn = turns[keys[i]];
			if turn < 0 or turn > cm:model():turn_number() or turn ~= math.floor(turn) then error("invalid annex turn"); end
		end
		FACTIONS_VASSALIZED_ANNEXING, FACTIONS_VASSALIZED_ANNEXATION_TIME = active, remaining;
		FACTIONS_VASSALIZED_DELAYS, annex_turn_ledger = delays, turns;
		annex_handover_claims = claims;
	end
);

cm:register_saving_game_callback(
	function(context)
		local claims, count = Annex_Serialize_Claims(annex_handover_claims);
		SaveBooleanPairTable(context, FACTIONS_VASSALIZED_ANNEXING, "FACTIONS_VASSALIZED_ANNEXING");
		SaveKeyPairTable(context, FACTIONS_VASSALIZED_ANNEXATION_TIME, "FACTIONS_VASSALIZED_ANNEXATION_TIME");
		SaveKeyPairTable(context, FACTIONS_VASSALIZED_DELAYS, "FACTIONS_VASSALIZED_DELAYS");
		SaveKeyPairTable(context, annex_turn_ledger, "MKMP_ANNEX_TURNS");
		cm:save_value("MKMP_ANNEX_TURNS_VERSION", 1, context);
		MK1212_SaveCommitString(context, ANNEX_HANDOVER_KEY, claims, count);
		cm:save_value(ANNEX_HANDOVER_KEY.."_VERSION", 1, context);
	end
);
