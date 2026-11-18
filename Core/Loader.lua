-- ForeverCoreLoader, schema 1: the one registry every embedded ForeverCore copy in a client shares. A consumer's
-- Begin.lua calls Begin(folder, build, digest), its wrapped files call copy:Define(function(...) ... end), and its
-- End.lua calls copy:Seal(). Registration and definition run no runtime code. At PLAYER_LOGIN the loader
-- elects the highest sealed build, including standalone, and runs only that copy's chunks into a fresh
-- namespace, and publishes its facade once. A host first loaded after login activates at its own ADDON_LOADED, and
-- PLAYER_ENTERING_WORLD activates a session whose PLAYER_LOGIN the loader missed; Trace() records which one ran.
--
-- Schema 1 is immutable. A later schema is a new global name (ForeverCoreLoader2), never an upgrade of this table: an
-- older copy must never call a newer loader's methods or the reverse. The first copy to load owns the registry for the
-- session.
local SCHEMA = 1

if rawget(_G, "ForeverCoreLoader") ~= nil then
	return
end

local Loader = { schema = SCHEMA }
_G.ForeverCoreLoader = Loader

local state = {
	activated = false,
	loggedIn = false,
	loginRan = false,
	booting = false,
	readyRunning = false,
	candidates = {},
	byFolder = {},
	rejections = {},
	onReady = {},
	stores = {},
	storesByFolder = {},
	trace = {},
	seen = {},
}

-- The loader's own record of what happened, in order: each copy's begin, seal and rejection, the events that drove
-- activation and how the boot ended. A copy that registered but never ran is otherwise silent (Selected and Error
-- both nil), so this is what an in-game check reads to see which step was reached. Bounded, oldest dropped first.
local TRACE_LIMIT = 200
local function Trace(kind, folder, detail)
	local trace = state.trace
	if #trace >= TRACE_LIMIT then
		table.remove(trace, 1)
	end
	trace[#trace + 1] = {
		kind = kind,
		folder = folder ~= nil and tostring(folder) or nil,
		detail = detail ~= nil and tostring(detail) or nil,
		time = type(GetTime) == "function" and GetTime() or nil,
	}
end

local function Record(folder, reason)
	state.rejections[#state.rejections + 1] = { folder = tostring(folder or "?"), reason = reason }
	Trace("reject", folder or "?", reason)
	return false, reason
end

-- The build is baked at release as major * 1000000 + minor * 1000 + patch. A value outside that shape is a broken
-- package, so the copy is rejected at Begin instead of competing with a number no release could have produced.
local function ValidBuild(build)
	return type(build) == "number" and build == build and build >= 1000000 and build % 1 == 0
end

-- An embedded copy lives under the consumer's Libs folder. The standalone participant keeps the top-level addon
-- layout its TOC and media already use, so its root is the addon folder itself.
local function Root(folder)
	if folder == "ForeverCore" then
		return "Interface\\AddOns\\ForeverCore"
	end
	return "Interface\\AddOns\\" .. folder .. "\\Libs\\ForeverCore"
end

-- Consumer callbacks are not boot chunks. Their failures must reach the client's own error handler (BugSack and the
-- script-error display), the way any other addon's startup error does. Recording one as well keeps it visible to
-- `/fcore` when the client has no handler; each kind of callback has its own field so a good boot stays readable.
local function Protected(field, callback)
	local handler = type(geterrorhandler) == "function" and geterrorhandler() or nil
	local failure
	local ok, err
	if type(handler) == "function" then
		ok, err = xpcall(callback, function(message)
			-- The client handler commonly returns nothing. Capture the original error before calling it so the record
			-- never degrades to the handler's return value.
			failure = tostring(message)
			return handler(message)
		end)
	else
		ok, err = pcall(callback)
	end
	if not ok then
		state[field] = state[field] or failure or tostring(err)
	end
	return ok, err
end

-- One login per session, after activation and its ready callbacks. Legacy and a failed boot have no namespace, so
-- they never run it. A converted runtime defines namespace.Login; a copy that does not is a broken package.
local function CallLogin()
	if state.loginRan or state.namespace == nil then
		return
	end
	state.loginRan = true
	local login = state.namespace.Login
	if type(login) ~= "function" then
		state.loginError = state.loginError
			or ("ForeverCore copy " .. state.namespace.folder .. " published no namespace Login")
		return false, state.loginError
	end
	return Protected("loginError", login)
end

-- Logged in means PLAYER_LOGIN has fired in this session, whether this loader saw it or the client says so. A copy
-- whose file first loads after login (an addon enabled mid-session, LoadAddOn) never sees PLAYER_LOGIN.
-- PLAYER_LOGIN and ADDON_LOADED only drive activation. PLAYER_ENTERING_WORLD and VARIABLES_LOADED are also recorded
-- once seen (Loader.Seen), because a runtime that boots after either has fired must not wait for it again: an
-- EventUtil.ContinueAfterAllEvents registered after the event never completes.
local ACTIVATION_EVENTS = { "PLAYER_LOGIN", "ADDON_LOADED" }
local WORLD_EVENTS = { "PLAYER_ENTERING_WORLD", "VARIABLES_LOADED" }

local function LoggedIn()
	local isLoggedIn = rawget(_G, "IsLoggedIn")
	return state.loggedIn or (type(isLoggedIn) == "function" and isLoggedIn() == true)
end

-- Activation and its one login, from whichever event reached the loader first. Activation needs only sealed copies,
-- so every path below waits for a host's files to have loaded (its ADDON_LOADED) or for login itself.
local function ActivateNow(reason, folder)
	Trace("activate", folder, reason)
	state.loggedIn = true
	if state.frame ~= nil then
		for _, event in ipairs(ACTIVATION_EVENTS) do
			state.frame:UnregisterEvent(event)
		end
	end
	Loader.Activate()
	CallLogin()
end

-- The one loading frame, created by the first Begin. Every copy shares it, so a second loader copy adds no event.
-- PLAYER_LOGIN is the normal path. A host loaded after login activates at its own ADDON_LOADED, once its files and
-- SavedVariables are in. PLAYER_ENTERING_WORLD follows PLAYER_LOGIN on every login and reload, so a session in which
-- this frame missed PLAYER_LOGIN still activates there, and the trace says so.
local function EnsureLoginFrame()
	if state.frame ~= nil or type(CreateFrame) ~= "function" then
		return
	end
	local frame = CreateFrame("Frame")
	state.frame = frame
	for _, event in ipairs(ACTIVATION_EVENTS) do
		frame:RegisterEvent(event)
	end
	if LoggedIn() then
		-- Only a load-on-demand host first loads after login, and the client loads it once the world is entered.
		for _, event in ipairs(WORLD_EVENTS) do
			state.seen[event] = true
		end
	else
		for _, event in ipairs(WORLD_EVENTS) do
			frame:RegisterEvent(event)
		end
	end
	frame:SetScript("OnEvent", function(_, event, name, ...)
		if event == "PLAYER_ENTERING_WORLD" or event == "VARIABLES_LOADED" then
			-- Recorded before any activation below, so the runtime it boots already sees this event as past.
			state.seen[event] = true
			if event == "PLAYER_ENTERING_WORLD" then
				state.worldEntry = { name, ... }
			end
			frame:UnregisterEvent(event)
		end
		if state.activated then
			return
		end
		if event == "PLAYER_LOGIN" then
			-- All startup copies and account globals are available before election.
			ActivateNow("PLAYER_LOGIN")
		elseif event == "ADDON_LOADED" then
			if state.byFolder[name] ~= nil and LoggedIn() then
				ActivateNow("ADDON_LOADED after login", name)
			end
		elseif event == "PLAYER_ENTERING_WORLD" then
			ActivateNow("PLAYER_ENTERING_WORLD without PLAYER_LOGIN")
		end
	end)
end

local methods = {}

-- One wrapped file. Defining is registration only; the chunk runs at activation, in the order the TOC listed it.
function methods:Define(chunk)
	if self.rejected ~= nil then
		return false, self.rejected
	end
	if self.sealed then
		return false, "sealed"
	end
	if type(chunk) ~= "function" then
		self.rejected = "chunk"
		return Record(self.folder, "chunk")
	end
	self.chunks[#self.chunks + 1] = chunk
	return self
end

-- The End.lua marker. Only a sealed copy can be elected, so a truncated package loses without running anything.
function methods:Seal()
	if self.rejected ~= nil then
		return false, self.rejected
	end
	if self.sealed then
		return false, "sealed"
	end
	if #self.chunks == 0 then
		self.rejected = "empty"
		return Record(self.folder, "empty")
	end
	self.sealed = true
	Trace("seal", self.folder, #self.chunks)
	return true
end

local function Rejected(folder, reason, build, digest)
	Record(folder, reason)
	return setmetatable({
		folder = tostring(folder or "?"),
		build = build,
		digest = digest,
		root = "",
		chunks = {},
		sealed = false,
		rejected = reason,
	}, { __index = methods })
end

-- A legacy table is any ForeverCore that predates this loader schema. It is adopted as it is, never neutralised:
-- its hooks and named frames cannot be undone, so a second runtime must not start beside it.
local function LegacyCore()
	local core = rawget(_G, "ForeverCore")
	if type(core) == "table" and core.loaderSchema ~= SCHEMA then
		return core
	end
end

-- The installed standalone's own version, for the report. A table published before this loader has no build field.
local function LegacyVersion()
	local addons = rawget(_G, "C_AddOns")
	if type(addons) == "table" and type(addons.GetAddOnMetadata) == "function" then
		local ok, version = pcall(addons.GetAddOnMetadata, "ForeverCore", "Version")
		if ok and type(version) == "string" then
			return version
		end
	end
end

-- What every embedding consumer's ready step uses: API 2, Register and the tracker line with SetInteractive. One rule
-- for every mode: a legacy table that fails it is not adopted (a second runtime cannot start beside it, so the session
-- fails naming its version), and an elected copy that fails it is refused before its Start.
local CONSUMER_API = 2
local function ServesConsumers(core)
	local line = core.TrackerLine
	return core.API == CONSUMER_API
		and type(core.Register) == "function"
		and type(line) == "table"
		and type(line.SetInteractive) == "function"
end

-- A consumer callback is not a boot chunk: it runs after the winner owns the session. One failure is reported and
-- recorded without stopping the next callback.
local function CallReady(callback)
	return Protected("callbackError", function()
		return callback(state.facade, Loader.Selected())
	end)
end

-- Registration order is run order. A callback that registers another OnReady while this loop runs queues it after
-- the callbacks already waiting, rather than running it ahead of them.
local function RunReady()
	if state.readyRan then
		return
	end
	state.readyRan = true
	state.readyRunning = true
	local index = 1
	while index <= #state.onReady do
		CallReady(state.onReady[index])
		index = index + 1
	end
	state.onReady = {}
	state.readyRunning = false
end

-- Runs the winner's chunks into one fresh namespace. Only this function may set the global facade, and only once.
-- Each wrapped file is called with the same varargs the standalone main chunk sees: the fixed identity "ForeverCore",
-- then the namespace. The namespace carries its mode before the first chunk and the runtime's explicit Start runs
-- before anything is published, so a failed Start leaves no facade.
local function Boot(copy)
	local namespace = { folder = copy.folder, root = copy.root, copy = copy }
	namespace.mode = copy.standalone and "standalone" or "elected"
	for index = 1, #copy.chunks do
		copy.chunks[index]("ForeverCore", namespace)
	end
	-- Everything that can be checked without running the runtime is checked before Start, which installs hooks and
	-- frames that cannot be undone: a copy that fails here leaves the client untouched.
	local start = namespace.Start
	if type(start) ~= "function" then
		error("ForeverCore copy " .. copy.folder .. " published no namespace Start", 0)
	end
	if type(namespace.Login) ~= "function" then
		error("ForeverCore copy " .. copy.folder .. " published no namespace Login", 0)
	end
	local facade = namespace.ForeverCore
	if type(facade) ~= "table" then
		error("ForeverCore copy " .. copy.folder .. " published no namespace facade", 0)
	end
	if not ServesConsumers(facade) then
		error("ForeverCore copy " .. copy.folder .. " published a facade the consumers cannot use", 0)
	end
	if facade.loaderSchema ~= nil and facade.loaderSchema ~= SCHEMA then
		error("ForeverCore copy " .. copy.folder .. " published an incompatible loader schema", 0)
	end
	if facade.build ~= nil and facade.build ~= copy.build then
		error("ForeverCore copy " .. copy.folder .. " published a build that is not the sealed build", 0)
	end
	local existing = rawget(_G, "ForeverCore")
	if existing ~= nil and existing ~= facade then
		error("ForeverCore copy " .. copy.folder .. " found another ForeverCore already published", 0)
	end
	start()
	if namespace.ForeverCore ~= facade then
		error("ForeverCore copy " .. copy.folder .. " replaced its facade during Start", 0)
	end
	local published = rawget(_G, "ForeverCore")
	if published ~= nil and published ~= facade then
		error("ForeverCore copy " .. copy.folder .. " found another ForeverCore already published", 0)
	end
	if published == nil then
		_G.ForeverCore = facade
	end
	if facade.loaderSchema == nil then
		facade.loaderSchema = SCHEMA
	end
	if facade.build == nil then
		facade.build = copy.build
	end
	state.namespace = namespace
	state.facade = facade
end

-- The election picks the highest sealed build. Two copies at that highest build with different content digests are
-- not interchangeable, so the loader refuses to choose between them: no folder name or load order is a reason to
-- boot one over the other. Equal builds with the same digest (including no digest) are the same package. A digest is
-- required by the final packaging contract; while it is optional here, a missing digest is not proof of equal bytes.
local function Elect()
	local bestBuild
	local firstDigest
	local digestsDiffer = false
	for _, copy in ipairs(state.candidates) do
		if copy.sealed and copy.rejected == nil then
			if bestBuild == nil or copy.build > bestBuild then
				bestBuild = copy.build
				firstDigest = copy.digest
				digestsDiffer = false
			elseif copy.build == bestBuild and copy.digest ~= firstDigest then
				digestsDiffer = true
			end
		end
	end
	if bestBuild == nil then
		return nil
	end
	local tied = {}
	for _, copy in ipairs(state.candidates) do
		if copy.sealed and copy.rejected == nil and copy.build == bestBuild then
			tied[#tied + 1] = copy
		end
	end
	if not digestsDiffer then
		return tied[1]
	end
	-- Every copy at the tied build is diagnosed, including two that share one digest: the set as a whole is the
	-- conflict, and a report that names only the first of a repeated digest hides a candidate.
	for _, copy in ipairs(tied) do
		Record(copy.folder, "tie-conflict")
	end
	state.error = "conflicting ForeverCore copies at build " .. bestBuild
	return nil
end

-- One activation per session, and one boot inside it. A failing winner is terminal: its chunks may already have
-- installed irreversible hooks, so a lower copy is never started over them.
function Loader.Activate()
	if state.activated then
		return state.facade
	end
	state.activated = true
	local legacy = state.legacy or LegacyCore()
	if legacy ~= nil then
		state.legacy = legacy
		local version = LegacyVersion()
		if not ServesConsumers(legacy) then
			state.error = "the installed ForeverCore "
				.. tostring(version or "standalone")
				.. " is too old for the embedded copies; update or disable it"
			Trace("legacy", "ForeverCore", "incompatible " .. tostring(version))
			RunReady()
			return nil
		end
		state.facade = legacy
		state.selection = { mode = "legacy", core = legacy, version = version }
		Trace("legacy", "ForeverCore", version)
		RunReady()
		return legacy
	end
	local chosen = Elect()
	if chosen == nil then
		state.error = state.error or "no sealed ForeverCore copy"
		Trace("boot", nil, state.error)
		RunReady()
		return nil
	end
	state.booting = true
	local ok, err = pcall(Boot, chosen)
	state.booting = false
	if ok then
		state.selection = {
			mode = chosen.standalone and "standalone" or "elected",
			build = chosen.build,
			folder = chosen.folder,
			root = chosen.root,
			core = state.facade,
		}
	else
		state.error = tostring(err)
		state.selection = nil
	end
	Trace("boot", chosen.folder, ok and "ok" or state.error)
	RunReady()
	return state.facade
end

-- A copy begins once, before PLAYER_LOGIN, and registers without side effects. A late begin is rejected: a runtime
-- that has already booted cannot be replaced in place. Under an adopted legacy table a later copy may still register,
-- because nothing of it will ever run.
function Loader.Begin(folder, build, digest)
	if type(folder) ~= "string" or folder == "" then
		return Rejected(folder, "folder", build, digest)
	end
	if digest ~= nil and (type(digest) ~= "string" or digest == "") then
		return Rejected(folder, "digest", build, digest)
	end
	if state.legacy == nil then
		state.legacy = LegacyCore()
		-- 1.8 is already loaded at the first consumer's file load. Activating it now means that consumer's OnReady
		-- runs inside the same file load, which is where 1.8's Register and TrackerSection use already works.
		if state.legacy ~= nil then
			Loader.Activate()
		end
	end
	if state.activated and state.legacy == nil then
		return Rejected(folder, "late", build, digest)
	end
	if not ValidBuild(build) then
		return Rejected(folder, "build", build, digest)
	end
	if state.byFolder[folder] ~= nil then
		return Rejected(folder, "duplicate", build, digest)
	end
	local copy = setmetatable({
		folder = folder,
		build = build,
		digest = digest,
		root = Root(folder),
		chunks = {},
		sealed = false,
		standalone = folder == "ForeverCore",
	}, { __index = methods })
	state.byFolder[folder] = copy
	state.candidates[#state.candidates + 1] = copy
	Trace("begin", folder, build)
	EnsureLoginFrame()
	return copy
end

-- Ready callbacks are consumer files that cannot touch Core until activation. Registration order is run order, and
-- a registration made after activation runs at once. A registration made from inside a ready callback queues behind
-- the callbacks already waiting. One callback's error is reported and recorded without stopping the next.
function Loader.OnReady(callback)
	if type(callback) ~= "function" then
		error("ForeverCoreLoader.OnReady: function expected", 2)
	end
	if state.activated and not state.booting and not state.readyRunning then
		return CallReady(callback)
	end
	state.onReady[#state.onReady + 1] = callback
	return true
end

-- The saved-variable seam. The loader retains only the folder and the explicit account SavedVariables global name; it
-- never captures the table, accepts a getter, looks the name up, or applies any migration policy. The elected runtime
-- resolves the name with rawget(_G, name) at reconciliation, so a registration before SavedVariables arrive and a
-- later replacement are both valid. Strategy belongs to the replaceable runtime, not this schema.
function Loader.OfferStore(folder, globalName)
	if type(folder) ~= "string" or folder == "" then
		return Record(folder, "store-folder")
	end
	if type(globalName) ~= "string" or globalName == "" then
		return Record(folder, "store-name")
	end
	-- The converted standalone repeats its generated offer when its runtime chunk boots.
	local existing = state.storesByFolder[folder]
	if existing ~= nil and existing.globalName == globalName then
		return true
	end
	-- Only login closes offers, including those from a generated standalone package.
	if state.loggedIn then
		return Record(folder, "late")
	end
	if state.storesByFolder[folder] ~= nil then
		return Record(folder, "duplicate")
	end
	local entry = { folder = folder, globalName = globalName }
	state.stores[#state.stores + 1] = entry
	state.storesByFolder[folder] = entry
	return true
end

-- The runtime resolves each offered name against the live globals at reconciliation. Entries are returned in offer
-- order with no lookup, copy, validation of the current value, or choice.
function Loader.Offers()
	local out = {}
	for index, entry in ipairs(state.stores) do
		out[index] = { folder = entry.folder, globalName = entry.globalName }
	end
	return out
end

-- Every registered copy, in Begin order. The diagnostic path needs the installed versions even when the highest one
-- never booted, and the runtime needs the winning copy's build for state provenance.
function Loader.Candidates()
	local out = {}
	for index, copy in ipairs(state.candidates) do
		out[index] = {
			folder = copy.folder,
			build = copy.build,
			digest = copy.digest,
			root = copy.root,
			sealed = copy.sealed == true,
			standalone = copy.standalone == true,
			rejected = copy.rejected,
		}
	end
	return out
end

function Loader.Selected()
	if not state.activated or state.selection == nil then
		return nil
	end
	local selection = state.selection
	return {
		mode = selection.mode,
		version = selection.version,
		build = selection.build,
		folder = selection.folder,
		root = selection.root,
		core = selection.core,
	}
end

function Loader.Namespace()
	return state.namespace
end

function Loader.Facade()
	return state.facade
end

-- The boot error only. Consumer callback and runtime login failures are separate records, because the runtime itself
-- may have booted cleanly (core#509).
function Loader.Error()
	return state.error
end

function Loader.CallbackError()
	return state.callbackError
end

function Loader.LoginError()
	return state.loginError
end

function Loader.Rejections()
	local out = {}
	for index, rejection in ipairs(state.rejections) do
		out[index] = { folder = rejection.folder, reason = rejection.reason }
	end
	return out
end

-- The loader's ordered record (see Trace above), copied so a caller cannot change it.
function Loader.Trace()
	local out = {}
	for index, entry in ipairs(state.trace) do
		out[index] = { kind = entry.kind, folder = entry.folder, detail = entry.detail, time = entry.time }
	end
	return out
end

-- Whether PLAYER_ENTERING_WORLD or VARIABLES_LOADED has already fired this session, as the loading frame saw it. The
-- runtime's waits skip an event that is already past instead of waiting for one that will not come again.
function Loader.Seen(event)
	return state.seen[event] == true
end

-- The arguments of the first PLAYER_ENTERING_WORLD the loading frame saw (isInitialLogin, isReloadingUi), for a
-- runtime booted after it that needs to know which kind of entry this session began with.
function Loader.WorldEntry()
	local entry = state.worldEntry
	if entry ~= nil then
		return entry[1], entry[2]
	end
end
