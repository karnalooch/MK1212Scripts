-----------------------------------------------------------------------------------------------
-----------------------------------------------------------------------------------------------
--
-- 	MEDIEVAL KINGDOMS 1212 - IRONMAN: MAIN
-- 	By: DETrooper
--
-----------------------------------------------------------------------------------------------
-----------------------------------------------------------------------------------------------

require("ironman/ironman");
require("ironman/ironman_achievements");

function Ironman_Initializer()
	if cm:is_multiplayer() then
		IRONMAN_ENABLED = false;
		return;
	end

	Add_Ironman_Listeners();
	Add_Ironman_Achievement_Listeners();
end
