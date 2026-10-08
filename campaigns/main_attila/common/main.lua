----------------------------------------------------------------------------------------------
----------------------------------------------------------------------------------------------
--
-- 	MEDIEVAL KINGDOMS 1212 - COMMON: MAIN
-- 	By: DETrooper
--
----------------------------------------------------------------------------------------------
----------------------------------------------------------------------------------------------

require("common/mk1212_common");
require("common/mk1212_common_lists");

require("common/mk1212_campaign_cutscenes");
require("common/mk1212_localisation_lists");
require("common/mk1212_update_region_loc");
require("common/mk1212_vassal_tracking");
require("common/mkmp_debug");
require("common/mkmp_runtime");

require("common/ui/mk1212_global_ui");
require("common/ui/mk1212_unit_information");

if not cm:is_multiplayer() then
	require("common/ui/mk1212_occupation_decisions");
end

function Common_Initializer()
	MKMP_Debug_Initialize();

	-- Runtime observability is optional in both single-player and multiplayer.
	-- The adapter is fail-closed: missing/incompatible native code only disables
	-- diagnostics and must never prevent normal MK1212 Lua initialization.
	MKMP_Runtime_Initialize();

	Add_MK1212_Common_Listeners();

	Add_MK1212_Campaign_Cutscene_Listeners();
	Add_MK1212_Global_UI_Listeners();
	Add_MK1212_Update_Region_Name_Listeners();
	Add_MK1212_Unit_Information_Listeners();
	Add_MK1212_Vassal_Tracking_Listeners();

	if not cm:is_multiplayer() then
		Add_MK1212_Occupation_Decision_Listeners();
	end
end
