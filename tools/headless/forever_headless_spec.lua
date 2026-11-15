-- Lua 5.1 fixtures for the startup handshake. A missing parked-character configuration must never signal readiness.
local source = assert(io.open("tools/headless/!!ForeverHeadless/ForeverHeadless.lua")):read("*a")

local function run(name, guid, map, x, y, screenshot)
	local events, callback = {}, nil
	_G.CreateFrame = function()
		return {
			RegisterEvent = function(_, event)
				events[#events + 1] = event
			end,
			SetScript = function(_, _, fn)
				callback = fn
			end,
		}
	end
	_G.C_Timer = {
		After = function(_, fn)
			fn()
		end,
	}
	_G.UnitName = function()
		return name, "Realm"
	end
	_G.UnitGUID = function()
		return guid
	end
	_G.UnitIsDeadOrGhost = function()
		return false
	end
	_G.UnitAffectingCombat = function()
		return false
	end
	_G.InCombatLockdown = function()
		return false
	end
	_G.UnitPosition = function()
		return map, x, y
	end
	_G.ChatEdit_GetActiveWindow = function()
		return nil
	end
	_G.Screenshot = function()
		screenshot.count = screenshot.count + 1
	end
	_G.print = function() end
	assert(loadstring(source))()
	assert(events[1] == "PLAYER_ENTERING_WORLD", "registers world readiness")
	callback(nil, "PLAYER_ENTERING_WORLD")
end

local screenshot = { count = 0 }
run("Tester", "Player-1-2-3", 0, 1, 1, screenshot)
assert(screenshot.count == 0, "missing parked-character configuration refuses readiness")
print("forever headless: missing parked character refuses readiness")
