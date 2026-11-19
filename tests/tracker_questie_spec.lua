-- #866: with Questie's own tracker on, Questie hides the game's tracker and draws the quest list as Questie_BaseFrame,
-- so the column follows that list. Questie's frame is only read: core anchors, parents and replaces nothing on it, and
-- Questie's own drag keeps working with core's hooks installed (Questie/Questie#8076, #188).
local harness = dofile("tests/tracker_host_harness.lua")

local function Under(ctx, left, line)
	local point = ctx.host.point
	return point[1] == "TOPLEFT"
		and point[2] == ctx.parent
		and point[3] == "BOTTOMLEFT"
		and point[4] == left
		and point[5] == line
end
-- Left of Questie's list: the column's top right corner on the list's top left, at UIParent coordinates.
local function Left(ctx, left, top)
	local point = ctx.host.point
	return point[1] == "TOPRIGHT"
		and point[2] == ctx.parent
		and point[3] == "BOTTOMLEFT"
		and point[4] == left
		and point[5] == top
end
-- Delivers a client event to every frame that registered it, as the client does.
local function Fire(ctx, event)
	for _, f in ipairs(ctx.frames) do
		if f.events and f.events[event] and f.scripts.OnEvent then
			f.scripts.OnEvent(f, event)
		end
	end
end

-- A stand-in for Questie_BaseFrame with Questie's own drag: OnMouseDown starts moving, and OnMouseUp reads the list's
-- left and top, clears its points and sets them again, as Questie's OnDragStop and _UpdateTrackerPosition do.
local function Questie(ctx)
	local list = ctx.env.CreateFrame("Frame", "Questie_BaseFrame", ctx.parent)
	list.left, list.top, list.width = 700, 800, 280
	list:SetHeight(200)
	local reads = {}
	list.reads = reads
	local function down(self)
		self.isMoving = true
		self:StartMoving()
	end
	local function up(self)
		local left, top = self:GetLeft(), self:GetTop()
		assert(left and top, "Questie's drag found no place for its list")
		self.isMoving = false
		self:StopMovingOrSizing()
		self:ClearAllPoints()
		self:SetPoint("TOPLEFT", ctx.parent, "BOTTOMLEFT", left, top)
		self.saved = { left, top }
	end
	list:SetScript("OnMouseDown", down)
	list:SetScript("OnMouseUp", up)
	list.down, list.up = down, up
	-- Every call core's TrackerHost makes on the list, so the spec can say they are reads and post-hooks only.
	for _, name in ipairs({
		"SetPoint",
		"ClearAllPoints",
		"SetScript",
		"SetParent",
		"SetHeight",
		"SetWidth",
		"Show",
		"Hide",
		"StartMoving",
		"StopMovingOrSizing",
		"HookScript",
		"IsShown",
		"GetLeft",
		"GetTop",
		"GetBottom",
		"GetEffectiveScale",
	}) do
		local method = list[name]
		list[name] = function(...)
			local caller = debug.getinfo(2, "S").source
			if caller:find("TrackerHost.lua", 1, true) then
				reads[name] = caller
			end
			return method(...)
		end
	end
	ctx.env.Questie_BaseFrame = list
	return list
end
local function Resize(list, height)
	list:SetHeight(height)
	list.scripts.OnSizeChanged(list, list.width, height)
end

local t = harness.new({ hostSettings = { attached = false } })
local check = t.check
check(Under(t, t.nativeRect.left, t.nativeRect.line), "with no Questie the column follows the game's tracker")

-- Questie builds its list a few seconds after login and hides the game's tracker. The quest log events that fire as it
-- fills the list find it, and the column goes under it.
local list = Questie(t)
t.showTracker(false)
Fire(t, "QUEST_LOG_UPDATE")
check(Under(t, 700, 600), "the column goes under Questie's list")
check(list.scripts.OnMouseDown == list.down, "Questie's own mouse down is untouched")
check(type(list.scripts.OnShow) == "function", "core hears the list show")
check(type(list.scripts.OnSizeChanged) == "function", "and resize")
local watcher
for _, f in ipairs(t.frames) do
	if f.events and f.events.GLOBAL_MOUSE_UP then
		watcher = f
	end
end
check(watcher and not watcher.events.QUEST_LOG_UPDATE, "once hooked, the quest log events are dropped")
-- GLOBAL_MOUSE_UP fires on every click, so it is registered only while the list is shown.
list:Hide()
check(not watcher.events.GLOBAL_MOUSE_UP, "a hidden list registers no mouse up")
list:Show()
check(watcher.events.GLOBAL_MOUSE_UP, "and showing it registers it again")

-- A quest added grows the list, and a collapsed section shrinks it: one SetPoint, no layout.
local updates = (t.first.updates or 0) + (t.second.updates or 0)
Resize(list, 400)
check(Under(t, 700, 400), "the column follows the list down as it grows")
Resize(list, 40)
check(Under(t, 700, 760), "and up when Questie collapses it")
check(t.pending() == 0 and (t.first.updates or 0) + (t.second.updates or 0) == updates, "following it is not a layout")
local height = t.host:GetHeight()
Resize(list, 800 - height + 1)
check(Left(t, 700, 800), "a list leaving no room under it puts the column left of the list, on UIParent")
Resize(list, 200)
check(Under(t, 700, 600), "and room brings it back")

-- Questie's drag, from the list or any of its lines, works with core's hooks: the drop is heard as GLOBAL_MOUSE_UP.
Fire(t, "GLOBAL_MOUSE_UP")
check(Under(t, 700, 600), "a click that does not move the list leaves the column")
list.scripts.OnMouseDown(list)
list.left, list.top = 500, 700
Fire(t, "GLOBAL_MOUSE_UP") -- the client may deliver the global release before or after the list's own
list.scripts.OnMouseUp(list)
check(list.saved and list.saved[1] == 500 and list.saved[2] == 700, "Questie's drag still saves where it was dropped")
check(Under(t, 500, 500), "and the column follows the dropped list")
list.scripts.OnMouseDown(list)
list.left, list.top = 600, 700
list.scripts.OnMouseUp(list)
Fire(t, "GLOBAL_MOUSE_UP")
check(list.saved[1] == 600 and Under(t, 600, 500), "in either order")
-- The drop compares with where the column last followed the list, not the last release: the list grows after a drop,
-- then is dragged back to that drop's bottom.
Resize(list, 400)
check(Under(t, 600, 300), "the column follows the list's growth")
list.scripts.OnMouseDown(list)
list.top = 900
list.scripts.OnMouseUp(list)
Fire(t, "GLOBAL_MOUSE_UP")
check(Under(t, 600, 500), "and a drag back to the earlier drop's bottom still moves it")
list.top = 700
Resize(list, 200)
list.left = 500
list.scripts.OnMouseDown(list)
list.scripts.OnMouseUp(list)
Fire(t, "GLOBAL_MOUSE_UP")
check(list.scripts.OnMouseUp == list.up, "Questie's own mouse up is untouched")

-- Questie hides its list with nothing to track, and the game's tracker stays hidden: the column goes to that tracker's
-- top, as with no list at all, and back under the list when it shows. Turning Questie's tracker off or on reloads the
-- UI, which the reload case below covers.
list:Hide()
check(
	Under(t, t.nativeRect.left, t.nativeRect.top),
	"a hidden Questie list puts the column at the hidden tracker's top"
)
list:Show()
check(Under(t, 500, 500), "and its showing again puts it under the list")

-- Nothing core created is anchored to the list, and core only read the list and hooked it.
for _, f in ipairs(t.frames) do
	if f ~= list then
		for _, p in pairs(f.points or {}) do
			check(p[2] ~= list, "no frame of ours is anchored to Questie's list")
		end
		check(f.parent ~= list and f.createdParent ~= list, "no frame of ours is parented to it")
	end
end
local allowed = { HookScript = 1, IsShown = 1, GetLeft = 1, GetTop = 1, GetBottom = 1, GetEffectiveScale = 1 }
for name in pairs(list.reads) do
	check(allowed[name], "core only reads and post-hooks Questie's list, not " .. name)
end

-- Combat holds the column; the layout after combat places it under the list again.
t.setCombat(true)
Resize(list, 300)
check(Under(t, 500, 500), "in combat the column holds still")
t.setCombat(false)
t.fire("PLAYER_REGEN_ENABLED")
t.drain()
check(Under(t, 500, 400), "and after combat it goes under the list")

-- A reload: Questie's list is there before the column's first layout, which finds and hooks it.
local reloaded = harness.new({ hostSettings = { attached = false }, deferReady = true })
local reloadedList = Questie(reloaded)
reloaded.showTracker(false)
reloaded.ready()
reloaded.drain()
reloaded.check(Under(reloaded, 700, 600), "after a reload the first layout puts the column under Questie's list")
Resize(reloadedList, 300)
reloaded.check(Under(reloaded, 700, 500), "and hooks it, so the column follows it from then on")

-- Questie's real drop only queues its re-anchor (QuestieCombatQueue, then _UpdateTrackerPosition): the list keeps its
-- place, cleared and set again by its stored corner, here BOTTOMLEFT, after the mouse up. A list at twice the host's
-- scale is read in the column's units, and Questie's sizer, which on a BOTTOMRIGHT list moves only its left and width,
-- is followed through OnSizeChanged.
local q = harness.new({ hostSettings = { attached = false } })
local qList = Questie(q)
q.showTracker(false)
Fire(q, "QUEST_LOG_UPDATE")
local queued = {}
qList.scripts.OnMouseUp = function(self)
	self.isMoving = false
	self:StopMovingOrSizing()
	queued[#queued + 1] = function()
		local left, bottom = self:GetLeft(), self:GetBottom()
		assert(left and bottom, "Questie's queued re-anchor found no place for its list")
		self:ClearAllPoints()
		self:SetPoint("BOTTOMLEFT", q.parent, "BOTTOMLEFT", left, bottom)
	end
end
for _, order in ipairs({ "global first", "list first" }) do
	qList.scripts.OnMouseDown(qList)
	qList.left = qList.left - 100
	if order == "global first" then
		Fire(q, "GLOBAL_MOUSE_UP")
		qList.scripts.OnMouseUp(qList)
	else
		qList.scripts.OnMouseUp(qList)
		Fire(q, "GLOBAL_MOUSE_UP")
	end
	table.remove(queued, 1)()
	q.check(Under(q, qList.left, 600), "the column is under the list after Questie's queued re-anchor, " .. order)
end
qList.effectiveScale = 2
qList.left, qList.top = 200, 400
Resize(qList, 100)
q.check(Under(q, 400, 600), "a list at another scale is read in the column's units")
qList.effectiveScale = nil
qList.left, qList.top = 600, 800
Resize(qList, 200)
qList.left, qList.width = 450, 430
qList.scripts.OnSizeChanged(qList, 430, 200)
q.check(Under(q, 450, 600), "Questie's sizer moving only the list's left is followed")

-- Questie's ready callback finds a list built with no quest log event after it, and Left follows the list too.
local late = harness.new({ hostSettings = { attached = false, placement = "left" }, deferReady = true })
local callbacks = {}
late.env.Questie = { API = {
	RegisterOnReady = function(fn)
		callbacks[#callbacks + 1] = fn
	end,
} }
late.ready()
late.drain()
late.check(#callbacks == 1, "the column asks Questie to call it back once Questie is ready")
local lateList = Questie(late)
late.showTracker(false)
callbacks[1]()
late.check(Left(late, 700, 800), "Questie's ready callback puts a Left column left of the list")
lateList.left = 500
lateList.scripts.OnMouseDown(lateList)
lateList.scripts.OnMouseUp(lateList)
Fire(late, "GLOBAL_MOUSE_UP")
late.check(Left(late, 500, 800), "and it follows a drag of the list")

print(("tracker_questie_spec: %d checks passed"):format(t.checks() + reloaded.checks() + late.checks() + q.checks()))
