-- Interface-only safety gate for automated addon proofs.
-- The harness runs this after entering the world and before any proof reload.
local function required(name)
    local value = _G[name]
    assert(type(value) == "function", "character preflight unavailable: " .. name)
    return value
end

local unitName = required("UnitName")
local unitGUID = required("UnitGUID")
local isDeadOrGhost = required("UnitIsDeadOrGhost")
local affectingCombat = required("UnitAffectingCombat")
local lockdown = required("InCombatLockdown")

return function()
    local name, realm = unitName("player")
    local guid = unitGUID("player")
    assert(type(name) == "string" and name ~= "", "character preflight unknown: player name")
    assert(type(guid) == "string" and guid ~= "", "character preflight unknown: player identity")
    assert(type(isDeadOrGhost("player")) == "boolean", "character preflight unknown: dead state")
    assert(isDeadOrGhost("player") == false, "character preflight unsafe: player is dead or a ghost")
    assert(type(affectingCombat("player")) == "boolean", "character preflight unknown: combat state")
    assert(affectingCombat("player") == false, "character preflight unsafe: player is in combat")
    assert(type(lockdown()) == "boolean", "character preflight unknown: combat lockdown")
    assert(lockdown() == false, "character preflight unsafe: combat lockdown is active")
    print("CHARACTER_PREFLIGHT_SAFE", name, realm or "", guid)
    return true
end
