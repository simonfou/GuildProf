local _, ns = ...

-- Pure Lua 5.1: the guild roster, matched against record owners, and the
-- removal of records whose characters left the guild.
--
-- Record owners carry the addon-message sender's spelling ("First Surname"
-- on Forever); the roster may spell a name another way, so both sides are
-- compared through a few forms. Removal only happens on a roster that
-- lists every member and finds the player in it.

local Store = ns.Store
local Roster = {}
ns.Roster = Roster

local index    -- name form -> online (true / false), nil before a roster
local exact    -- roster names as the roster spells them
local complete -- the roster listed every member

-- Spellings of one name: as given, with hyphens as spaces, and the part
-- before the first hyphen (a realm suffix).
function Roster.Forms(name)
	local list = { name, (name:gsub("%-", " ")) }
	local before = name:match("^(.-)%-")
	if before and before ~= "" then
		list[#list + 1] = before
	end
	return list
end

-- entries: array of { name = string, online = bool }; total: the member
-- count the client reports (offline members included).
function Roster.Set(entries, total)
	index, exact = {}, {}
	for _, e in ipairs(entries) do
		exact[e.name] = true
		for _, f in ipairs(Roster.Forms(e.name)) do
			if index[f] == nil or e.online then
				index[f] = e.online and true or false
			end
		end
	end
	complete = total > 0 and #entries == total
end

function Roster.Clear()
	index, exact, complete = nil, nil, nil
end

local function online(forms)
	for _, f in ipairs(forms) do
		local v = index[f]
		if v ~= nil then
			return v
		end
	end
	return nil
end

-- true / false when the roster names the owner, nil otherwise.
function Roster.Online(owner)
	if not index then
		return nil
	end
	local v = index[owner]
	if v ~= nil then
		return v
	end
	return online(Roster.Forms(owner))
end

function Roster.Has(owner)
	return Roster.Online(owner) ~= nil
end

-- Membership can be judged only on a roster that lists every member and
-- finds the player under the spelling used for records.
function Roster.Trusted()
	return index ~= nil and complete == true and ns.me ~= nil and Roster.Has(ns.me)
end

-- Another spelling of a member the roster lists exactly: a copy of that
-- member's record under a name nobody speaks with (e.g. "First-Surname"
-- next to "First Surname"). Matching through Forms alone would keep it in
-- the guild forever. The listed name is taken as the member's record key
-- when a record is held under it, or when the roster lists the player
-- under the player's own key: it then spells names as records do.
local function alias(owner, forms)
	if exact[owner] then
		return false
	end
	local asRecords = ns.me ~= nil and exact[ns.me]
	for _, f in ipairs(forms) do
		if f ~= owner and exact[f] and (asRecords or Store.Get(f)) then
			return true
		end
	end
	return false
end

function Roster.IsAlias(owner)
	return exact ~= nil and alias(owner, Roster.Forms(owner))
end

-- Why a record no longer belongs to the guild: "alias" (another spelling
-- of a member) or "left" (absent from the roster). nil for a member, and
-- whenever that cannot be judged: no trusted roster, the player's own
-- record, or a character heard on the guild channel this session (a
-- member who joined after the roster was read speaks there before showing
-- in it).
function Roster.Former(owner)
	if owner == ns.me or not Roster.Trusted() or exact[owner] then
		return nil
	end
	local heard = ns.Sync and ns.Sync.heard
	if heard and heard[owner] then
		return nil
	end
	local forms = Roster.Forms(owner)
	if alias(owner, forms) then
		return "alias"
	end
	if online(forms) == nil then
		return "left"
	end
	return nil
end

-- Removes the records of former members. Departures are refused when more
-- than half of the members' records would go: that points at a roster
-- read wrong, not a purge. Aliases stay out of that count: each one is
-- matched to a name the roster lists.
-- Returns the number removed and a description (or the reason for none).
function Roster.Prune()
	if not Store.IsBound() then
		return 0, "no guild"
	end
	if not Roster.Trusted() then
		return 0, "roster not trusted"
	end
	local owners = Store.Owners()
	local left, aliases = {}, {}
	for _, owner in ipairs(owners) do
		local why = Roster.Former(owner)
		if why == "alias" then
			aliases[#aliases + 1] = owner
		elseif why then
			left[#left + 1] = owner
		end
	end
	local what = {}
	local members = #owners - #aliases
	if #left * 2 > members then
		what[1] = #left .. " of " .. members .. " records would go: skipped"
		left = {}
	elseif #left > 0 then
		what[1] = "removed " .. table.concat(left, ", ")
	end
	if #aliases > 0 then
		what[#what + 1] = "other spellings removed: " .. table.concat(aliases, ", ")
	end
	if #what == 0 then
		return 0, "nobody left"
	end
	for _, list in ipairs({ left, aliases }) do
		for _, owner in ipairs(list) do
			Store.Remove(owner)
			if ns.Version then
				ns.Version.Forget(owner)
			end
		end
	end
	return #left + #aliases, table.concat(what, "; ")
end
