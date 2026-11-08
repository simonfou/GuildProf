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
	index = {}
	for _, e in ipairs(entries) do
		for _, f in ipairs(Roster.Forms(e.name)) do
			if index[f] == nil or e.online then
				index[f] = e.online and true or false
			end
		end
	end
	complete = total > 0 and #entries == total
end

function Roster.Clear()
	index, complete = nil, nil
end

-- true / false when the roster names the owner, nil otherwise.
function Roster.Online(owner)
	if not index then
		return nil
	end
	for _, f in ipairs(Roster.Forms(owner)) do
		local v = index[f]
		if v ~= nil then
			return v
		end
	end
	return nil
end

function Roster.Has(owner)
	return Roster.Online(owner) ~= nil
end

-- Membership can be judged only on a roster that lists every member and
-- finds the player under the spelling used for records.
function Roster.Trusted()
	return index ~= nil and complete == true and ns.me ~= nil and Roster.Has(ns.me)
end

-- The owner left the guild: absent from a trusted roster, and not heard on
-- the guild channel this session (a member who joined after the roster was
-- read speaks there before showing in it).
function Roster.IsFormer(owner)
	if owner == ns.me or not Roster.Trusted() then
		return false
	end
	local heard = ns.Sync and ns.Sync.heard
	if heard and heard[owner] then
		return false
	end
	return not Roster.Has(owner)
end

-- Removes the records of former members. Refuses when more than half of
-- the records would go: that points at a roster read wrong, not a purge.
-- Returns the number removed and a description (or the reason for none).
function Roster.Prune()
	if not Store.IsBound() then
		return 0, "no guild"
	end
	if not Roster.Trusted() then
		return 0, "roster not trusted"
	end
	local owners = Store.Owners()
	local gone = {}
	for _, owner in ipairs(owners) do
		if Roster.IsFormer(owner) then
			gone[#gone + 1] = owner
		end
	end
	if #gone == 0 then
		return 0, "nobody left"
	end
	if #gone * 2 > #owners then
		return 0, #gone .. " of " .. #owners .. " records would go: skipped"
	end
	for _, owner in ipairs(gone) do
		Store.Remove(owner)
	end
	return #gone, "removed " .. table.concat(gone, ", ")
end
