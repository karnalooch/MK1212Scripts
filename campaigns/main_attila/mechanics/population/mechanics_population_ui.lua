---------------------------------------------------------------------------------------------------------------------
---------------------------------------------------------------------------------------------------------------------
--
-- 	MEDIEVAL KINGDOMS 1212 - MECHANICS: POPULATION UI
-- 	By: DETrooper
--
---------------------------------------------------------------------------------------------------------------------
---------------------------------------------------------------------------------------------------------------------

local button_disband_pressed = false;
local captured_disband = nil;
local captured_commander = nil;

POPULATION_COMMANDER_TO_REPLACE_CQI = 0;
POPULATION_CURRENT_TOOLTIP_SELECTED = 0;

function Add_Population_UI_Listeners()
	cm:add_listener(
		"FactionTurnEnd_Population_UI",
		"FactionTurnEnd",
		true,
		function(context) FactionTurnEnd_Population_UI(context) end,
		true
	);
	cm:add_listener(
		"OnComponentMouseOn_Population_UI",
		"ComponentMouseOn",
		true,
		function(context) OnComponentMouseOn_Population_UI(context) end,
		true
	);
	cm:add_listener(
		"OnComponentLClickUp_Population_UI",
		"ComponentLClickUp",
		true,
		function(context) OnComponentLClickUp_Population_UI(context) end,
		true
	);
	cm:add_listener(
		"OnPanelOpenedCampaign_Population_UI",
		"PanelOpenedCampaign",
		true,
		function(context) OnPanelOpenedCampaign_Population_UI(context) end,
		true
	);
	cm:add_listener(
		"ShortcutTriggered_Population_UI",
		"ShortcutTriggered",
		true,
		function(context) ShortcutTriggered_Population_UI(context) end,
		true
	);
	cm:add_listener(
		"TimeTrigger_Population_UI",
		"TimeTrigger",
		true,
		function(context) TimeTrigger_Population_UI(context) end,
		true
	);

	if cm:is_new_game() then
		local faction_list = cm:model():world():faction_list();

		for i = 0, faction_list:num_items() - 1 do
			local current_faction = faction_list:item_at(i);

			if current_faction:is_horde() == false and current_faction:region_list():num_items() > 0 then
				local regions = current_faction:region_list();

				for j = 0, regions:num_items() - 1 do
					local region = regions:item_at(j);
					cm:apply_effect_bundle_to_region("mk_bundle_population_bundle_region", region:name(), 0);
				end
			end
		end
	end
end

function FactionTurnEnd_Population_UI(context)
	if context:faction():is_human() then
		POPULATION_CURRENT_TOOLTIP_SELECTED = 0;
	end
end

function Population_UI_Get_Growth(region_name, class)
	local population = POPULATION_REGIONS_POPULATIONS[region_name][class];
	local growth = POPULATION_REGIONS_GROWTH_RATES[region_name][class];
	local color = "[[rgba:8:201:27:150]]";
	local symbol = "+";

	growth = growth * 100; -- Multiply it for the UI by 100 so it shows as the correct percentage for addition/subtraction, rather than what the population # is being multiplied/divided by.

	if growth == 0 or (growth < 0 and population == 0) then
		growth = 0;
		color = "[[rgba:255:255:0:150]]";
		symbol = "";
	elseif growth < 0 then
		color = "[[rgba:255:0:0:150]]";
		symbol = "";

		growth = Round_Number_Text(growth);
	else
		growth = Round_Number_Text(growth);
	end

	return color.."("..symbol..growth.."%)".."[[/rgba]]";
end


function Population_UI_Get_Growth_Factor(growth)
	local color = "[[rgba:8:201:27:150]]";
	local symbol = "+";

	growth = growth * 100; -- Multiply it for the UI by 100 so it shows as the correct percentage for addition/subtraction, rather than what the population # is being multiplied/divided by.

	if growth == 0 or (growth < 0 and population == 0) then
		growth = 0;
		color = "[[rgba:255:255:0:150]]";
		symbol = "";
	elseif growth < 0 then
		color = "[[rgba:255:0:0:150]]";
		symbol = "";

		growth = Round_Number_Text(growth);
	else
		growth = Round_Number_Text(growth);
	end

	return "\nProjected Growth: "..color.."("..symbol..growth.."%)".."[[/rgba]]";
end

function OnComponentMouseOn_Population_UI(context)
	if string.find(context.string, "effect_bundle") then
		local root = cm:ui_root();
		local TechTooltipPopup = UIComponent(root:Find("TechTooltipPopup"));
		local instruction_window_uic = UIComponent(TechTooltipPopup:Find("dy_building_title"));

		if instruction_window_uic:GetStateText() == "Population of" then
			Change_Tooltip_Population_UI(REGION_SELECTED, POPULATION_CURRENT_TOOLTIP_SELECTED, true);
		end
	elseif context.string == "mk_bundle_population_bundle_region" then
		local root = cm:ui_root();
		local TechTooltipPopup = UIComponent(root:Find("TechTooltipPopup"));
		local instruction_window_uic = UIComponent(TechTooltipPopup:Find("dy_building_title"));

		Change_Tooltip_Population_UI(REGION_SELECTED, POPULATION_CURRENT_TOOLTIP_SELECTED, false);
	elseif string.find(context.string, "_recruitable") then
		local root = cm:ui_root();
		local unit_name = string.gsub(context.string, "_recruitable", "");
		local unit_population_table = POPULATION_UNITS_TO_POPULATION[unit_name];

		if unit_population_table then
			local unit_class = unit_population_table[2];
			local unit_class_string = POPULATIONS_CLASSES_STRINGS[unit_class];

			if unit_class_string then
				local splitstr = SplitString(UIComponent(context.component):GetTooltipText(), "\n");
				local oldToolTip = splitstr[1];
				local newToolTip = "";

				if not LAST_CHARACTER_SELECTED:faction():is_horde() then
					local region_name = LAST_CHARACTER_SELECTED:region():name();
					newToolTip = "Available "..unit_class_string.." manpower in "..REGIONS_NAMES_LOCALISATION[region_name]..": "..tostring(POPULATION_REGIONS_MANPOWER[region_name][unit_class]).."\nManpower Cost: "..unit_population_table[1];

					UIComponent(context.component):SetTooltipText(string.gsub(oldToolTip, "\n\n"..newToolTip, "").."\n\n"..newToolTip.."\n\n"..subRecruitableUnit);
				else
					UIComponent(context.component):SetTooltipText(oldToolTip.."\n\n"..subRecruitableUnit);
				end
			end	
		end
	elseif string.find(context.string, "QueuedLandUnit") then
		local queue_number = string.gsub(context.string, "QueuedLandUnit ", "");

		queue_number = tonumber(queue_number) + 1;

		local unit_name = POPULATION_UNITS_IN_RECRUITMENT[tostring(LAST_CHARACTER_SELECTED:cqi())][queue_number];
		local unit_population_table = POPULATION_UNITS_TO_POPULATION[unit_name];

		if unit_population_table then
			local unit_class = unit_population_table[2];
			local unit_class_string = POPULATIONS_CLASSES_STRINGS[unit_class];

			if unit_class_string then
				local newToolTip = "Left-click to remove this unit from the recruitment queue.";
				
				if not LAST_CHARACTER_SELECTED:faction():is_horde() then
					local region_name = LAST_CHARACTER_SELECTED:region():name();
					newToolTip = "Left-click to remove this unit from the recruitment queue.\n\nThis will refund "..unit_population_table[1].." "..unit_class_string.." manpower in "..REGIONS_NAMES_LOCALISATION[region_name]..".";
				end

				UIComponent(context.component):SetTooltipText(newToolTip);
			end
		end
	elseif string.find(context.string, "LandUnit") then
		local unit_card_uic = UIComponent(context.component);
		local merc_icon_uic = UIComponent(unit_card_uic:Find("merc_icon"));
		local strength_number = UIComponent(unit_card_uic:Find("unit_strength_number")):GetStateText();
		local splitstr = SplitString(UIComponent(context.component):GetTooltipText(), "||");
		local oldToolTip = splitstr[1];
		local queue_number = string.gsub(context.string, "LandUnit ", "");

		if tonumber(queue_number) > 0 and merc_icon_uic:Visible() == false and LAST_CHARACTER_SELECTED:faction():is_horde() == false then
			local newToolTip = oldToolTip.."\n\nUsed Manpower: "..strength_number.."\n\nLeft-click to select.";
			UIComponent(context.component):SetTooltipText(newToolTip);
		else
			local newToolTip = oldToolTip.."\n\nLeft-click to select.";
			UIComponent(context.component):SetTooltipText(newToolTip);
		end
	end
end

function OnComponentLClickUp_Population_UI(context)
	if string.find(context.string, "effect_bundle") then
		local root = cm:ui_root();
		local TechTooltipPopup = UIComponent(root:Find("TechTooltipPopup"));
		local instruction_window_uic = UIComponent(TechTooltipPopup:Find("dy_building_title"));

		if instruction_window_uic:GetStateText() == "Population of" or string.find(instruction_window_uic:GetStateText(), REGIONS_NAMES_LOCALISATION[REGION_SELECTED]) then
			if POPULATION_CURRENT_TOOLTIP_SELECTED < 5 then
				POPULATION_CURRENT_TOOLTIP_SELECTED = POPULATION_CURRENT_TOOLTIP_SELECTED + 1;
			else
				POPULATION_CURRENT_TOOLTIP_SELECTED = 0;
			end

			Change_Tooltip_Population_UI(REGION_SELECTED, POPULATION_CURRENT_TOOLTIP_SELECTED, true);
		end
	elseif context.string == "mk_bundle_population_bundle_region" then
		local root = cm:ui_root();
		local TechTooltipPopup = UIComponent(root:Find("TechTooltipPopup"));
		local instruction_window_uic = UIComponent(TechTooltipPopup:Find("dy_building_title"));

		if POPULATION_CURRENT_TOOLTIP_SELECTED < 5 then
			POPULATION_CURRENT_TOOLTIP_SELECTED = POPULATION_CURRENT_TOOLTIP_SELECTED + 1;
		else
			POPULATION_CURRENT_TOOLTIP_SELECTED = 0;
		end

		Change_Tooltip_Population_UI(REGION_SELECTED, POPULATION_CURRENT_TOOLTIP_SELECTED, false);
	elseif string.find(context.string, "_recruitable") then
		local unit_name = string.gsub(context.string, "_recruitable", "");
		if POPULATION_UNITS_TO_POPULATION[unit_name] and UIComponent(context.component):CurrentState() == "active" then
			local payload = MKMP_Population_Capture_Recruit(LAST_CHARACTER_SELECTED, unit_name);
			if payload then
				local accepted, reason = MKMP_Actions_Submit_Local("population_recruit", payload.actor, payload);
				if not accepted then MKMP_Actions_UI_Feedback(context.component, reason); end
			end
			UIComponent(context.component):SetDisabled(true);
			cm:add_time_trigger("Unit_Cards", 0.0);
		end
	elseif string.find(context.string, "QueuedLandUnit") then
		local value = string.match(context.string, "^QueuedLandUnit (%d+)$");
		local slot = value and tonumber(value) + 1;
		local payload = slot and MKMP_Population_Capture_Cancel(LAST_CHARACTER_SELECTED, slot);
		if payload then
			local accepted, reason = MKMP_Actions_Submit_Local("population_cancel", payload.actor, payload);
			if not accepted then MKMP_Actions_UI_Feedback(context.component, reason); end
		end
	elseif string.find(context.string, "LandUnit") then
		local unit_card_uic = UIComponent(context.component);
		local merc_icon_uic = UIComponent(unit_card_uic:Find("merc_icon"));
		local strength_number = UIComponent(unit_card_uic:Find("unit_strength_number")):GetStateText();
		local splitstr = SplitString(UIComponent(context.component):GetTooltipText(), "||");
		local oldToolTip = splitstr[1];
		local queue_number = string.gsub(context.string, "LandUnit ", "");

		if tonumber(queue_number) > 0 and merc_icon_uic:Visible() == false and LAST_CHARACTER_SELECTED:faction():is_horde() == false then
			local newToolTip = oldToolTip.."\n\nUsed Manpower: "..strength_number.."\n\nLeft-click to select.";
			UIComponent(context.component):SetTooltipText(newToolTip);
		else
			local newToolTip = oldToolTip.."\n\nLeft-click to select.";
			UIComponent(context.component):SetTooltipText(newToolTip);
		end
	elseif context.string == "button_tick" then
		if UIComponent(context.component):GetTooltipText() == "Accept" and button_disband_pressed == true then
			local payload = captured_disband;
			captured_disband, button_disband_pressed = nil, false;
			if payload then
				local accepted, reason = MKMP_Actions_Submit_Local("population_force", payload.actor, payload);
				if not accepted then MKMP_Actions_UI_Feedback(context.component, reason); end
			end
		elseif UIComponent(context.component):GetTooltipText() == "Cancel" and button_disband_pressed == true then
			captured_disband, button_disband_pressed = nil, false;
		end
	elseif context.string == "button_replace_general" then
		captured_commander = MKMP_Population_Capture_Force(LAST_CHARACTER_SELECTED, "commander");
	elseif context.string == "button_accept_general" then
		local payload = captured_commander;
		captured_commander = nil;
		if payload then
			local accepted, reason = MKMP_Actions_Submit_Local("population_force", payload.actor, payload);
			if not accepted then MKMP_Actions_UI_Feedback(context.component, reason); end
		end
	elseif context.string == "Summary" or context.string == "Records" then
		cm:add_time_trigger("Faction_Panel_Population", 0.0);
	end

	if context.string == "button_disband" then
		captured_disband = MKMP_Population_Capture_Force(LAST_CHARACTER_SELECTED, "disband");
		button_disband_pressed = captured_disband ~= nil;
	end
end

function OnPanelOpenedCampaign_Population_UI(context)
	if context.string == "units_recruitment" then
		cm:add_time_trigger("Unit_Cards", 0.0);
	elseif context.string == "clan" then
		cm:add_time_trigger("Faction_Panel_Population", 0.0);
	end
end

function ShortcutTriggered_Population_UI(context)
	if context.string == "auto_merge_units" then
		local payload = MKMP_Population_Capture_Force(LAST_CHARACTER_SELECTED, "merge");
		if payload then MKMP_Actions_Submit_Local("population_force", payload.actor, payload); end
	elseif context.string == "current_selection_disband" then
		captured_disband = MKMP_Population_Capture_Force(LAST_CHARACTER_SELECTED, "disband");
		button_disband_pressed = captured_disband ~= nil;
	end
end

function TimeTrigger_Population_UI(context)
	if MKMP_Population_Observe_Timer(context) then return; end
	if context.string == "Unit_Cards" then
		local root = cm:ui_root();
		local recuitment_list_uic = UIComponent(root:Find("recuitment_list"));
		local list_box_uic = UIComponent(recuitment_list_uic:Find("list_box"));		

		for i = 0, list_box_uic:ChildCount() - 1 do
			local unit_uic = UIComponent(list_box_uic:Find(i));
			local unit_name = UIComponent(list_box_uic:Find(i)):Id();

			if string.find(unit_name, "_recruitable") then
				unit_name = string.gsub(unit_name, "_recruitable", "");

				if not LAST_CHARACTER_SELECTED:faction():is_horde() then
					local unit_population_table = POPULATION_UNITS_TO_POPULATION[unit_name];

					if unit_population_table then
						if POPULATION_REGIONS_MANPOWER[LAST_CHARACTER_SELECTED:region():name()][unit_population_table[2]] < unit_population_table[1] then
							local unit_icon_uic = UIComponent(unit_uic:Find("unit_icon"));
							unit_uic:SetDisabled(true);
							unit_icon_uic:SetState("inactive");
						end
					end
				end
			end 
		end
	elseif context.string == "Check_Disbanded_Units" or context.string == "Update_Force_CQI" then
		-- Old uncorrelated timers cannot use current selection as an action target.
		return;
	elseif context.string == "Faction_Panel_Population" then
		local root = cm:ui_root();
		local tab_records_uic = UIComponent(root:Find("Records"));
		local tab_summary_uic = UIComponent(root:Find("Summary"));
		local details_list_uic = UIComponent(tab_summary_uic:Find("details_list"))
		local tx_population_uic = UIComponent(details_list_uic:Find("tx_population2"));
		local dy_population_uic = UIComponent(tx_population_uic:Find("dy_population2"));
		local tx_provinces_owned_uic = UIComponent(tab_records_uic:Find("tx_provinces_owned"));
		local dy_provinces_owned_uic = UIComponent(tx_provinces_owned_uic:Find("dy_provinces_owned"));

		tx_provinces_owned_uic:SetStateText(UI_LOCALISATION["population_prefix_no_space"]);
		dy_provinces_owned_uic:SetStateText(tostring(POPULATION_FACTION_TOTAL_POPULATIONS[cm:get_local_faction()]));
		dy_population_uic:SetStateText(tostring(POPULATION_FACTION_TOTAL_POPULATIONS[cm:get_local_faction()]));
	end
end

function Change_Tooltip_Population_UI(key, class, own_region)
	local root = cm:ui_root();
	local TechTooltipPopup = UIComponent(root:Find("TechTooltipPopup"));
	local instruction_window_uic = UIComponent(TechTooltipPopup:Find("dy_building_title"));
	local description_window_uic = UIComponent(TechTooltipPopup:Find("description_window"));
	local nobility_uic = UIComponent(TechTooltipPopup:Find("building_info_generic_entry0"));
	nobility_dy_uic = UIComponent(nobility_uic:Find("description_dy"));
	local artisans_uic = UIComponent(TechTooltipPopup:Find("building_info_generic_entry1"));
	artisans_dy_uic = UIComponent(artisans_uic:Find("description_dy"));
	local peasantry_uic = UIComponent(TechTooltipPopup:Find("building_info_generic_entry2"));
	peasantry_dy_uic = UIComponent(peasantry_uic:Find("description_dy"));
	local tribesmen_uic = UIComponent(TechTooltipPopup:Find("building_info_generic_entry3"));
	tribesmen_dy_uic = UIComponent(tribesmen_uic:Find("description_dy"));
	local foreigners_uic = UIComponent(TechTooltipPopup:Find("building_info_generic_entry4"));
	foreigners_dy_uic = UIComponent(foreigners_uic:Find("description_dy"));
	local available_manpower_str = UI_LOCALISATION["population_available_manpower"];

	if class == 0 then
		instruction_window_uic:SetStateText(UI_LOCALISATION["population_of_prefix"]..REGIONS_NAMES_LOCALISATION[key]);

		if own_region == true then
			description_window_uic:SetStateText(UI_LOCALISATION["total_population_prefix"]..tostring(POPULATION_REGIONS_POPULATIONS[key][1] + POPULATION_REGIONS_POPULATIONS[key][2] + POPULATION_REGIONS_POPULATIONS[key][3] + POPULATION_REGIONS_POPULATIONS[key][4] + POPULATION_REGIONS_POPULATIONS[key][5]).."\n\nLeft-click to cycle through growth details.");
			description_window_uic:Resize(340, 64);
		else
			description_window_uic:SetStateText(UI_LOCALISATION["total_population_prefix"]..tostring(POPULATION_REGIONS_POPULATIONS[key][1] + POPULATION_REGIONS_POPULATIONS[key][2] + POPULATION_REGIONS_POPULATIONS[key][3] + POPULATION_REGIONS_POPULATIONS[key][4] + POPULATION_REGIONS_POPULATIONS[key][5]));
			description_window_uic:Resize(340, 32);
		end

		description_window_uic:Resize(340, 64);
		nobility_dy_uic:SetStateText(POPULATIONS_CLASSES_TITLE_STRINGS[1]..": "..POPULATION_REGIONS_POPULATIONS[key][1].." "..Population_UI_Get_Growth(key, 1)..available_manpower_str..POPULATION_REGIONS_MANPOWER[key][1]);
		artisans_dy_uic:SetStateText(POPULATIONS_CLASSES_TITLE_STRINGS[2]..": "..POPULATION_REGIONS_POPULATIONS[key][2].." "..Population_UI_Get_Growth(key, 2)..available_manpower_str..POPULATION_REGIONS_MANPOWER[key][2]);
		peasantry_dy_uic:SetStateText(POPULATIONS_CLASSES_TITLE_STRINGS[3]..": "..POPULATION_REGIONS_POPULATIONS[key][3].." "..Population_UI_Get_Growth(key, 3)..available_manpower_str..POPULATION_REGIONS_MANPOWER[key][3]);
		tribesmen_dy_uic:SetStateText(POPULATIONS_CLASSES_TITLE_STRINGS[4]..": "..POPULATION_REGIONS_POPULATIONS[key][4].." "..Population_UI_Get_Growth(key, 4)..available_manpower_str..POPULATION_REGIONS_MANPOWER[key][4]);
		foreigners_dy_uic:SetStateText(POPULATIONS_CLASSES_TITLE_STRINGS[5]..": "..POPULATION_REGIONS_POPULATIONS[key][5].." "..Population_UI_Get_Growth(key, 5)..available_manpower_str..POPULATION_REGIONS_MANPOWER[key][5]);

		nobility_uic:SetVisible(true);
		artisans_uic:SetVisible(true);
		peasantry_uic:SetVisible(true);
		tribesmen_uic:SetVisible(true);
		foreigners_uic:SetVisible(true);
	elseif class ~= 0 then
		instruction_window_uic:SetStateText(POPULATIONS_CLASSES_TITLE_STRINGS[class]..UI_LOCALISATION["of"]..REGIONS_NAMES_LOCALISATION[key]..UI_LOCALISATION["population_growth_factors"]);
		description_window_uic:Resize(340, 300);

		local class_population = "Class Population: "..tostring(POPULATION_REGIONS_POPULATIONS[key][class].."\n\n");
		local projected_growth = "\nProjected Growth Rate: "..Population_UI_Get_Growth(key, class);
		local projected_growth_num = "";
		local class_string = POPULATIONS_CLASSES_PLURAL_STRINGS[class];

		if math.ceil(POPULATION_REGIONS_POPULATIONS[key][class] * POPULATION_REGIONS_GROWTH_RATES[key][class]) == 1 then
			class_string = POPULATIONS_CLASSES_STRINGS[class];
		end

		if math.ceil(POPULATION_REGIONS_POPULATIONS[key][class] * POPULATION_REGIONS_GROWTH_RATES[key][class]) < 0 then
			projected_growth_num = "\nProjected Growth: [[rgba:255:0:0:150]]"..tostring(math.ceil(POPULATION_REGIONS_POPULATIONS[key][class] * POPULATION_REGIONS_GROWTH_RATES[key][class])).."[[/rgba]] "..class_string;
		elseif math.ceil(POPULATION_REGIONS_POPULATIONS[key][class] * POPULATION_REGIONS_GROWTH_RATES[key][class]) == 0 then
			if POPULATION_REGIONS_GROWTH_RATES[key][class] == 0 or POPULATION_REGIONS_GROWTH_RATES[key][class] < 0 then
				projected_growth_num = "\nProjected Growth: [[rgba:255:255:0:150]]0[[/rgba]] "..class_string;
			elseif POPULATION_REGIONS_GROWTH_RATES[key][class] > 0 then
				projected_growth_num = "\nProjected Growth: [[rgba:8:201:27:150]]+1[[/rgba]] "..POPULATIONS_CLASSES_STRINGS[class];
			end
		else
			projected_growth_num = "\nProjected Growth: [[rgba:8:201:27:150]]+"..tostring(math.ceil(POPULATION_REGIONS_POPULATIONS[key][class] * POPULATION_REGIONS_GROWTH_RATES[key][class])).."[[/rgba]] "..class_string;
		end

		-- May or may not exist.
		local faction_trait_growth = "";
		local building_growth = "";
		local technology_growth = "";
		local capital_bonus = "";
		local imperial_decree = "";
		local cap_exceeded = "";
		local under_siege = "";
		local food_shortage = "";
		local region_raided = "";

		if POPULATION_REGIONS_GROWTH_FACTORS[key] ~= "" then
			local first_split = SplitString(POPULATION_REGIONS_GROWTH_FACTORS[key], "@");

			for i = 1, #first_split do
				local second_split = SplitString(first_split[i], "#");

				if second_split[1] == "faction_trait_"..tostring(class) then
					second_split[2] = Round_Number_Text(second_split[2]);

					if tonumber(second_split[2]) < 0 then
						faction_trait_growth = "Growth From Faction Trait: ".."[[rgba:255:0:0:150]]("..second_split[2].."%)[[/rgba]]\n";
					elseif tonumber(second_split[2]) == 0 then
						-- Should never be the case.
						faction_trait_growth = "Growth From Faction Trait: ".."[[rgba:255:255:0:150]](0%)[[/rgba]]\n";
					else
						faction_trait_growth = "Growth From Faction Trait: ".."[[rgba:8:201:27:150]](+"..second_split[2].."%)[[/rgba]]\n";
					end
				elseif second_split[1] == "technologies_"..tostring(class) then
					second_split[2] = Round_Number_Text(second_split[2]);
	
					if tonumber(second_split[2]) < 0 then
						technology_growth = "Growth From Technologies: ".."[[rgba:255:0:0:150]]("..second_split[2].."%)[[/rgba]]\n";
					elseif tonumber(second_split[2]) == 0 then
						-- Should never be the case.
						technology_growth = "Growth From Technologies: ".."[[rgba:255:255:0:150]](0%)[[/rgba]]\n";
					else
						technology_growth = "Growth From Technologies: ".."[[rgba:8:201:27:150]](+"..second_split[2].."%)[[/rgba]]\n";
					end
				elseif second_split[1] == "buildings_"..tostring(class) then
					second_split[2] = Round_Number_Text(second_split[2]);
					building_growth = "Growth From Buildings: ".."[[rgba:8:201:27:150]](+"..second_split[2].."%)[[/rgba]]\n";
				elseif second_split[1] == "capital_bonus_"..tostring(class) then
					--second_split[2] = Round_Number_Text(second_split[2]);
					capital_bonus = "Faction Capital: ".."[[rgba:8:201:27:150]](+"..second_split[2].."%)[[/rgba]]\n";
				elseif second_split[1] == "imperial_decree_"..tostring(class) then
					--second_split[2] = Round_Number_Text(second_split[2]);
					imperial_decree = "Imperial Decree: ".."[[rgba:8:201:27:150]](+"..second_split[2].."%)[[/rgba]]\n";
				elseif second_split[1] == "hard_cap_exceeded" then
					second_split[2] = Round_Number_Text(second_split[2]);
					cap_exceeded = "Hard Cap Exceeded: ".."[[rgba:255:0:0:150]](-"..second_split[2].."% of growth)[[/rgba]]\n";
				elseif second_split[1] == "soft_cap_exceeded" then
					second_split[2] = Round_Number_Text(second_split[2]);
					cap_exceeded = "Soft Cap Exceeded: ".."[[rgba:255:0:0:150]](-"..second_split[2].."% of growth)[[/rgba]]\n";
				elseif second_split[1] == "black_death" then
					second_split[2] = Round_Number_Text(second_split[2]);
					cap_exceeded = "Plague Outbreak: ".."[[rgba:255:0:0:150]](-"..second_split[2].."%)[[/rgba]]\n";
				elseif second_split[1] == "under_siege" then
					second_split[2] = Round_Number_Text(second_split[2]);
					under_siege = "Under Siege: ".."[[rgba:255:0:0:150]](-"..second_split[2].."%)[[/rgba]]\n";
				elseif second_split[1] == "food_shortage" then
					second_split[2] = Round_Number_Text(second_split[2]);
					food_shortage = "Food Shortage: ".."[[rgba:255:0:0:150]](-"..second_split[2].."%)[[/rgba]]\n";
				elseif second_split[1] == "region_raided" then
					second_split[2] = Round_Number_Text(second_split[2]);
					region_raided = "Region Being Raided: ".."[[rgba:255:0:0:150]](-"..second_split[2].."%)[[/rgba]]\n";
				end
			end
		end

		description_window_uic:SetStateText(class_population..capital_bonus..faction_trait_growth..building_growth..technology_growth..imperial_decree..cap_exceeded..under_siege..food_shortage..region_raided..projected_growth..projected_growth_num);
		nobility_uic:SetVisible(false);
		artisans_uic:SetVisible(false);
		peasantry_uic:SetVisible(false);
		tribesmen_uic:SetVisible(false);
		foreigners_uic:SetVisible(false);
	end
end
