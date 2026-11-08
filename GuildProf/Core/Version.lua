local _, ns = ...

-- Pure Lua 5.1: addon versions across the guild. Each H goes out right
-- after a V carrying the sender's version ("1.2.3"); an H that arrives
-- without one comes from a copy older than these announcements. Versions
-- are kept per guild in the SavedVariables, so the window shows who runs
-- an older copy even while they are offline.

local Version = {}
ns.Version = Version

Version.URL = "https://github.com/simonfou/GuildProf/releases/latest"
Version.NONE = "" -- a copy older than the announcements

local PAIR_WINDOW = 10 -- seconds between a sender's V and its H

Version.mine = nil   -- this copy's version (the TOC's), or nil
Version.newest = nil -- the newest version heard, when newer than this copy's

local known      -- owner -> version or NONE, for the bound guild
local lastV = {} -- sender -> time of its last V

function Version.Parse(v)
	local a, b, c = tostring(v):match("^(%d+)%.(%d+)%.(%d+)$")
	if a then
		return { tonumber(a), tonumber(b), tonumber(c) }
	end
end

-- -1, 0 or 1. NONE and anything that does not parse sort below every version.
function Version.Compare(x, y)
	local a, b = Version.Parse(x), Version.Parse(y)
	if not a or not b then
		if a then
			return 1
		elseif b then
			return -1
		end
		return 0
	end
	for i = 1, 3 do
		if a[i] ~= b[i] then
			return a[i] < b[i] and -1 or 1
		end
	end
	return 0
end

function Version.Bind(db, guildKey)
	db.guilds = db.guilds or {}
	local g = db.guilds[guildKey]
	if type(g) ~= "table" then
		g = {}
		db.guilds[guildKey] = g
	end
	if type(g.versions) ~= "table" then
		g.versions = {}
	end
	for owner, v in pairs(g.versions) do
		if type(v) ~= "string" then
			g.versions[owner] = nil
		end
	end
	known = g.versions
end

-- A V from `sender`. Returns Compare(v, this copy's version), or nil when
-- there is nothing to compare.
function Version.OnV(sender, v)
	if not Version.Parse(v) then
		return nil
	end
	lastV[sender] = GetTime()
	if known then
		known[sender] = v
	end
	local mine = Version.mine
	if not mine then
		return nil
	end
	local c = Version.Compare(v, mine)
	if c > 0 and (not Version.newest or Version.Compare(v, Version.newest) > 0) then
		Version.newest = v
		if ns.OnNewerVersion then
			ns.OnNewerVersion(v)
		end
	end
	return c
end

-- An H from `sender`: without a V just before it, the sender runs a copy
-- older than the announcements.
function Version.OnHello(sender)
	local t = lastV[sender]
	if known and (not t or GetTime() - t > PAIR_WINDOW) then
		known[sender] = Version.NONE
	end
end

-- The owner's last known version, NONE, or nil when never heard.
function Version.Of(owner)
	if owner == ns.me then
		return Version.mine
	end
	return known and known[owner]
end

-- The newest version known: heard, or this copy's.
function Version.Latest()
	return Version.newest or Version.mine
end

-- The owner's version when it is older than the newest known, else nil.
function Version.Outdated(owner)
	local v, latest = Version.Of(owner), Version.Latest()
	if v and latest and Version.Compare(v, latest) < 0 then
		return v
	end
end

function Version.Forget(owner)
	if known then
		known[owner] = nil
	end
end
