-- Lua 5.1 fixture for the interface-only character safety gate.
local path = "tools/headless/character_preflight.lua"

local function run(label, dead, combat, locked, succeeds)
	_G.UnitName = function()
		return "Tester", "Realm"
	end
	_G.UnitGUID = function()
		return "Player-1-2-3"
	end
	_G.UnitIsDeadOrGhost = function()
		return dead
	end
	_G.UnitAffectingCombat = function()
		return combat
	end
	_G.InCombatLockdown = function()
		return locked
	end
	local check = assert(loadfile(path))()
	local ok = pcall(check)
	assert(ok == succeeds, label .. " preflight result")
end

run("parked", false, false, false, true)
run("dead", true, false, false, false)
run("combat", false, true, false, false)
run("lockdown", false, false, true, false)

_G.UnitGUID = nil
local ok = pcall(function()
	assert(loadfile(path))()
end)
assert(not ok, "missing identity API fails closed")
print("character preflight: parked, dead, combat, lockdown and unknown fixtures pass")
