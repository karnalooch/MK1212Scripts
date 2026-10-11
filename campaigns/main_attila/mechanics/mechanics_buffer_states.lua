-----------------------------------------------------------------------------------------------------------------------
-----------------------------------------------------------------------------------------------------------------------
--
-- 	MEDIEVAL KINGDOMS 1212 - MECHANICS: BUFFER STATES
-- 	By: DETrooper
--
-----------------------------------------------------------------------------------------------------------------------
-----------------------------------------------------------------------------------------------------------------------

-- Local UI intent remains experimental in MP; this is not a transport layer.
-- One action and one owned timer may exist. Only confirmed spawn/vassal work
-- reaches waiting_transfer; interrupted started/applying work is never replayed.
local buffer_initialized = false;
local buffer_intent = nil;
local buffer_pending = nil;
local buffer_serial = 0;
local buffer_timer_armed = false;
local buffer_blocked = false;
local buffer_preserve_raw = false;
local buffer_raw = "";
local buffer_raw_schema = 0;
local BUFFER_STATE_KEY = "MKMP_BUFFER_ACTION_STATE";
-- Keep every identifier exact even with the committed float-configured Lua.
-- Refuse exhaustion; wrapping could let an old timer consume a new action.
local BUFFER_MAX_SERIAL = 1000000;

local function Buffer_Log(event, action)
	if MKMP_Debug_Log then
		pcall(MKMP_Debug_Log, event, {
			region = action and action.region, faction = action and action.master,
			vassal = action and action.vassal, phase = action and action.phase,
			serial = action and action.serial
		});
	end
end

local function Buffer_Timer_Name(action)
	return "MK1212_Buffer_Transfer_"..tostring(action.serial);
end

local function Buffer_Resolve_Action(action)
	local world = cm:model():world();
	local region = world:region_manager():region_by_key(action.region);
	local master = world:faction_by_key(action.master);
	local vassal = world:faction_by_key(action.vassal);
	if not region or region:is_null_interface() or not master or master:is_null_interface()
		or not vassal or vassal:is_null_interface()
		or REGIONS_LIBERATION_FACTIONS[action.region] ~= action.vassal
		or action.turn > cm:model():turn_number() then
		return nil;
	end
	local owner = region:owning_faction();
	if not owner or owner:is_null_interface() then return nil; end
	if owner:name() ~= action.master and owner:name() ~= action.vassal then return nil; end
	return region, master, vassal, owner:name() == action.vassal;
end

local function Buffer_Arm_Transfer()
	local action = buffer_pending;
	if buffer_blocked or buffer_timer_armed or not action or action.phase ~= "waiting_transfer" then return; end
	local region, _, _, already_owned = Buffer_Resolve_Action(action);
	if not region then
		action.phase = "blocked";
		Buffer_Log("buffer_transfer_invalid_owner", action);
		return;
	elseif already_owned then
		buffer_pending = nil;
		return;
	end
	-- The same namespaced token may be delivered twice after loading; only the
	-- still-pending action can consume it. It never reads REGION_SELECTED.
	buffer_timer_armed = true;
	cm:add_time_trigger(Buffer_Timer_Name(action), 0.1);
end

local function Buffer_Apply_Transfer(action)
	local region, _, _, already_owned = Buffer_Resolve_Action(action);
	if not region then
		action.phase = "blocked";
		Buffer_Log("buffer_transfer_invalid_owner", action);
		return;
	end
	if already_owned then buffer_pending = nil; return; end
	-- Retain the claim if the engine/helper fails. Neither another timer nor
	-- loading this phase is allowed to retry a potentially partial mutation.
	action.phase = "applying";
	if Transfer_Region_To_Faction(action.region, action.vassal) == true then
		buffer_pending = nil;
		Buffer_Log("buffer_transfer_complete", action);
	else
		Buffer_Log("buffer_transfer_blocked", action);
	end
end

local function Buffer_Capture_Intent()
	if buffer_pending or buffer_blocked then return nil; end
	local region_name, master_name = REGION_SELECTED, FACTION_TURN;
	if type(region_name) ~= "string" or region_name == "" or type(master_name) ~= "string"
		or master_name ~= cm:get_local_faction() then return nil; end
	local vassal_name = REGIONS_LIBERATION_FACTIONS[region_name];
	if type(vassal_name) ~= "string" or vassal_name == "" then return nil; end
	local action = {region = region_name, master = master_name, vassal = vassal_name,
		turn = cm:model():turn_number()};
	local region, _, _, already_owned = Buffer_Resolve_Action(action);
	if not region or already_owned then return nil; end
	if mkHRE and mkHRE.factions_start and mkHRE.current_reform
		and HasValue(mkHRE.factions_start, vassal_name) and mkHRE.current_reform < 9 then return nil; end
	return action;
end

function Add_Buffer_States_Listeners()
	if buffer_initialized then
		Buffer_Arm_Transfer();
		return;
	end
	buffer_initialized = true;
	cm:add_listener(
		"OnComponentLClickUp_Buffer_UI",
		"ComponentLClickUp",
		true,
		function(context) OnComponentLClickUp_Buffer_UI(context) end,
		true
	);
	cm:add_listener(
		"SettlementSelected_Buffer",
		"SettlementSelected",
		true,
		function(context) OnSettlementSelected_Buffer(context) end,
		true
	);
	cm:add_listener(
		"SettlementDeselected_Buffer",
		"SettlementDeselected",
		true,
		function(context) OnSettlementDeselected_Buffer(context) end,
		true
	);
	cm:add_listener(
		"TimeTrigger_Buffer",
		"TimeTrigger",
		true,
		function(context) OnTimeTrigger_Buffer(context) end,
		true
	);

	CreateBufferStateUI();
	Buffer_Arm_Transfer();
end

function CreateBufferStateUI()
	local root = cm:ui_root();

	root:CreateComponent("Buffer_Warning", "UI/new/buffer_warning");
	local panBufferWarning = UIComponent(root:Find("Buffer_Warning"));

	UIComponent(panBufferWarning:Find("heading_txt")):SetStateText(UI_LOCALISATION["buffer_state_prompt_heading_text"]);
	UIComponent(panBufferWarning:Find("dy_buffer_info")):SetStateText("");
	UIComponent(panBufferWarning:Find("txt")):SetStateText(UI_LOCALISATION["buffer_state_prompt_description"]);
	panBufferWarning:SetVisible(false);
end

function OnComponentLClickUp_Buffer_UI(context)
	if context.string == "button_release_buffer_state" then
		local root = cm:ui_root();
		local panBufferWarning = UIComponent(root:Find("Buffer_Warning"));
	
		if panBufferWarning:Visible() == false then
			buffer_intent = Buffer_Capture_Intent();
			if not buffer_intent then return; end
			local vassal_faction_name = buffer_intent.vassal;
			local faction_string = Get_DFN_Localisation(vassal_faction_name);
			local region_string = REGIONS_NAMES_LOCALISATION[buffer_intent.region];
			local dy_buffer_info_uic = UIComponent(panBufferWarning:Find("dy_buffer_info"));
			local scroll_frame_uic = UIComponent(panBufferWarning:Find("scroll_frame"));

			dy_buffer_info_uic:SetStateText(UI_LOCALISATION["buffer_state_prompt_info_pt1"]..faction_string..UI_LOCALISATION["buffer_state_prompt_info_pt2"]..region_string);
			scroll_frame_uic:DestroyChildren();

			if HasValue(FACTIONS_WITH_IMAGES, vassal_faction_name) then
				scroll_frame_uic:CreateComponent("faction_logo", "UI/new/faction_flags/"..vassal_faction_name.."_flag_big");
			else
				scroll_frame_uic:CreateComponent("faction_logo", "UI/new/faction_flags/mk_fact_unknown_flag_big");
			end

			local faction_logo_uic = UIComponent(scroll_frame_uic:Find(0));
			local scroll_frame_uicX, scroll_frame_uicY = scroll_frame_uic:Position();

			faction_logo_uic:SetMoveable(true);
			faction_logo_uic:MoveTo(scroll_frame_uicX + 152, scroll_frame_uicY + 70);
			faction_logo_uic:SetMoveable(false);
			faction_logo_uic:SetInteractive(false);

			panBufferWarning:SetVisible(true);
		else
			BufferPanelClosed(true);
		end
	elseif context.string == "button_buffer_confirm" then
		local action = buffer_intent;
		if not action or buffer_pending or buffer_blocked then return; end
		buffer_intent = nil;
		local region, _, _, already_owned = Buffer_Resolve_Action(action);
		if not region or already_owned or FACTION_TURN ~= action.master
			or buffer_serial >= BUFFER_MAX_SERIAL then
			BufferPanelClosed(false);
			return;
		end
		buffer_serial = buffer_serial + 1;
		action.serial, action.phase = buffer_serial, "started";
		buffer_pending = action;
		local root = cm:ui_root();
		local btnBuffer = UIComponent(root:Find("button_release_buffer_state"));
		local faction_name = action.master;
		local vassal_faction_name = action.vassal;
		local spear_unit = BUFFER_STATE_SPEAR_UNITS[vassal_faction_name];
		local unit_list = "";

		if spear_unit then
			unit_list = spear_unit..","..spear_unit..","..spear_unit..","..spear_unit;
		else
			-- We need to give them something even if it's inaccurate, otherwise the army will not spawn.
			unit_list = "att_rom_cohors";
		end

		if not FactionIsAlive(vassal_faction_name) then
			local settlement = region:settlement();
			if not settlement or settlement:is_null_interface() then
				action.phase = "blocked";
				BufferPanelClosed(false);
				return;
			end
			local region_x = settlement:logical_position_x();
			local region_y = settlement:logical_position_y();

			cm:create_force(
				vassal_faction_name,
				unit_list,
				action.region,
				region_x,
				region_y,
				"VassalArmy_"..action.region..action.turn,
				true,
				function(cqi)
					if buffer_pending ~= action or action.phase ~= "started" then return; end
					local created_cqi = tonumber(cqi);
					if not created_cqi or created_cqi <= 0 or created_cqi == math.huge
						or created_cqi ~= math.floor(created_cqi) then
						action.phase = "blocked";
						Buffer_Log("buffer_spawn_invalid_cqi", action);
						return;
					end
					local current_region, _, _, transferred = Buffer_Resolve_Action(action);
					if not current_region or transferred then
						action.phase = "blocked";
						Buffer_Log("buffer_spawn_invalid_owner", action);
						return;
					end
					action.phase = "applying";
					cm:force_make_vassal(faction_name, vassal_faction_name);
					if FACTIONS_TO_FACTIONS_VASSALIZED then
						Faction_Vassalized(faction_name, vassal_faction_name, true, false, false);
					end
					action.phase = "waiting_transfer";
					Buffer_Arm_Transfer();
				end
			);
		else
			Buffer_Apply_Transfer(action);
		end

		BufferPanelClosed(false);
		btnBuffer:SetVisible(false);
	elseif context.string == "button_buffer_cancel" then
		BufferPanelClosed(false);
	elseif context.string == "root" then
		buffer_intent = nil;
		local root = cm:ui_root();
		local panBufferWarning = UIComponent(root:Find("Buffer_Warning"));
		local btnBuffer = UIComponent(root:Find("button_release_buffer_state"));
	
		if panBufferWarning:Visible() == true then
			panBufferWarning:SetVisible(false);
		end

		if btnBuffer:Visible() == true then
			btnBuffer:SetState("inactive"); 
			btnBuffer:SetVisible(false);
		end
	end
end

function OnSettlementSelected_Buffer(context)
	local root = cm:ui_root();
	local btnBuffer = UIComponent(root:Find("button_release_buffer_state"));
	local faction_name = FACTION_TURN;

	if btnBuffer:Visible() == true then
		btnBuffer:SetState("inactive");
		btnBuffer:SetVisible(false);
	end
	if buffer_pending or buffer_blocked then return; end
	local garrison = context:garrison_residence();
	if not garrison or garrison:is_null_interface() then return; end
	local region = garrison:region();
	if not region or region:is_null_interface() then return; end
	local owner = region:owning_faction();
	if not owner or owner:is_null_interface() then return; end
	local region_name, region_owner_name = region:name(), owner:name();

	if region_owner_name == faction_name then
		local vassal_faction_name = REGIONS_LIBERATION_FACTIONS[region_name];
		if type(vassal_faction_name) ~= "string" or vassal_faction_name == "" then return; end
		local vassal_faction = cm:model():world():faction_by_key(vassal_faction_name);
		if not vassal_faction or vassal_faction:is_null_interface() then return; end

		if not FactionIsAlive(vassal_faction_name) then
			-- Don't allow HRE factions to be released as buffer states unless Renovatio Imperii has already occured.
			if mkHRE and mkHRE.factions_start and mkHRE.current_reform then
				if HasValue(mkHRE.factions_start, vassal_faction_name) and mkHRE.current_reform < 9 then
					return;
				end
			end

			if cm:get_local_faction() == FACTION_TURN then
				btnBuffer:SetState("active"); 
				btnBuffer:SetVisible(true);
			end
		end
	end
end

function OnSettlementDeselected_Buffer(context)
	buffer_intent = nil;
	local root = cm:ui_root();
	local panBufferWarning = UIComponent(root:Find("Buffer_Warning"));
	local btnBuffer = UIComponent(root:Find("button_release_buffer_state"));

	if panBufferWarning:Visible() == true then
		panBufferWarning:SetVisible(false);
	end

	if btnBuffer:Visible() == true then
		btnBuffer:SetState("inactive"); 
		btnBuffer:SetVisible(false);
	end
end

function OnTimeTrigger_Buffer(context)
	local action = buffer_pending;
	if buffer_blocked or not action or action.phase ~= "waiting_transfer"
		or context.string ~= Buffer_Timer_Name(action) then return; end
	buffer_timer_armed = false;
	Buffer_Apply_Transfer(action);
end

function BufferPanelClosed(hover)
	buffer_intent = nil;
	local root = cm:ui_root();
	local panBufferWarning = UIComponent(root:Find("Buffer_Warning"));
	local btnBuffer = UIComponent(root:Find("button_release_buffer_state"));

	panBufferWarning:SetVisible(false);

	if hover == true then
		btnBuffer:SetState("hover");
	else
		btnBuffer:SetState("active");
	end
end

-- Owned action schema 1, stored through the common framed array codec:
-- {"1", serial, "idle"} or
-- {"1", serial, phase, master_key, vassal_key, region_key, start_turn}.
-- At most seven scalar fields / 4096 encoded bytes, one pending action, no
-- retry list. Local unconfirmed modal intent is intentionally never persisted.
local function Buffer_Saved_Integer(value)
	if type(value) ~= "string" or not string.match(value, "^%d+$") then return nil; end
	local number = tonumber(value);
	if not number or number < 0 or number > BUFFER_MAX_SERIAL
		or tostring(number) ~= value then return nil; end
	return number;
end

local function Buffer_Valid_Phase(phase)
	return phase == "started" or phase == "applying"
		or phase == "waiting_transfer" or phase == "blocked";
end

cm:register_saving_game_callback(
	function(context)
		if buffer_preserve_raw then
			cm:save_value(BUFFER_STATE_KEY, buffer_raw, context);
			cm:save_value(BUFFER_STATE_KEY.."__schema", buffer_raw_schema, context);
			return;
		end
		local record = {"1", tostring(buffer_serial), "idle"};
		if buffer_pending then
			local action = buffer_pending;
			if not Buffer_Valid_Phase(action.phase) or action.serial ~= buffer_serial then
				error("MK1212 buffer action has invalid phase/serial");
			end
			record = {"1", tostring(buffer_serial), action.phase, action.master,
				action.vassal, action.region, tostring(action.turn)};
		end
		-- All fields are bounded before the common codec writes the value.
		for i = 1, #record do
			if type(record[i]) ~= "string" or record[i] == "" or #record[i] > 256 then
				error("MK1212 buffer action has invalid/oversized field");
			end
		end
		SaveTable(context, record, BUFFER_STATE_KEY);
	end
);

cm:register_loading_game_callback(
	function(context)
		buffer_intent, buffer_pending = nil, nil;
		buffer_timer_armed = false;
		buffer_blocked, buffer_preserve_raw = true, true;
		buffer_raw = cm:load_value(BUFFER_STATE_KEY, "", context);
		buffer_raw_schema = cm:load_value(BUFFER_STATE_KEY.."__schema", 0, context);
		if buffer_raw == "" and buffer_raw_schema == 0 then
			-- Old saves have no correlated action. A legacy region_transfer timer
			-- cannot be reconstructed from whichever settlement is selected now.
			buffer_serial = 0;
			buffer_blocked, buffer_preserve_raw = false, false;
			return;
		end
		if type(buffer_raw) ~= "string" or #buffer_raw > 4096 then
			Buffer_Log("buffer_action_invalid_save");
			return;
		end
		local ok, record = pcall(LoadTable, context, BUFFER_STATE_KEY);
		if not ok or record[1] ~= "1" or not Buffer_Saved_Integer(record[2]) then
			Buffer_Log("buffer_action_invalid_save");
			return;
		end
		local serial, phase = Buffer_Saved_Integer(record[2]), record[3];
		if phase == "idle" and #record == 3 then
			buffer_serial = serial;
			buffer_blocked, buffer_preserve_raw = false, false;
			return;
		end
		if #record ~= 7 or serial < 1 or not Buffer_Valid_Phase(phase)
			or not Buffer_Saved_Integer(record[7]) or Buffer_Saved_Integer(record[7]) < 1 then
			Buffer_Log("buffer_action_invalid_save");
			return;
		end
		for i = 4, 6 do
			if type(record[i]) ~= "string" or record[i] == "" or #record[i] > 256 then
				Buffer_Log("buffer_action_invalid_save");
				return;
			end
		end
		buffer_serial = serial;
		buffer_pending = {serial = serial, phase = phase, master = record[4],
			vassal = record[5], region = record[6], turn = Buffer_Saved_Integer(record[7])};
		if phase == "waiting_transfer" then
			-- First-tick initialization validates current entities/owner and arms
			-- one timer. No model commands or timers are issued while loading.
			buffer_blocked, buffer_preserve_raw = false, false;
		else
			-- started/applying may have partially succeeded before saving. Keep
			-- the exact saved record, never spawn or replay setup to compensate.
			Buffer_Log("buffer_action_no_replay", buffer_pending);
		end
	end
);
