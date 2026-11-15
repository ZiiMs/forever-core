-- Dev addon for tools/headless/forever_client.py. The launcher links this folder into AddOns only for its own session
-- and removes it on stop, so a player's login never loads it.
-- Config.lua is generated into an isolated session copy before the client starts. A missing config refuses readiness.
local SAFE_CHARACTER = _G.FOREVER_HEADLESS_CHARACTER
local UnitGUID = _G.UnitGUID
local UnitAffectingCombat = _G.UnitAffectingCombat
local IsResting = _G.IsResting

local function safeCharacter()
	if type(SAFE_CHARACTER) ~= "table" then
		return false, "no safe parked character configured"
	end
	if type(UnitGUID) ~= "function" or type(UnitAffectingCombat) ~= "function" then
		return false, "player identity or combat API unavailable"
	end
	local name, realm = UnitName("player")
	local guid = UnitGUID("player")
	if type(name) ~= "string" or name == "" or type(guid) ~= "string" or guid == "" then
		return false, "player identity unavailable"
	end
	if name ~= SAFE_CHARACTER.name or guid ~= SAFE_CHARACTER.guid then
		return false, "unexpected player identity"
	end
	if type(UnitIsDeadOrGhost("player")) ~= "boolean" or UnitIsDeadOrGhost("player") then
		return false, "player is dead or a ghost"
	end
	if type(UnitAffectingCombat("player")) ~= "boolean" or UnitAffectingCombat("player") then
		return false, "player is in combat"
	end
	if type(InCombatLockdown()) ~= "boolean" or InCombatLockdown() then
		return false, "combat lockdown is active"
	end
	if SAFE_CHARACTER.require_resting then
		if type(IsResting) ~= "function" or type(IsResting()) ~= "boolean" then
			return false, "resting state unavailable"
		end
		if not IsResting() then
			return false, "player is not resting at the approved park spot"
		end
	end
	return true, realm or ""
end

-- Each time the world loads, validate the parked character before taking the screenshot that tells Python the world is
-- ready.  An unsafe or unknown state produces no readiness screenshot, so no proof flow or reload can begin.
local frame = CreateFrame("Frame")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:SetScript("OnEvent", function()
	C_Timer.After(2, function()
		local safe, reason = safeCharacter()
		if not safe then
			print("FOREVER_HEADLESS_PREFLIGHT_REFUSED", reason)
			return
		end
		local marker = CreateFrame("Frame", nil, UIParent)
		marker:SetIgnoreParentScale(true)
		marker:SetFrameStrata("TOOLTIP")
		marker:SetSize(8, 8)
		marker:SetPoint("CENTER")
		local texture = marker:CreateTexture(nil, "OVERLAY")
		texture:SetAllPoints()
		texture:SetColorTexture(31 / 255, 239 / 255, 117 / 255, 1)
		local box = ChatEdit_GetActiveWindow and ChatEdit_GetActiveWindow()
		if box then
			ChatEdit_DeactivateChat(box)
		end
		Screenshot()
		C_Timer.After(0.5, function()
			marker:Hide()
			marker = nil
		end)
	end)
end)
