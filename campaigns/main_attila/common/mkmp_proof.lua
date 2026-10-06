------------------------------------------------------------------------------------------------------------------------
------------------------------------------------------------------------------------------------------------------------
--
-- MK1212 MULTIPLAYER PROOF HARNESS
--
-- Read-only structured instrumentation for final two-peer validation.
-- It must never drive gameplay decisions.
--
------------------------------------------------------------------------------------------------------------------------
------------------------------------------------------------------------------------------------------------------------

MKMP_PROOF = {
	initialized = false,
	sequence = 0,
	schema = 1
};

local function MKMP_Proof_Human_Order()
	local names = {};

	for i = 1, #HUMAN_FACTIONS do
		local faction = cm:model():faction_for_command_queue_index(HUMAN_FACTIONS[i]);

		if faction and not faction:is_null_interface() then
			table.insert(names, faction:name());
		end
	end

	return table.concat(names, ",");
end

local function MKMP_Proof_Battle_Detail()
	local telemetry = MKMP_Runtime_Get_Battle_Telemetry();

	if telemetry then
		return "battle_cap="..tostring(telemetry.cap)..",reinforcement_queue="..tostring(telemetry.size);
	end

	return "battle_native=unavailable";
end

function MKMP_Proof_Log(event_name, detail)
	if not cm:is_multiplayer() then
		return;
	end

	MKMP_PROOF.sequence = MKMP_PROOF.sequence + 1;

	MKMP_Runtime_Log(
		"[PROOF]"..
		" schema="..tostring(MKMP_PROOF.schema)..
		" seq="..tostring(MKMP_PROOF.sequence)..
		" turn="..tostring(cm:model():turn_number())..
		" faction_turn="..tostring(FACTION_TURN)..
		" event="..tostring(event_name)..
		" detail="..tostring(detail or "")..
		" fingerprint="..MKMP_Runtime_Get_Campaign_Fingerprint()
	);
end

function MKMP_Proof_FactionTurnStart(context)
	if context:faction():is_human() then
		MKMP_Proof_Log(
			"FactionTurnStart",
			"faction="..context:faction():name()..
			",human_order="..MKMP_Proof_Human_Order()
		);
	end
end

function MKMP_Proof_FactionTurnEnd(context)
	if context:faction():is_human() then
		MKMP_Proof_Log(
			"FactionTurnEnd",
			"faction="..context:faction():name()
		);
	end
end

function MKMP_Proof_PendingBattle(context)
	local pending_battle = cm:model():pending_battle();
	local attacker = "none";
	local defender = "none";

	if pending_battle:has_attacker() then
		attacker = pending_battle:attacker():faction():name();
	end

	if pending_battle:has_defender() then
		defender = pending_battle:defender():faction():name();
	end

	MKMP_Proof_Log(
		"PendingBattle",
		"attacker="..attacker..
		",defender="..defender..
		","..MKMP_Proof_Battle_Detail()
	);
end

function MKMP_Proof_BattleCompleted(context)
	local pending_battle = cm:model():pending_battle();
	local attacker_result = pending_battle:attacker_battle_result();
	local defender_result = pending_battle:defender_battle_result();

	MKMP_Proof_Log(
		"BattleCompleted",
		"attacker_result="..tostring(attacker_result)..
		",defender_result="..tostring(defender_result)
	);
end

function MKMP_Proof_DilemmaChoice(context)
	MKMP_Proof_Log(
		"DilemmaChoiceMadeEvent",
		"faction="..context:faction():name()..
		",dilemma="..tostring(context:dilemma())..
		",choice="..tostring(context:choice())
	);
end

function MKMP_Proof_PostBattle(context, action)
	MKMP_Proof_Log(
		"CharacterPostBattle",
		"action="..tostring(action)..
		",faction="..context:character():faction():name()..
		",character_cqi="..tostring(context:character():cqi())
	);
end

function MKMP_Proof_WarDeclared(context)
	MKMP_Proof_Log(
		"FactionLeaderDeclaresWar",
		"faction="..context:character():faction():name()
	);
end

function MKMP_Proof_LeaderChange(context)
	MKMP_Proof_Log(
		"CharacterBecomesFactionLeader",
		"faction="..context:character():faction():name()..
		",character_cqi="..tostring(context:character():cqi())
	);
end

function MKMP_Proof_TimeTrigger(context)
	if string.find(tostring(context.string), "mkmp_proof:", 1, true) == 1 then
		MKMP_Proof_Log("TimeTrigger", tostring(context.string));
	end
end

function MKMP_Proof_Schedule_Timer(token, delay)
	if not cm:is_multiplayer() then
		return false;
	end

	cm:add_time_trigger("mkmp_proof:"..tostring(token), delay or 0.5);
	return true;
end

function MKMP_Proof_Initialize()
	if MKMP_PROOF.initialized or not cm:is_multiplayer() then
		return;
	end

	MKMP_PROOF.initialized = true;

	cm:add_listener(
		"MKMP_Proof_FactionTurnStart",
		"FactionTurnStart",
		true,
		function(context) MKMP_Proof_FactionTurnStart(context) end,
		true
	);
	cm:add_listener(
		"MKMP_Proof_FactionTurnEnd",
		"FactionTurnEnd",
		true,
		function(context) MKMP_Proof_FactionTurnEnd(context) end,
		true
	);
	cm:add_listener(
		"MKMP_Proof_PendingBattle",
		"PendingBattle",
		true,
		function(context) MKMP_Proof_PendingBattle(context) end,
		true
	);
	cm:add_listener(
		"MKMP_Proof_BattleCompleted",
		"BattleCompleted",
		true,
		function(context) MKMP_Proof_BattleCompleted(context) end,
		true
	);
	cm:add_listener(
		"MKMP_Proof_DilemmaChoiceMade",
		"DilemmaChoiceMadeEvent",
		true,
		function(context) MKMP_Proof_DilemmaChoice(context) end,
		true
	);
	cm:add_listener(
		"MKMP_Proof_PostBattleEnslave",
		"CharacterPostBattleEnslave",
		true,
		function(context) MKMP_Proof_PostBattle(context, "ENSLAVE") end,
		true
	);
	cm:add_listener(
		"MKMP_Proof_PostBattleRelease",
		"CharacterPostBattleRelease",
		true,
		function(context) MKMP_Proof_PostBattle(context, "RELEASE") end,
		true
	);
	cm:add_listener(
		"MKMP_Proof_PostBattleSlaughter",
		"CharacterPostBattleSlaughter",
		true,
		function(context) MKMP_Proof_PostBattle(context, "SLAUGHTER") end,
		true
	);
	cm:add_listener(
		"MKMP_Proof_WarDeclared",
		"FactionLeaderDeclaresWar",
		true,
		function(context) MKMP_Proof_WarDeclared(context) end,
		true
	);
	cm:add_listener(
		"MKMP_Proof_LeaderChange",
		"CharacterBecomesFactionLeader",
		true,
		function(context) MKMP_Proof_LeaderChange(context) end,
		true
	);
	cm:add_listener(
		"MKMP_Proof_TimeTrigger",
		"TimeTrigger",
		true,
		function(context) MKMP_Proof_TimeTrigger(context) end,
		true
	);

	MKMP_Runtime_Log(
		"[PROOF] init env="..MKMP_Runtime_Get_Environment_Fingerprint()..
		" runtime_available="..tostring(MKMP_Runtime_Available())
	);
end
