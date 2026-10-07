---------------------------------------------------------------------------------------------------------------------------------------
---------------------------------------------------------------------------------------------------------------------------------------
--
-- 	MEDIEVAL KINGDOMS 1212 - MULTIPLAYER CAMPAIGN DISCLAIMER
-- 	By: DETrooper
--
---------------------------------------------------------------------------------------------------------------------------------------
---------------------------------------------------------------------------------------------------------------------------------------

disclaimertitlestring = "Experimental Full Multiplayer Script Profile";
disclaimerstring = "This build enables the MK1212 full experimental multiplayer script profile."..
					"\n\nEnabled core systems include invasions, Papal systems, Starting Battles, War Weariness, World Events, Dynamic Faction Names, Kingdom Events, Annexing Vassals, Buffer States, Decisions, the Holy Roman Empire, Population, Region Trading, occupation-region gifting, Crusades/Pope UI, and HRE/Sicily Story Events."..
					"\n\nIMPORTANT: systems initiated from local UI or dilemma choices are repository-tested but are NOT yet proven to replicate identically between two real Attila peers. Final two-peer runtime validation is still required."..
					"\n\nIntentionally blocked peer-local modifiers: Challenges, Ironman/Achievements, Lucky Nations. The legacy MK1212 networking/chat experiment also remains disabled."..
					"\n\nUse this profile as an experimental multiplayer candidate, not as a claim that every Attila engine desync has been solved.";

eh:add_listener(
	"OnFrontendScreenTransition_MP_Campaign",
	"FrontendScreenTransition",
	true,
	function(context) OnFrontendScreenTransition_MP_Campaign(context) end,
	true
);
eh:add_listener(
	"OnComponentLClickUp_MP_Campaign",
	"ComponentLClickUp",
	true,
	function(context) OnComponentLClickUp_MP_Campaign(context) end,
	true
);

function OnFrontendScreenTransition_MP_Campaign(context)
	if context.string == "mp_grand_campaign" then
		tm:callback(
			function()
				CreateScriptDisclaimer();
			end, 
			0.1
		);
	end
end;

function OnComponentLClickUp_MP_Campaign(context)
	if context.string == "disclaimer_accept" or context.string == "button_home" then
		local mp_grand_campaign_uic = UIComponent(m_root:Find("mp_grand_campaign"));
		local disclaimer_uic = UIComponent(mp_grand_campaign_uic:Find("disclaimer"));

		disclaimer_uic:SetVisible(false);
	elseif context.string == "button_disclaimer" then
		local mp_grand_campaign_uic = UIComponent(m_root:Find("mp_grand_campaign"));
		local disclaimer_uic = UIComponent(mp_grand_campaign_uic:Find("disclaimer"));

		if disclaimer_uic:Visible() then
			disclaimer_uic:SetVisible(false);
		else
			disclaimer_uic:SetVisible(true);
		end
	end
end;


function CreateScriptDisclaimer()
	local mp_grand_campaign_uic = UIComponent(m_root:Find("mp_grand_campaign"));

	if not mp_grand_campaign_uic:Find("disclaimer") then
		local disclaimer_uic = UIComponent(mp_grand_campaign_uic:CreateComponent("disclaimer", "UI/campaign ui/events"));
		local disclaimer_accept_uic = UIComponent(disclaimer_uic:CreateComponent("disclaimer_accept", "UI/new/basic_toggle_accept"));
		local disclaimer_event_dilemma_uic = UIComponent(disclaimer_uic:Find("event_dilemma"));
		local disclaimer_event_standard_uic = UIComponent(disclaimer_uic:Find("event_standard"));
		local disclaimer_scroll_frame_uic = UIComponent(disclaimer_event_standard_uic:Find("scroll_frame"));
		local disclaimer_tx_title_uic = UIComponent(disclaimer_uic:Find("tx_title"));
		local disclaimer_dy_event_picture_uic = UIComponent(disclaimer_event_standard_uic:Find("dy_event_picture"));
		local disclaimer_textview_no_sub_uic = UIComponent(disclaimer_event_standard_uic:Find("textview_no_sub"));
		local disclaimer_textview_with_sub_uic = UIComponent(disclaimer_event_standard_uic:Find("textview_with_sub"));
		local disclaimer_dy_subtitle_uic = UIComponent(disclaimer_event_standard_uic:Find("dy_subtitle"));
		local disclaimer_text_uic = UIComponent(disclaimer_textview_with_sub_uic:Find("Text"));
		local button_campaign_uic = UIComponent(m_root:Find("button_campaign"));
		local curX, curY = disclaimer_uic:Position();
		local button_campaign_uicX, button_campaign_uicY = button_campaign_uic:Position();
		
		disclaimer_event_dilemma_uic:SetVisible(false);
		disclaimer_event_standard_uic:SetVisible(true);
		disclaimer_dy_event_picture_uic:SetVisible(false);
		disclaimer_textview_no_sub_uic:SetVisible(false);

		tm:callback(
			function() 
				disclaimer_uic:SetMoveable(true);
				disclaimer_uic:MoveTo(curX - 40, button_campaign_uicY - 80);
				disclaimer_uic:SetMoveable(false);
				disclaimer_event_standard_uic:Resize(505, 500);
				disclaimer_scroll_frame_uic:Resize(505, 580);
				disclaimer_textview_with_sub_uic:Resize(460, 500);

				local curX2, curY2 = disclaimer_textview_with_sub_uic:Position();
				local curX3, curY3 = disclaimer_dy_subtitle_uic:Position();
				disclaimer_textview_with_sub_uic:SetMoveable(true);
				disclaimer_textview_with_sub_uic:MoveTo(curX2, curY2 + 110);
				disclaimer_textview_with_sub_uic:SetMoveable(false);
				disclaimer_dy_subtitle_uic:SetMoveable(true);
				disclaimer_dy_subtitle_uic:MoveTo(curX3 - 5, curY3 - 240);
				disclaimer_dy_subtitle_uic:SetMoveable(false);

				disclaimer_accept_uic:SetMoveable(true);
				disclaimer_accept_uic:MoveTo(curX3 + 125, curY3 + 325);
				disclaimer_accept_uic:SetMoveable(false);
			end, 
			1
		);

		disclaimer_tx_title_uic:SetStateText("Medieval Kingdoms 1212 AD");
		disclaimer_dy_subtitle_uic:SetStateText(disclaimertitlestring);
		disclaimer_text_uic:SetStateText(disclaimerstring);
		disclaimer_uic:SetVisible(false);
	end
end
