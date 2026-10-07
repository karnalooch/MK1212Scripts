--------------------------------------------------------------------------------------------------------------
--------------------------------------------------------------------------------------------------------------
--
-- MK1212 MULTIPLAYER FEATURE PROFILE
--
-- Central authority for script-side multiplayer feature activation.
-- The full profile is experimental until issue #15 provides real two-peer Attila proof.
--
--------------------------------------------------------------------------------------------------------------
--------------------------------------------------------------------------------------------------------------

MKMP_FEATURE_PROFILE = "full_experimental_v1";

MKMP_FEATURES = {
	-- Existing multiplayer baseline.
	["common"] = {enabled = true, mode = "shared_model"},
	["byzantium"] = {enabled = true, mode = "shared_model"},
	["kingdoms"] = {enabled = true, mode = "shared_model"},
	["mongols"] = {enabled = true, mode = "shared_model"},
	["timurids"] = {enabled = true, mode = "shared_model"},
	["nicknames"] = {enabled = true, mode = "shared_model"},
	["starting_battles"] = {enabled = true, mode = "shared_model"},
	["story_core"] = {enabled = true, mode = "shared_model"},
	["dynamic_faction_names"] = {enabled = true, mode = "shared_model"},
	["islam"] = {enabled = true, mode = "shared_model"},
	["plague"] = {enabled = true, mode = "shared_model"},
	["pope_core"] = {enabled = true, mode = "shared_model"},
	["settle_upkeep"] = {enabled = true, mode = "shared_model"},
	["silk_road"] = {enabled = true, mode = "shared_model"},
	["war_weariness"] = {enabled = true, mode = "shared_model"},
	["vassal_tracking"] = {enabled = true, mode = "shared_model"},
	["twdll_observability"] = {enabled = true, mode = "observability_only"},

	-- Experimental full unlock. These were historically guarded out of MP.
	["annex_vassals"] = {enabled = true, mode = "experimental_local_ui"},
	["buffer_states"] = {enabled = true, mode = "experimental_local_ui"},
	["decisions"] = {enabled = true, mode = "experimental_local_ui"},
	["hre"] = {enabled = true, mode = "experimental_local_ui"},
	["population"] = {enabled = true, mode = "experimental_local_ui"},
	["region_trading"] = {enabled = true, mode = "experimental_local_ui"},
	["occupation_decisions"] = {enabled = true, mode = "experimental_local_ui"},
	["crusades"] = {enabled = true, mode = "experimental_local_ui"},
	["pope_ui"] = {enabled = true, mode = "experimental_local_ui"},
	["hre_story"] = {enabled = true, mode = "shared_model"},
	["sicily_story"] = {enabled = true, mode = "experimental_choice_event"},

	-- Peer-local modifiers remain blocked. They are not missing core mechanics.
	["challenges"] = {enabled = false, mode = "blocked_local_config"},
	["ironman"] = {enabled = false, mode = "blocked_local_config"},
	["lucky_nations"] = {enabled = false, mode = "blocked_local_config"},

	-- Stale chat/UI experiment is not a synchronization backend.
	["legacy_networking"] = {enabled = false, mode = "blocked_stale"}
};

function MKMP_FeatureEnabled(feature_name)
	if cm:is_multiplayer() == false then
		return true;
	end

	local feature = MKMP_FEATURES[feature_name];

	if not feature then
		if dev and dev.log then
			dev.log("[MKMP][FEATURE] unknown feature requested: "..tostring(feature_name));
		end

		return false;
	end

	return feature.enabled == true;
end

function MKMP_FeatureMode(feature_name)
	local feature = MKMP_FEATURES[feature_name];

	if not feature then
		return "unknown";
	end

	return feature.mode;
end

function MKMP_FeatureProfileFingerprint()
	local keys = {};

	for key, _ in pairs(MKMP_FEATURES) do
		table.insert(keys, key);
	end

	table.sort(keys);

	local parts = {
		"profile="..MKMP_FEATURE_PROFILE
	};

	for i = 1, #keys do
		local key = keys[i];
		local feature = MKMP_FEATURES[key];

		table.insert(
			parts,
			key.."="..(feature.enabled and "1" or "0")..":"..tostring(feature.mode)
		);
	end

	return table.concat(parts, "|");
end

function MKMP_Log_Feature_Profile()
	if dev and dev.log then
		dev.log("[MKMP][FEATURE] "..MKMP_FeatureProfileFingerprint());
	end
end
