-- Dev addon for tools/headless/forever_client.py. The launcher links this folder into AddOns only for its own session
-- and removes it on stop, so a player's login never loads it.
-- The expected parked character is deliberately configured only after the owner confirms a safe character.  A missing
-- expectation refuses an automatic proof instead of treating an arbitrary living character as safe.
local SAFE_CHARACTER = nil -- { name = "Barry", guid = "Player-...", map = 0, x = 0, y = 0 }

local function safeCharacter()
	if type(SAFE_CHARACTER) ~= "table" then
		return false, "no safe parked character configured"
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
	if type(UnitPosition) ~= "function" then
		return false, "player position unavailable"
	end
	local map, x, y = UnitPosition("player")
	if map ~= SAFE_CHARACTER.map or type(x) ~= "number" or type(y) ~= "number" then
		return false, "unexpected player position"
	end
	if math.abs(x - SAFE_CHARACTER.x) > 0.001 or math.abs(y - SAFE_CHARACTER.y) > 0.001 then
		return false, "player is not at the parked position"
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
		local box = ChatEdit_GetActiveWindow and ChatEdit_GetActiveWindow()
		if box then
			ChatEdit_DeactivateChat(box)
		end
		Screenshot()
	end)
end)
