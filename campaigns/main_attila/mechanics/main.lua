--------------------------------------------------------------------------------------------------
--------------------------------------------------------------------------------------------------
--
-- 	MEDIEVAL KINGDOMS 1212 - MECHANICS: MAIN
-- 	By: DETrooper
--
--------------------------------------------------------------------------------------------------
--------------------------------------------------------------------------------------------------

require("mechanics/mechanics_lists");

require("mechanics/mechanics_annex_vassals");
require("mechanics/mechanics_buffer_states");
require("mechanics/mechanics_dynamic_faction_names");
require("mechanics/mechanics_plague");
require("mechanics/mechanics_region_trading");
require("mechanics/mechanics_settle_upkeep");
require("mechanics/mechanics_silk_road");
require("mechanics/mechanics_war_weariness");

require("mechanics/islam/mechanics_islam");
require("mechanics/pope/mechanics_pope");
require("mechanics/decisions/mechanics_decisions");

require("mechanics/hre/mechanics_hre");
require("mechanics/population/mechanics_population");

function Mechanic_Initializer()
	if MKMP_FeatureEnabled("annex_vassals") then
		Add_Annex_Vassals_Listeners();
	end

	if MKMP_FeatureEnabled("buffer_states") then
		Add_Buffer_States_Listeners();
	end

	if MKMP_FeatureEnabled("decisions") then
		Add_Decisions_Listeners();
	end

	Add_Dynamic_Faction_Names_Listeners();

	if MKMP_FeatureEnabled("hre") then
		Add_HRE_Listeners();
	end

	Add_Islamic_Listeners();
	Add_Plague_Listeners();
	Add_Pope_Listeners();

	if MKMP_FeatureEnabled("population") then
		Add_Population_Listeners();
	end

	if MKMP_FeatureEnabled("region_trading") then
		Add_Region_Trading_Listeners();
	end

	Add_Settle_Upkeep_Listeners();
	Add_Silk_Road_Listeners();
	Add_War_Weariness_Listeners();
end
