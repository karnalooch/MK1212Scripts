-- Experimental MK1212 Single Player -> Multiplayer parity switches.
-- Issue #66. This file is bundled with both peers' identical mod content.
-- FAIL CLOSED: normal multiplayer remains unchanged until deliberately opted in.
-- Use ONLY for disposable, new, two-peer test campaigns. No runtime proof yet.
--
-- Every enabled feature may cause OOS. Turn on ONE feature at a time after
-- recording the exact .pack hashes, load order, and HOST/CLIENT game build.

MKMP_SP_PARITY = {
    enabled = false, -- explicit opt-in; NEVER infer from a local user setting
    all_experimental = false, -- DANGEROUS: one-switch disposable-campaign smoke

    annex_vassals = false,
    buffer_states = false,
    decisions = false,
    hre = false,
    population = false,
    region_trading = false,
    occupation_decisions = false,
    story_hre_sicily = false,
    lucky_nations = false,
    challenge_judgement_day = false,
    challenge_no_retreat = false,
    challenge_this_is_total_war = false,
    pope_crusades_ui = false,
    pope_capital_visibility = false,
    global_ui_religion_change = false,
    kingdom_decisions = false,
    dynamic_faction_decisions = false,
    pope_favour_decisions = false,
}

-- Intentionally unsupported even in experimental MP parity mode:
-- ironman: local autosave/quickload and file ownership.
-- change_capital: external executable alters a local save/reload path.
-- legacy_networking: superseded unsafe helper; no MP protocol proof.
local blocked_features = {
    ironman = true,
    change_capital = true,
    legacy_networking = true,
}

function MKMP_SP_Parity_Enabled(feature)
    if type(feature) ~= "string" or blocked_features[feature] then
        return false
    end
    if type(MKMP_SP_PARITY) ~= "table" or MKMP_SP_PARITY.enabled ~= true then
        return false
    end
    if not cm or type(cm.is_multiplayer) ~= "function" or not cm:is_multiplayer() then
        return false
    end
    -- Never let all_experimental turn an unknown or blocked key into permission.
    if feature == "enabled" or feature == "all_experimental"
        or type(MKMP_SP_PARITY[feature]) ~= "boolean" then
        return false
    end
    local all = MKMP_SP_PARITY.all_experimental == true
    local enabled = all or MKMP_SP_PARITY[feature] == true
    if not enabled then
        return false
    end
    -- Manual decisions need the common decision UI/listener layer.
    if feature == "kingdom_decisions" or feature == "dynamic_faction_decisions"
        or feature == "pope_favour_decisions" then
        return all or MKMP_SP_PARITY.decisions == true
    end
    return true
end
