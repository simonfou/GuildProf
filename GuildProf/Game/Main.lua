local addonName, ns = ...

-- Addon shell: SavedVariables, events, guild binding, roster, own name,
-- slash commands. Loaded last.

local Store, Sync, Comm = ns.Store, ns.Sync, ns.Comm

ns.roster = {}

function ns.Print(...)
	print("|cff33ccffGuildProf|r:", ...)
end

function ns.Debug(...)
	if ns.db and ns.db.debug then
		ns.Print("|cff888888debug|r", ...)
	end
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

local function readRoster()
	local r = {}
	for i = 1, GetNumGuildMembers() do
		local name, _, _, _, _, _, _, _, online = GetGuildRosterInfo(i)
		if type(name) == "string" then
			r[name] = online and true or false
		end
	end
	ns.roster = r
end

-- true, false, or nil when the roster names this character another way.
function ns.IsOnline(owner)
	local v = ns.roster[owner]
	if v ~= nil then
		return v
	end
	if Ambiguate then
		local short = Ambiguate(owner, "none")
		v = ns.roster[short]
	end
	return v
end

---------------------------------------------------------------- guild binding

local boundKey

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
	if own then
		Store.Put(ns.me, own.rev, own.data)
	end
	ns.Debug("guild", key == "" and "(none)" or key, #Store.Owners(), "records")
	C_Timer.After(2, ns.Scan.Basic)
	if not ns.solo then
		C_Timer.After(ns.random(80, 150) / 10, Sync.Hello)
	end
	ns.UI.RefreshSoon()
end

---------------------------------------------------------------- events

local frame = CreateFrame("Frame")
local handlers = {}

handlers.ADDON_LOADED = function(name)
	if name ~= addonName then
		return
	end
	GuildProfDB = type(GuildProfDB) == "table" and GuildProfDB or {}
	GuildProfCharDB = type(GuildProfCharDB) == "table" and GuildProfCharDB or {}
	ns.db, ns.char = GuildProfDB, GuildProfCharDB
	ns.db.schema = ns.db.schema or 2
	-- Diagnostics describe this session only.
	ns.db.diag = {}
end

handlers.PLAYER_LOGIN = function()
	local baseName = UnitName("player")
	ns.baseName = baseName
	if type(ns.char.me) == "string" and ns.char.me:sub(1, #baseName) == baseName then
		ns.me = ns.char.me
	else
		local name, realm = UnitFullName("player")
		ns.me = (realm and realm ~= "") and (name .. "-" .. realm) or name
	end
	C_ChatInfo.RegisterAddonMessagePrefix(Comm.PREFIX)
	ns.RequestRoster()
	bindGuild()
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
handlers.SKILL_LINES_CHANGED = function()
	if basicPlanned then return end
	basicPlanned = true
	C_Timer.After(1, function()
		basicPlanned = false
		ns.Scan.Basic()
	end)
end

handlers.GET_ITEM_INFO_RECEIVED = function() ns.UI.RefreshSoon() end

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
		ns.Print("sent:", Comm.stats.sent, "received:", Comm.stats.received, "dropped:",
			Comm.stats.dropped, "queued:", Comm.Pending())
		if ns.unknownEvents then
			ns.Print("events not registered:", ns.unknownEvents)
		end
	elseif cmd == "sync" then
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
		ns.Print("/gp, /gp status, /gp sync, /gp scan, /gp debug")
	end
end
