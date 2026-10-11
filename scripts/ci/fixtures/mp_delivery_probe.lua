-- Production observer contract, using the repository's Lua 5.1 float runtime.
local listeners, saved, loaded, records = {}, {}, {}, {};
local registrations = 0;
cm = {
	add_listener = function(self, id, event, condition, callback, persistent)
		assert(not listeners[id], "duplicate listener");
		listeners[id] = {event = event, callback = callback};
		registrations = registrations + 1;
	end,
	remove_listener = function(self, id) listeners[id] = nil; end,
	get_local_faction = function() return "mk_fact_host"; end,
	register_saving_game_callback = function(self, callback) saved[#saved + 1] = callback; end,
	register_loading_game_callback = function(self, callback) loaded[#loaded + 1] = callback; end
};
MKMP_Debug_Trace = function(domain, event, fields)
	records[#records + 1] = {domain = domain, event = event, fields = fields};
	return true;
end;
dofile("campaigns/main_attila/common/mkmp_delivery_probe.lua");
assert(MKMP_Delivery_Probe_Init());
assert(MKMP_Delivery_Probe_Init());
assert(registrations == 10 and #saved == 1 and #loaded == 1);
local context = {
	choice = function() return 1; end,
	dilemma = function() return "mk_dilemma_fixture"; end,
	faction = function() return {
		is_null_interface = function() return false; end,
		name = function() return "mk_fact_target"; end
	}; end
};
assert(listeners.MKMP_DeliveryProbe_Dilemma.event == "DilemmaChoiceMadeEvent");
listeners.MKMP_DeliveryProbe_Dilemma.callback(context);
assert(records[#records - 1].domain == "shared_candidate");
assert(records[#records - 1].fields.faction == "mk_fact_target");
assert(records[#records - 1].fields.choice == 1);
assert(records[#records - 1].fields.local_faction == nil);
assert(records[#records].domain == "local");
assert(records[#records].fields.local_faction == "mk_fact_host");
assert(listeners.MKMP_DeliveryProbe_Incident.event == "IncidentOccuredEvent");
listeners.MKMP_DeliveryProbe_Incident.callback(context);
assert(records[#records].fields.native_key == "mk_dilemma_fixture");
assert(records[#records].fields.payload_transport == "unproven");
assert(listeners.MKMP_DeliveryProbe_DilemmaIssued.event == "DilemmaIssued");
assert(listeners.MKMP_DeliveryProbe_DilemmaIssuedRepo.event == "DilemmaIssuedEvent");
local diplomacy = {
	proposer = function() return {name = function() return "mk_fact_host"; end, treasury = function() return 5000; end}; end,
	recipient = function() return {name = function() return "mk_fact_client"; end, treasury = function() return 6000; end}; end,
	is_trade_agreement = function() return false; end,
	is_alliance = function() return true; end
};
listeners.MKMP_DeliveryProbe_Diplomacy.callback(diplomacy);
assert(records[#records - 1].fields.proposer == "mk_fact_host");
assert(records[#records - 1].fields.recipient_treasury == 6000);
assert(records[#records - 1].fields.is_trade_agreement == false);
assert(records[#records - 1].fields.is_alliance == true);
assert(records[#records - 1].fields.is_peace_treaty == "unavailable");
assert(records[#records - 1].fields.amount_status == "not_exposed_by_documented_context");
listeners.MKMP_DeliveryProbe_DiplomacyRejected.callback(diplomacy);
assert(records[#records - 1].fields.phase == "DiplomaticOfferRejected");
assert(records[#records - 1].fields.is_trade_agreement == nil);
local broken = setmetatable({}, {__index = function() error("invalid native interface"); end});
assert(pcall(listeners.MKMP_DeliveryProbe_Dilemma.callback, broken));
assert(records[#records - 1].fields.choice == "unavailable");
MKMP_Delivery_Probe_Observe_Command("PapalLoan", "owned_callback", "fixture-action", "returned", {actor = "mk_fact_target", amount = 1000});
assert(records[#records].fields.command_replication == "unproven");
assert(records[#records].fields.stage == "returned");
for i = 1, 5000 do
	MKMP_Delivery_Probe_Observe_Command("PapalLoan", "owned_callback", "fixture-action", "observed", {});
end
assert(MKMP_Delivery_Probe_Status().observations == 4096);
assert(#records == 4096);
assert(records[#records].event == "delivery_probe_budget_exhausted");
loaded[1]();
assert(MKMP_Delivery_Probe_Status().segment == 1);
assert(MKMP_Delivery_Probe_Status().observations == 1);
MKMP_Debug_Trace = function() error("diagnostic failure"); end;
assert(pcall(listeners.MKMP_DeliveryProbe_Dilemma.callback, context));
assert(pcall(saved[1]));
assert(MKMP_Delivery_Probe_Status().authority == "evidence_only");
cm = {add_listener = function() error("no event API"); end, remove_listener = function() end};
dofile("campaigns/main_attila/common/mkmp_delivery_probe.lua");
assert(MKMP_Delivery_Probe_Init() == false);
assert(MKMP_Delivery_Probe_Status().reason == "listener_registration_failed");
cm = nil;
dofile("campaigns/main_attila/common/mkmp_delivery_probe.lua");
assert(MKMP_Delivery_Probe_Init() == false);
assert(MKMP_Delivery_Probe_Status().reason == "listener_api_unavailable");
print("delivery probe PASS");
