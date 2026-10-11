-------------------------------------------------------------------------------------------
-------------------------------------------------------------------------------------------
--
-- 	MEDIEVAL KINGDOMS 1212 - NICKNAMES: MAIN
-- 	By: DETrooper
--
-------------------------------------------------------------------------------------------
-------------------------------------------------------------------------------------------

require("nicknames/nicknames_lists");
require("nicknames/nicknames_tracking");
require("nicknames/nicknames_ui");

local nicknames_initializer_complete = false;

function Nicknames_Initializer()
	if nicknames_initializer_complete then return; end
	nicknames_initializer_complete = true;
	Add_Nicknames_Tracking_Listeners();
	Add_Nicknames_UI_Listeners();
end

function Add_Character_Nickname(character_cqi, nickname, ignore_priority)
	local cqi = tostring(character_cqi);
	local old_nickname = CHARACTERS_TO_NICKNAMES[cqi];

	if old_nickname then
		-- Character already has a nickname, so check to see if the new nickname has a higher priority.
		if ignore_priority then
			CHARACTERS_TO_NICKNAMES[cqi] = nickname;
		elseif NICKNAMES[nickname].priority and NICKNAMES[old_nickname].priority then
			-- Equal priority retains the existing name. Trait candidates are now
			-- visited in byte order, so this upstream tie rule is reproducible.
			if NICKNAMES[nickname].priority < NICKNAMES[old_nickname].priority then
				CHARACTERS_TO_NICKNAMES[cqi] = nickname;
			end
		end
	else
		CHARACTERS_TO_NICKNAMES[cqi] = nickname;
	end
end

function Remove_Character_Nickname(character_cqi, nickname)
	local cqi = tostring(character_cqi);

	CHARACTERS_TO_NICKNAMES[cqi] = nil;
end
