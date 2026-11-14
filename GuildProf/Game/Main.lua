local addonName, ns = ...

-- Addon shell: SavedVariables, events, guild binding, roster, own name,
-- slash commands. Loaded last.

local Store, Sync, Comm, Roster, Version = ns.Store, ns.Sync, ns.Comm, ns.Roster, ns.Version

function ns.Print(...)
	print("|cff33ccffGuildProf|r:", ...)
end

function ns.Debug(...)
	if ns.db and ns.db.debug then
		ns.Print("|cff888888debug|r", ...)
	end
end

-- Last protocol lines, in GuildProfDB.diag.sync: "<seconds since load> <line>".
local LOG_LINES = 80
local t0
function ns.Log(text)
	local diag = ns.db and ns.db.diag
	if not diag then
		return
	end
	diag.sync = diag.sync or {}
	local list = diag.sync
	list[#list + 1] = ("%6.1f %s"):format(GetTime() - (t0 or 0), text)
	if #list > LOG_LINES then
		table.remove(list, 1)
	end
	ns.Debug(text)
end

function ns.random(lo, hi)
	return math.random(lo, hi)
end

---------------------------------------------------------------- own name

-- Sync.OnOwnEcho learns the server's form of the player's name; kept per character.
function ns.OnOwnName(sender)
	ns.Debug("own name is", sender)
	ns.char.me = sender
end

---------------------------------------------------------------- version

-- The TOC's Version field, when the client returns one that parses.
local function tocVersion()
	local get = C_AddOns and C_AddOns.GetAddOnMetadata or GetAddOnMetadata
	if not get then
		return nil
	end
	local ok, v = pcall(get, addonName, "Version")
	if ok and Version.Parse(v) then
		return v
	end
end

-- A guild member runs a newer version: said once per version and session.
function ns.OnNewerVersion(v)
	ns.Print(("|cffff9933version %s is out|r (installed: %s). |cffffffff/gp update|r shows the download link.")
		:format(v, tostring(Version.mine)))
	ns.UI.RefreshSoon()
end

function ns.OnRecordChanged(owner)
	ns.Debug("record", owner)
	ns.UI.RefreshSoon()
end

---------------------------------------------------------------- roster

function ns.RequestRoster()
	if IsInGuild() and C_GuildInfo and C_GuildInfo.GuildRoster then
		C_GuildInfo.GuildRoster()
	end
end

local lastPrune

-- Reads the roster, then removes the records of characters no longer in
-- the guild. diag.roster shows how the client spells roster names.
local function readRoster()
	local total = GetNumGuildMembers() or 0
	local entries = {}
	for i = 1, total do
		local name, _, _, _, _, _, _, _, online = GetGuildRosterInfo(i)
		if type(name) == "string" and name ~= "" then
			entries[#entries + 1] = { name = name, online = online and true or false }
		end
	end
	Roster.Set(entries, total)
	if ns.db.diag then
		ns.db.diag.roster = ("%d/%d listed, trusted %s, first %s"):format(#entries, total,
			tostring(Roster.Trusted()), entries[1] and entries[1].name or "-")
	end
	if ns.solo then
		return
	end
	local n, what = Roster.Prune()
	if what ~= lastPrune then
		lastPrune = what
		ns.Log("prune: " .. what)
	end
	if n > 0 then
		ns.OnRecordChanged()
	end
end

-- true, false, or nil when the roster does not name this character.
function ns.IsOnline(owner)
	return Roster.Online(owner)
end

---------------------------------------------------------------- guild binding

local boundKey
local followUps

local function bindGuild()
	local key
	if IsInGuild() then
		-- The guild name alone: GetGuildInfo's realm return is nil right after
		-- login and filled later on Forever, so it cannot be part of a key.
		local name = GetGuildInfo("player")
		if not name then
			return -- not known yet; GUILD_ROSTER_UPDATE will call again
		end
		key = name
	else
		-- No guild: own professions only, nothing is sent.
		key = ""
	end
	if key == boundKey then
		return
	end
	-- Carry the player's own record over: IsInGuild() can be false for a moment at
	-- login, and recipes are only read while a profession window is open.
	local own = ns.me and Store.IsBound() and Store.Get(ns.me)
	boundKey = key
	ns.solo = key == ""
	Store.Bind(ns.db, key)
	Version.Bind(ns.db, key)
	if own then
		Store.Put(ns.me, own.rev, own.data)
	end
	-- The echo renames the record only in the table bound when it arrives:
	-- a copy left here under the guessed name would be relayed as another
	-- character's record.
	if ns.guess and ns.guess ~= ns.me then
		Store.Rename(ns.guess, ns.me)
	end
	if ns.solo then
		Roster.Clear()
	end
	ns.Debug("guild", key == "" and "(none)" or key, #Store.Owners(), "records")
	C_Timer.After(2, ns.Scan.Basic)
	-- The spellbook can still be loading at the first scans, on a first
	-- login above all: scan again a few times; nothing is sent unless the
	-- record changed.
	if not followUps then
		followUps = true
		for _, t in ipairs({ 10, 30, 90 }) do
			C_Timer.After(t, ns.Scan.Basic)
		end
	end
	if not ns.solo then
		C_Timer.After(ns.random(30, 60) / 10, Sync.Hello)
	end
	ns.UI.RefreshSoon()
end

---------------------------------------------------------------- events

local frame = CreateFrame("Frame")
local handlers = {}

handlers.ADDON_LOADED = function(name)
	-- The guild frame loads on demand.
	if name == "Blizzard_Communities" then
		ns.UI.SetupGuildTab()
		return
	end
	if name ~= addonName then
		return
	end
	GuildProfDB = type(GuildProfDB) == "table" and GuildProfDB or {}
	GuildProfCharDB = type(GuildProfCharDB) == "table" and GuildProfCharDB or {}
	ns.db, ns.char = GuildProfDB, GuildProfCharDB
	ns.db.schema = ns.db.schema or 2
	-- Diagnostics describe this session only.
	ns.db.diag = {}
	t0 = GetTime()
	Version.mine = tocVersion()
end

handlers.PLAYER_LOGIN = function()
	local baseName = UnitName("player")
	ns.baseName = baseName
	-- The record key until the server's form of the name is known.
	local name, realm = UnitFullName("player")
	ns.guess = (realm and realm ~= "") and (name .. "-" .. realm) or name
	if type(ns.char.me) == "string" and ns.char.me:sub(1, #baseName) == baseName then
		ns.me = ns.char.me
	else
		ns.me = ns.guess
	end
	C_ChatInfo.RegisterAddonMessagePrefix(Comm.PREFIX)
	ns.RequestRoster()
	bindGuild()
	ns.UI.SetupGuildTab()
end

handlers.PLAYER_GUILD_UPDATE = bindGuild

handlers.GUILD_ROSTER_UPDATE = function()
	bindGuild()
	readRoster()
	ns.UI.RefreshSoon()
end

handlers.CHAT_MSG_ADDON = function(prefix, text, channel, sender)
	Comm.OnMessage(prefix, text, channel, sender)
end

handlers.TRADE_SKILL_SHOW = function() ns.Scan.Schedule("TRADE_SKILL_SHOW") end
handlers.TRADE_SKILL_LIST_UPDATE = function() ns.Scan.Schedule("TRADE_SKILL_LIST_UPDATE") end

local basicPlanned
local function scanSoon()
	if basicPlanned then return end
	basicPlanned = true
	C_Timer.After(1, function()
		basicPlanned = false
		ns.Scan.Basic()
	end)
end

handlers.SKILL_LINES_CHANGED = scanSoon
-- A recipe learned from a trainer or a recipe item.
handlers.NEW_RECIPE_LEARNED = scanSoon
-- The spellbook finished loading or changed.
handlers.SPELLS_CHANGED = scanSoon

handlers.GET_ITEM_INFO_RECEIVED = function() ns.UI.RefreshSoon() end
-- Reagent counts and work-order boxes follow the bags.
handlers.BAG_UPDATE_DELAYED = function() ns.UI.OnBagsChanged() end

frame:SetScript("OnEvent", function(_, event, ...)
	handlers[event](...)
end)
-- An event this client does not know raises an error: register one by one.
for event in pairs(handlers) do
	if not pcall(frame.RegisterEvent, frame, event) then
		ns.unknownEvents = (ns.unknownEvents or "") .. " " .. event
	end
end

---------------------------------------------------------------- slash

SLASH_GUILDPROF1 = "/gp"
SLASH_GUILDPROF2 = "/guildprof"
SlashCmdList.GUILDPROF = function(msg)
	local cmd = (msg or ""):match("^%s*(%S*)"):lower()
	if cmd == "" then
		ns.UI.Toggle()
	elseif cmd == "status" then
		ns.Print("me:", tostring(ns.me), "| guild:", boundKey == "" and "(none)" or tostring(boundKey))
		ns.Print("spellbook:", tostring(ns.db.diag and ns.db.diag.basic))
		ns.Print("window:", tostring(ns.db.diag and ns.db.diag.window))
		ns.Print("last event:", tostring(ns.db.diag and ns.db.diag.event))
		if ns.db.diag and ns.db.diag.error then
			ns.Print("|cffff4040error:|r", ns.db.diag.error)
		end
		ns.Print("records:", #Store.Owners(), "| digest:", Store.IsBound() and Store.Digest() or "-")
		ns.Print("roster:", tostring(ns.db.diag and ns.db.diag.roster), "| prune:", tostring(lastPrune))
		local older = {}
		for _, owner in ipairs(Store.Owners()) do
			local v = Version.Outdated(owner)
			if v then
				older[#older + 1] = owner .. " (" .. (v == Version.NONE and "old" or v) .. ")"
			end
		end
		ns.Print("version:", tostring(Version.mine), "| newer in the guild:", tostring(Version.newest),
			"| older:", #older > 0 and table.concat(older, ", ") or "-")
		ns.Print("sent:", Comm.stats.sent, "received:", Comm.stats.received, "dropped:",
			Comm.stats.dropped, "queued:", Comm.Pending())
		if ns.unknownEvents then
			ns.Print("events not registered:", ns.unknownEvents)
		end
	elseif cmd == "update" then
		ns.UI.ShowLink()
	elseif cmd == "sync" then
		ns.Scan.Basic()
		Sync.Hello()
		ns.Print("sync requested")
	elseif cmd == "scan" then
		ns.Scan.Basic()
		ns.Scan.Window()
		ns.Print("scanned")
	elseif cmd == "debug" then
		ns.db.debug = not ns.db.debug
		ns.Print("debug", ns.db.debug and "on" or "off")
	else
		ns.Print("/gp, /gp status, /gp sync, /gp scan, /gp update, /gp debug")
	end
end
