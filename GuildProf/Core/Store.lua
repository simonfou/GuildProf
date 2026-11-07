local _, ns = ...

-- Pure Lua 5.1: the replicated table of profession records, one per
-- character, for the guild the player is in. Each record is owned by its
-- character and versioned by `rev`; a higher rev always wins, so merging is
-- order-independent and replays are harmless.
--
-- SavedVariables layout (account-wide, partitioned per guild so alts in
-- different guilds never leak data into each other's sync):
--   GuildProfDB.guilds[guildKey].records[owner] = { rev = n, data = "<EncodeProfs>" }

local Codec = ns.Codec
local Store = {}
ns.Store = Store

Store.BUCKETS = 16

local records -- records table of the bound guild, or nil
local cache   -- digests, rebuilt lazily after any change

function Store.Bind(db, guildKey)
	db.guilds = db.guilds or {}
	local g = db.guilds[guildKey]
	if type(g) ~= "table" then
		g = {}
		db.guilds[guildKey] = g
	end
	if type(g.records) ~= "table" then
		g.records = {}
	end
	-- Drop anything that would not survive the protocol.
	for owner, r in pairs(g.records) do
		if type(r) ~= "table" or type(r.rev) ~= "number" or type(r.data) ~= "string"
			or not Codec.DecodeProfs(r.data) then
			g.records[owner] = nil
		end
	end
	records = g.records
	cache = nil
end

function Store.Unbind()
	records, cache = nil, nil
end

function Store.IsBound()
	return records ~= nil
end

function Store.Get(owner)
	return records and records[owner]
end

-- Accepts the record when it is new or newer. Returns true when it changed.
function Store.Put(owner, rev, data)
	if not records or type(owner) ~= "string" or owner == "" then
		return false
	end
	local cur = records[owner]
	if cur and cur.rev >= rev then
		return false
	end
	if not Codec.DecodeProfs(data) then
		return false
	end
	records[owner] = { rev = rev, data = data }
	cache = nil
	return true
end

function Store.Rename(old, new)
	if records and records[old] and old ~= new then
		local r = records[old]
		records[old] = nil
		local cur = records[new]
		if not cur or cur.rev < r.rev then
			records[new] = r
		end
		cache = nil
	end
end

function Store.Owners()
	local list = {}
	if records then
		for owner in pairs(records) do
			list[#list + 1] = owner
		end
	end
	table.sort(list)
	return list
end

function Store.BucketOf(owner)
	return Codec.Hash(owner) % Store.BUCKETS
end

local function build()
	local lines = {}
	for i = 0, Store.BUCKETS - 1 do
		lines[i] = {}
	end
	for _, owner in ipairs(Store.Owners()) do
		local b = lines[Store.BucketOf(owner)]
		b[#b + 1] = owner .. "=" .. Codec.ToB36(records[owner].rev)
	end
	local buckets, all = {}, 5381
	for i = 0, Store.BUCKETS - 1 do
		local h = Codec.Hash(table.concat(lines[i], ","))
		buckets[i] = Codec.ToB36(h)
		all = Codec.Hash(buckets[i] .. ".", all)
	end
	cache = { lines = lines, buckets = buckets, digest = Codec.ToB36(all) }
end

-- One short string that matches between two peers exactly when their
-- (owner, rev) sets match.
function Store.Digest()
	if not cache then
		build()
	end
	return cache.digest
end

-- Array [0..BUCKETS-1] of per-bucket digests.
function Store.BucketDigests()
	if not cache then
		build()
	end
	return cache.buckets
end

-- "owner=rev,owner=rev" lines of one bucket.
function Store.BucketLine(i)
	if not cache then
		build()
	end
	return table.concat(cache.lines[i], ",")
end
