------------------------------------------------------------------------------------------------------------------------
-- MK1212 N2 native-delivery observation. Diagnostics only; no engine commands,
-- timers, networking, log input, authority toggles, or gameplay save state.
-- DilemmaChoiceMadeEvent is the ATTILA event used by the existing Papal code.
-- Seeing an event on both peers does not prove command replication semantics.
------------------------------------------------------------------------------------------------------------------------

local initialized = false;
local enabled = false;
local observations = 0;
local segment = 0;
local max_observations = 4096;
local max_segments = 65535;
local reason = "not_initialized";
local owned_listeners = {
	"MKMP_DeliveryProbe_Dilemma",
	"MKMP_DeliveryProbe_TurnStart",
	"MKMP_DeliveryProbe_TurnEnd",
	"MKMP_DeliveryProbe_Incident",
	"MKMP_DeliveryProbe_DilemmaIssued",
	"MKMP_DeliveryProbe_RoundStart",
	"MKMP_DeliveryProbe_NormalPhase",
	"MKMP_DeliveryProbe_Diplomacy",
	"MKMP_DeliveryProbe_DiplomacyRejected",
	"MKMP_DeliveryProbe_DilemmaIssuedRepo"
};

local function SafeCall(object, method)
	local ok, value = pcall(function()
		if not object or type(object[method]) ~= "function" then return nil; end
		return object[method](object);
	end);
	if ok then return value; end
	return nil;
end

local function BoundedText(value)
	if type(value) ~= "string" then return "unavailable"; end
	if #value == 0 or #value > 256 then return "unavailable"; end
	return value;
end

local function FactionName(faction)
	if SafeCall(faction, "is_null_interface") == true then return "unavailable"; end
	return BoundedText(SafeCall(faction, "name"));
end

local function LocalFaction()
	if not cm then return "unavailable"; end
	return BoundedText(SafeCall(cm, "get_local_faction"));
end

local function Emit(domain, event, fields)
	if not enabled or observations >= max_observations then return false; end
	observations = observations + 1;
	if observations == max_observations then
		-- Reserve the last bounded record for an explicit coverage stop marker.
		-- Silence after this point must not be mistaken for event non-delivery.
		domain = "diagnostic";
		event = "delivery_probe_budget_exhausted";
		fields = {maximum = max_observations, reason = "observation_budget"};
		reason = "observation_budget";
		enabled = false;
	end
	fields.probe_schema = 1;
	fields.probe_segment = segment;
	fields.authority = "evidence_only";
	if type(MKMP_Debug_Trace) == "function" then
		local ok, result = pcall(MKMP_Debug_Trace, domain, event, fields);
		return ok and result;
	end
	if type(MKMP_Debug_Log) == "function" then
		fields.domain = domain;
		local ok, result = pcall(MKMP_Debug_Log, event, fields);
		return ok and result;
	end
	return false;
end

local function ObserveDilemma(context)
	local choice = SafeCall(context, "choice");
	if type(choice) ~= "number" or choice ~= choice or choice < 0 or choice > 64
		or choice ~= math.floor(choice) then choice = "unavailable"; end
	local faction = FactionName(SafeCall(context, "faction"));
	local dilemma = BoundedText(SafeCall(context, "dilemma"));
	Emit("shared_candidate", "delivery_dilemma_observed", {
		listener = "MKMP_DeliveryProbe_Dilemma",
		phase = "DilemmaChoiceMadeEvent",
		stage = "observed",
		faction = faction,
		dilemma = dilemma,
		choice = choice,
		identity_status = "context_only_not_unique",
		command_replication = "unproven"
	});
	-- The local role/faction can differ legitimately. Keep it out of the
	-- candidate shared event fields used for paired delivery comparison.
	Emit("local", "delivery_dilemma_local_context", {
		phase = "DilemmaChoiceMadeEvent",
		local_faction = LocalFaction(),
		faction = faction,
		dilemma = dilemma,
		choice = choice
	});
end

local function ObservePhase(phase, context)
	Emit("shared_candidate", "delivery_phase_observed", {
		phase = phase,
		stage = "listener_entry",
		faction = FactionName(SafeCall(context, "faction")),
		meaning = "owned_listener_entry_not_global_barrier"
	});
end

local function ObserveNotice(event, context)
	-- Official ATTILA Extra Scripting Guides spells the event 'Occured' and
	-- documents dilemma() as the key accessor even for IncidentOccuredEvent.
	-- Missing/different runtime capability is recorded, never guessed into data.
	local key = BoundedText(SafeCall(context, "dilemma"));
	Emit("shared_candidate", "delivery_notice_observed", {
		phase = event,
		stage = "observed",
		faction = FactionName(SafeCall(context, "faction")),
		native_key = key,
		key_status = key == "unavailable" and "context_accessor_unavailable" or "observed",
		identity_status = "context_only_not_unique",
		payload_transport = "unproven"
	});
end

local function TreasurySnapshot(faction)
	local value = SafeCall(faction, "treasury");
	if type(value) ~= "number" or value ~= value or value < -16777215
		or value > 16777215 or value ~= math.floor(value) then return "unavailable"; end
	return value;
end

local function ObserveDiplomacy(event, context)
	local proposer = SafeCall(context, "proposer");
	local recipient = SafeCall(context, "recipient");
	local fields = {
		phase = event,
		stage = "event_callback_snapshot",
		proposer = FactionName(proposer),
		recipient = FactionName(recipient),
		proposer_treasury = TreasurySnapshot(proposer),
		recipient_treasury = TreasurySnapshot(recipient),
		amount_status = "not_exposed_by_documented_context",
		deal_id_status = "not_exposed_by_documented_context",
		treasury_meaning = "current_state_not_transaction_delta",
		command_replication = "unproven"
	};
	if event == "PositiveDiplomaticEvent" then
		local flags = {"is_alliance", "is_peace_treaty", "is_military_access", "is_trade_agreement", "is_form_confederation"};
		for i = 1, #flags do
			local flag = flags[i];
			local value = SafeCall(context, flag);
			fields[flag] = type(value) == "boolean" and value or "unavailable";
			-- Lua's and/or idiom loses false; preserve an observed false value.
			if value == false then fields[flag] = false; end
		end
	end
	Emit("shared_candidate", "delivery_diplomacy_observed", fields);
	Emit("local", "delivery_diplomacy_local_context", {
		phase = event, local_faction = LocalFaction(),
		proposer = fields.proposer, recipient = fields.recipient
	});
end

function MKMP_Delivery_Probe_Init()
	if initialized then return enabled; end
	initialized = true;
	if not cm or type(cm.add_listener) ~= "function" then
		reason = "listener_api_unavailable";
		return false;
	end
	enabled = true;
	local ok = pcall(function()
		cm:add_listener(owned_listeners[1], "DilemmaChoiceMadeEvent", true,
			function(context) pcall(ObserveDilemma, context); end, true);
		cm:add_listener(owned_listeners[2], "FactionTurnStart", true,
			function(context) pcall(ObservePhase, "FactionTurnStart", context); end, true);
		cm:add_listener(owned_listeners[3], "FactionTurnEnd", true,
			function(context) pcall(ObservePhase, "FactionTurnEnd", context); end, true);
		cm:add_listener(owned_listeners[4], "IncidentOccuredEvent", true,
			function(context) pcall(ObserveNotice, "IncidentOccuredEvent", context); end, true);
		cm:add_listener(owned_listeners[5], "DilemmaIssued", true,
			function(context) pcall(ObserveNotice, "DilemmaIssued", context); end, true);
		cm:add_listener(owned_listeners[6], "FactionRoundStart", true,
			function(context) pcall(ObservePhase, "FactionRoundStart", context); end, true);
		cm:add_listener(owned_listeners[7], "FactionBeginTurnPhaseNormal", true,
			function(context) pcall(ObservePhase, "FactionBeginTurnPhaseNormal", context); end, true);
		cm:add_listener(owned_listeners[8], "PositiveDiplomaticEvent", true,
			function(context) pcall(ObserveDiplomacy, "PositiveDiplomaticEvent", context); end, true);
		cm:add_listener(owned_listeners[9], "DiplomaticOfferRejected", true,
			function(context) pcall(ObserveDiplomacy, "DiplomaticOfferRejected", context); end, true);
		-- Repo lua_scripts/events.lua uses this name while the official guide
		-- lists DilemmaIssued. Keep observations distinct until runtime evidence.
		cm:add_listener(owned_listeners[10], "DilemmaIssuedEvent", true,
			function(context) pcall(ObserveNotice, "DilemmaIssuedEvent", context); end, true);
	end);
	if not ok then
		for i = 1, #owned_listeners do
			pcall(function() cm:remove_listener(owned_listeners[i]); end);
		end
		enabled = false;
		reason = "listener_registration_failed";
		return false;
	end
	-- Save/load observers contain no cm:save_value/cm:load_value calls and never
	-- write gameplay state. The local segment is evidence metadata only.
	if type(cm.register_saving_game_callback) == "function" then
		pcall(function()
			cm:register_saving_game_callback(function()
				pcall(Emit, "diagnostic", "delivery_save_observed", {phase = "saving_callback"});
			end);
		end);
	end
	if type(cm.register_loading_game_callback) == "function" then
		pcall(function()
			cm:register_loading_game_callback(function()
				if segment >= max_segments then
					enabled = false;
					reason = "segment_budget";
					return;
				end
				segment = segment + 1;
				observations = 0;
				if reason == "observation_budget" then
					enabled = true;
					reason = "observing";
				end
				pcall(Emit, "diagnostic", "delivery_load_observed", {phase = "loading_callback"});
			end);
		end);
	end
	reason = "observing";
	Emit("diagnostic", "delivery_probe_ready", {
		listeners = #owned_listeners,
		observation_budget = max_observations,
		local_faction = LocalFaction(),
		command_execution = "not_available"
	});
	return true;
end

function MKMP_Delivery_Probe_Observe_Command(kind, phase, action_id, stage, values)
	-- Call this only adjacent to an operation the gameplay module already owns.
	-- This function does not call it, repeat it, or equate 'returned' with applied.
	local fields = {
		kind = BoundedText(kind), phase = BoundedText(phase),
		action_id = BoundedText(action_id), stage = BoundedText(stage),
		command_replication = "unproven"
	};
	local allowed = {"actor", "target", "cqi", "amount", "expected", "actual", "reason", "execution_policy", "command_name"};
	if type(values) == "table" then
		for i = 1, #allowed do
			local key = allowed[i];
			local value = values[key];
			if type(value) == "string" then
				fields[key] = BoundedText(value);
			elseif type(value) == "boolean" then
				fields[key] = value;
			elseif type(value) == "number" and value == value and value >= -16777215
				and value <= 16777215 then
				fields[key] = value;
			end
		end
	end
	return Emit("shared_candidate", "delivery_command_observed", fields);
end

function MKMP_Delivery_Probe_Status()
	return {initialized = initialized, enabled = enabled, reason = reason,
		observations = observations, maximum = max_observations,
		segment = segment, authority = "evidence_only", execution = "not_available"};
end
