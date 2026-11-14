-- Headless tests: lua-5.1 tests/run.lua (from the project root).
-- Loads the pure modules once per simulated player, each in its own
-- environment, on a simulated guild channel with a virtual clock.

local ROOT = "GuildProf/Core/"
local MODULES = { "Codec", "Store", "Roster", "Version", "Comm", "Sync", "Index" }

-- Generated recipe data, loaded once and shared by every simulated player.
local dataNs = {}
assert(loadfile("GuildProf/Data/Recipes.lua"))("GuildProf", dataNs)

local failures, checks = 0, 0
local function check(cond, msg)
	checks = checks + 1
	if not cond then
		failures = failures + 1
		print("FAIL: " .. msg)
	end
end

-- Deterministic PRNG (the client's math.random cannot be seeded).
local seed = tonumber(os.getenv("SEED") or "") or 12345
local function rand(lo, hi)
	seed = (seed * 1103515245 + 12345) % 2147483648
	return lo + seed % (hi - lo + 1)
end

---------------------------------------------------------------- network

local clock = 0
local timers = {}      -- { at, fn, cancelled }
local nodes = {}       -- name -> node
local traffic = { GUILD = 0, WHISPER = 0, bytes = 0 }

local function after(sec, fn)
	local t = { at = clock + sec, fn = fn }
	timers[#timers + 1] = t
	return t
end

local function runUntil(limit)
	while true do
		table.sort(timers, function(a, b) return a.at < b.at end)
		local t = timers[1]
		if not t or t.at > limit then
			break
		end
		table.remove(timers, 1)
		clock = t.at
		if not t.cancelled then
			t.fn()
		end
	end
	clock = limit
end

local LATENCY = 0.05

local function deliver(from, text, kind, target)
	traffic[kind] = traffic[kind] + 1
	traffic.bytes = traffic.bytes + #text
	assert(#text <= 255, "message over 255 bytes")
	assert(not text:find("[%z|]"), "forbidden byte in message")
	if kind == "GUILD" then
		local guild = nodes[from].guild
		for _, n in pairs(nodes) do
			if n.online and n.guild == guild then
				after(LATENCY, function()
					if n.online then
						n.ns.Comm.OnMessage("GuildProf", text, "GUILD", from)
					end
				end)
			end
		end
	else
		local n = nodes[target]
		if not n or not n.online then
			return 12 -- TargetOffline
		end
		after(LATENCY, function()
			if n.online then
				n.ns.Comm.OnMessage("GuildProf", text, "WHISPER", from)
			end
		end)
	end
	return 0
end

local function newNode(name)
	local node = { name = name, online = false, db = {}, guild = "TestGuild" }
	local ns = {}
	local env = setmetatable({}, { __index = _G })
	env.GetTime = function() return clock end
	env.GetServerTime = function() return 1800000000 + math.floor(clock) end
	env.C_Timer = {
		After = function(sec, fn) after(sec, fn) end,
		NewTicker = function(sec, fn)
			local h = { cancelled = false }
			local function tick()
				if h.cancelled then return end
				fn()
				if not h.cancelled then after(sec, tick) end
			end
			after(sec, tick)
			function h:Cancel() self.cancelled = true end
			return h
		end,
	}
	env.C_ChatInfo = {
		SendAddonMessage = function(prefix, text, kind, target)
			if not node.online then return 12 end
			return deliver(name, text, kind, target)
		end,
	}
	ns.random = rand
	ns.Debug = function() end
	ns.OnRecordChanged = function() end
	ns.Recipes = dataNs.Recipes
	for _, m in ipairs(MODULES) do
		local chunk = assert(loadfile(ROOT .. m .. ".lua"))
		setfenv(chunk, env)
		chunk("GuildProf", ns)
	end
	ns.Version.mine = "1.0.0"
	node.ns = ns
	nodes[name] = node
	return node
end

local function login(node)
	node.online = true
	node.ns.me = node.guess or node.name
	node.ns.baseName = node.name:match("^%S+")
	node.ns.Store.Bind(node.db, node.guild)
	node.ns.Version.Bind(node.db, node.guild)
	node.ns.Sync.heard = {} -- a new session
	after(1, function() node.ns.Sync.Hello() end)
end

local function logout(node)
	node.online = false
end

local function randomProfs()
	local profs = {}
	for _ = 1, 2 do
		local sl = 164 + rand(0, 20) * 7
		local ids = {}
		for _ = 1, rand(40, 160) do
			ids[#ids + 1] = rand(2000, 30000)
		end
		profs[sl] = { level = rand(1, 300), max = 300, ids = codecForTests.EncodeIDs(ids) }
	end
	return profs
end

local function snapshot(node)
	local s = {}
	for _, owner in ipairs(node.ns.Store.Owners()) do
		s[#s + 1] = owner .. "=" .. node.ns.Store.Get(owner).rev
	end
	return table.concat(s, " ")
end

---------------------------------------------------------------- unit tests

local probe = newNode("Probe")
nodes.Probe = nil
local C = probe.ns.Codec
codecForTests = C

do
	for _ = 1, 200 do
		local ids, set = {}, {}
		for _ = 1, rand(0, 300) do
			local id = rand(1, 2000000)
			ids[#ids + 1] = id
			set[id] = true
		end
		local enc = C.EncodeIDs(ids)
		check(not enc:find("[^0-9A-Za-z@_]"), "EncodeIDs alphabet")
		local dec = C.DecodeIDs(enc)
		local n = 0
		for _ in pairs(set) do n = n + 1 end
		check(dec and #dec == n, "DecodeIDs count")
		for i = 2, #(dec or {}) do
			check(dec[i] > dec[i - 1], "DecodeIDs ascending")
		end
		for _, id in ipairs(dec or {}) do
			check(set[id], "DecodeIDs value")
		end
	end
	check(C.DecodeIDs("W") == nil, "DecodeIDs rejects a dangling continuation")
	check(C.DecodeIDs("!") == nil, "DecodeIDs rejects foreign bytes")
	check(C.FromB36(C.ToB36(1800000000)) == 1800000000, "B36 round trip")
	check(C.ToB36(0) == "0", "B36 zero")
	local profs = { [171] = { level = 250, max = 300, ids = C.EncodeIDs({ 2330, 2332, 3170 }) }, [186] = { level = 75, max = 150 } }
	local back = C.DecodeProfs(C.EncodeProfs(profs))
	check(back and back[171].level == 250 and back[171].ids == profs[171].ids and back[186].ids == nil,
		"EncodeProfs round trip")
	check(C.DecodeProfs("x") == nil, "DecodeProfs rejects garbage")
end

---------------------------------------------------------------- sync tests

local function reset(t)
	traffic.GUILD, traffic.WHISPER, traffic.bytes = 0, 0, 0
	return t
end

-- 1. Twenty players log in one by one, each with professions.
local names = {}
for i = 1, 20 do
	names[i] = "Player" .. i .. " Surname"
	newNode(names[i])
end
for i, name in ipairs(names) do
	local n = nodes[name]
	after(i * 30, function()
		login(n)
		after(3, function() n.ns.Sync.SetOwn(randomProfs()) end)
	end)
end
runUntil(20 * 30 + 120)
local ref = snapshot(nodes[names[20]])
local converged = 0
for _, name in ipairs(names) do
	if snapshot(nodes[name]) == ref then
		converged = converged + 1
	end
end
check(converged == 20, "staggered logins: all 20 hold the same table (" .. converged .. "/20)")
check(#nodes[names[1]].ns.Store.Owners() == 20, "staggered logins: 20 records")
print(("staggered logins: GUILD %d, WHISPER %d, %d bytes"):format(traffic.GUILD, traffic.WHISPER, traffic.bytes))

-- 2. Everyone in sync: a login costs two GUILD messages (V and H) and nothing else.
reset()
local n5 = nodes[names[5]]
logout(n5)
runUntil(clock + 10)
login(n5)
runUntil(clock + 60)
check(traffic.GUILD == 2 and traffic.WHISPER == 0,
	("in-sync login costs 2 messages (GUILD %d, WHISPER %d)"):format(traffic.GUILD, traffic.WHISPER))

-- 3. Offline changes: three players log out, others change while they are
-- away, then they come back and catch up through one peer each.
for i = 1, 3 do logout(nodes[names[i]]) end
runUntil(clock + 10)
for i = 10, 14 do
	nodes[names[i]].ns.Sync.SetOwn(randomProfs())
end
runUntil(clock + 30)
-- One of the absent players changed alone on another computer.
-- (Simulated: player 2 edits offline and brings a newer own record.)
nodes[names[2]].online = true
nodes[names[2]].ns.Sync.SetOwn(randomProfs())
nodes[names[2]].online = false
reset()
for i = 1, 3 do
	local n = nodes[names[i]]
	after(i * 2, function() login(n) end)
end
runUntil(clock + 120)
ref = snapshot(nodes[names[20]])
converged = 0
for _, name in ipairs(names) do
	if snapshot(nodes[name]) == ref then
		converged = converged + 1
	end
end
check(converged == 20, "offline catch-up: all 20 converge (" .. converged .. "/20)")
print(("offline catch-up (3 logins, 6 stale records): GUILD %d, WHISPER %d, %d bytes")
	:format(traffic.GUILD, traffic.WHISPER, traffic.bytes))

-- 4. A newcomer with an empty table joins a guild of 20.
reset()
local fresh = newNode("Fresh Recruit")
login(fresh)
runUntil(clock + 120)
check(#fresh.ns.Store.Owners() == 20, "newcomer receives all 20 records ("
	.. #fresh.ns.Store.Owners() .. ")")
print(("newcomer: GUILD %d, WHISPER %d, %d bytes"):format(traffic.GUILD, traffic.WHISPER, traffic.bytes))

-- 5. A player whose guessed name differs from the server's form: the
-- echo of its first GUILD message renames its record, and the guild ends
-- up holding it under the server's form only.
reset()
local renamed = newNode("Renamed Surname")
renamed.guess = "Renamed-SomeRealm"
login(renamed)
after(0.5, function() renamed.ns.Sync.SetOwn(randomProfs()) end)
runUntil(clock + 60)
check(renamed.ns.me == "Renamed Surname", "echo teaches the server's name form (" .. tostring(renamed.ns.me) .. ")")
local holders, wrong = 0, 0
for _, n in pairs(nodes) do
	if n.online and n.ns.Store.Get("Renamed Surname") then holders = holders + 1 end
	if n.ns.Store.Get("Renamed-SomeRealm") then wrong = wrong + 1 end
end
check(holders == 22 and wrong == 0, ("renamed record held by %d/22 online, %d under the guessed name"):format(holders, wrong))

-- 6. Two players with stale tables log in together while nobody else is
-- online: neither answers before its own sync, then they retry and meet.
for _, n in pairs(nodes) do logout(n) end
runUntil(clock + 5)
local pa, pb = nodes[names[7]], nodes[names[8]]
pa.online = true
pa.ns.Sync.SetOwn(randomProfs())
pa.online = false
reset()
login(pa)
login(pb)
runUntil(clock + 90)
check(snapshot(pa) == snapshot(pb), "simultaneous stale logins converge after the retry")
print(("simultaneous stale logins: GUILD %d, WHISPER %d"):format(traffic.GUILD, traffic.WHISPER))

-- 7. Index: crafters per recipe and recipes per profession.
do
	local ns = nodes[names[20]].ns
	local I = ns.Index
	local alchemist = "Player20 Surname"
	local profs = { [171] = { level = 300, max = 300, ids = C.EncodeIDs({ 2329, 2330, 999999 }) } }
	ns.Store.Put(alchemist, 1900000000, C.EncodeProfs(profs))
	local crafters = I.Crafters(2329)
	local found = false
	for _, o in ipairs(crafters) do if o == alchemist then found = true end end
	check(found, "Index: the alchemist crafts 2329")
	local inAlchemy = {}
	for _, id in ipairs(I.Recipes(171)) do inAlchemy[id] = true end
	check(inAlchemy[2329] and inAlchemy[999999], "Index: recipes of Alchemy, unknown IDs keep the sender's profession")
	local m = I.Members(171)
	check(#m >= 1 and m[1].level >= m[#m].level, "Index: members sorted by level")
end

-- 8. A character leaves the guild: every player's roster stops listing it,
-- each removes the record, and a player that still holds it cannot bring
-- it back.
do
	local all = {}
	for name in pairs(nodes) do all[#all + 1] = name end
	table.sort(all)
	local leaver, holdout, back = names[3], nodes[names[15]], nodes[names[9]]
	local function setRoster(node, without, total)
		local entries = {}
		for _, name in ipairs(all) do
			if name ~= without then
				entries[#entries + 1] = { name = name, online = nodes[name].online }
			end
		end
		node.ns.Roster.Set(entries, total or #entries)
	end
	local function holders()
		local n = 0
		for _, node in pairs(nodes) do
			if node.online and node ~= holdout and node.ns.Store.Get(leaver) then n = n + 1 end
		end
		return n
	end

	-- Everyone logs in again and holds the same table, the leaver's record included.
	for _, n in pairs(nodes) do logout(n) end
	runUntil(clock + 5)
	for i, name in ipairs(all) do
		after(i * 3, function() login(nodes[name]) end)
	end
	runUntil(clock + #all * 3 + 90)
	ref = snapshot(nodes[all[1]])
	converged = 0
	for _, name in ipairs(all) do
		if snapshot(nodes[name]) == ref then converged = converged + 1 end
	end
	check(converged == #all, "before the departure: all converge (" .. converged .. "/" .. #all .. ")")
	check(nodes[all[1]].ns.Store.Get(leaver) ~= nil, "before the departure: the leaver's record is held")

	-- The leaver goes; the holdout is offline and keeps the record. Each
	-- remaining player starts a new session, without the leaver's messages.
	logout(nodes[leaver])
	logout(holdout)
	for _, n in pairs(nodes) do n.ns.Sync.heard = {} end

	-- Guards, on one player.
	local obs = nodes[names[20]]
	local R = obs.ns.Roster
	check(not R.Trusted(), "no roster read yet: not trusted")
	setRoster(obs, leaver, #all)
	local n, why = R.Prune()
	check(n == 0 and obs.ns.Store.Get(leaver), "roster missing members: nothing removed (" .. why .. ")")
	setRoster(obs, obs.name)
	n, why = R.Prune()
	check(n == 0 and why == "roster not trusted", "roster without the player: nothing removed (" .. why .. ")")
	obs.ns.Roster.Set({ { name = obs.name, online = true }, { name = names[1], online = false } }, 2)
	n, why = R.Prune()
	check(n == 0 and obs.ns.Store.Get(leaver), "most records would go: nothing removed (" .. why .. ")")
	setRoster(obs, leaver)
	obs.ns.Sync.heard[leaver] = true
	n, why = R.Prune()
	check(n == 0 and why == "nobody left", "heard on the guild channel this session: kept (" .. why .. ")")
	obs.ns.Sync.heard = {}
	local suffixed = {}
	for _, name in ipairs(all) do
		suffixed[#suffixed + 1] = { name = name .. "-SomeRealm", online = false }
	end
	R.Set(suffixed, #suffixed)
	check(R.Trusted() and R.Has(leaver) and R.Online(names[1]) == false, "roster names with a realm suffix match")
	R.Set({ { name = "Player1-Surname", online = true } }, 1)
	check(R.Online(names[1]) == true, "roster names with a hyphen match")

	-- The departure on every remaining player.
	for _, node in pairs(nodes) do
		if node.online then
			setRoster(node, leaver)
			node.ns.Roster.Prune()
		end
	end
	check(holders() == 0, "departure: no online player holds the record (" .. holders() .. ")")
	check(obs.ns.Store.Get(obs.name) ~= nil, "departure: own record kept")

	-- The holdout comes back with the record and no roster yet: its sync
	-- pushes the record, and the others drop it.
	local lines = {}
	for _, node in pairs(nodes) do
		node.ns.Log = function(t) lines[#lines + 1] = node.name .. ": " .. t end
	end
	local function logged(pattern)
		for _, l in ipairs(lines) do
			if l:find(pattern) then return true end
		end
		return false
	end
	holdout.ns.Roster.Clear()
	reset()
	login(holdout)
	runUntil(clock + 60)
	check(holdout.ns.Store.Get(leaver) ~= nil, "holdout without a roster keeps the record")
	check(logged("for " .. leaver .. " left the guild: dropped"), "the holdout pushed the record in its sync")
	check(holders() == 0, "relayed record of a former member dropped (" .. holders() .. " holders)")

	-- A player who already removed it syncs with the holdout: the record
	-- is listed by the holdout but not requested.
	logout(back)
	runUntil(clock + 5)
	setRoster(back, leaver)
	login(back)
	runUntil(clock + 60)
	check(logged("^" .. back.name .. ": M from " .. holdout.name .. " %-> need 0"), "the holdout listed the record to a pruned player")
	check(back.ns.Store.Get(leaver) == nil, "former member's record not requested in a sync")

	-- Once the holdout reads the roster, everyone holds the same table again.
	setRoster(holdout, leaver)
	holdout.ns.Roster.Prune()
	ref = snapshot(obs)
	converged = 0
	local total = 0
	for _, node in pairs(nodes) do
		if node.online then
			total = total + 1
			if snapshot(node) == ref then converged = converged + 1 end
		end
	end
	check(converged == total, "after the departure: all online converge (" .. converged .. "/" .. total .. ")")
	print(("departure (holdout sync + one login): GUILD %d, WHISPER %d"):format(traffic.GUILD, traffic.WHISPER))
end

-- 8b. A member's record also held under another spelling of the name
-- ("Player7-Surname" next to "Player7 Surname", the form the roster and
-- the sender use): a player holding the copy cannot spread it in a sync,
-- and the copy goes on its own roster read.
do
	local member, holder = names[7], nodes[names[8]]
	local alias = member:gsub(" ", "-")
	local entries = {}
	for name, n in pairs(nodes) do
		if n.guild == "TestGuild" and name ~= names[3] then
			entries[#entries + 1] = { name = name, online = n.online }
		end
	end
	local lines = {}
	for _, node in pairs(nodes) do
		node.ns.Log = function(t) lines[#lines + 1] = node.name .. ": " .. t end
	end
	logout(holder)
	runUntil(clock + 5)
	holder.ns.Store.Bind(holder.db, holder.guild)
	holder.ns.Store.Put(alias, holder.ns.Store.Get(member).rev - 100, C.EncodeProfs(randomProfs()))
	holder.ns.Roster.Clear()
	login(holder)
	runUntil(clock + 60)
	local copies, dropped = 0, 0
	for _, n in pairs(nodes) do
		if n.online and n ~= holder and n.ns.Store.Get(alias) then copies = copies + 1 end
	end
	for _, l in ipairs(lines) do
		if l:find("for " .. alias .. " another spelling of a member: dropped", 1, true) then dropped = dropped + 1 end
	end
	check(dropped > 0 and copies == 0, ("alias pushed in a sync: dropped %d times, %d copies"):format(dropped, copies))
	check(holder.ns.Roster.IsAlias(alias) == false, "no roster yet: no alias")
	holder.ns.Roster.Set(entries, #entries)
	check(holder.ns.Roster.IsAlias(alias) and not holder.ns.Roster.IsAlias(member), "alias found next to the exact name")
	local n = holder.ns.Roster.Prune()
	check(n == 1 and holder.ns.Store.Get(alias) == nil and holder.ns.Store.Get(member) ~= nil,
		"roster read: alias removed, the member's record kept")
end

-- 8c. Aliases on a player who does not hold the member's own record, in
-- a guild of their own: a peer without a roster holds every member's
-- record and an alias of three of them; a recruit with an empty table and
-- a trusted roster syncs with it.
do
	local GUILD = "AliasGuild"
	local old, recruit = newNode("Old Hand"), newNode("New Recruit")
	old.guild, recruit.guild = GUILD, GUILD
	local absent = { "Third Member", "Fourth Member", "Fifth Member" }
	local aliases = {}
	local function put(node, owner, rev)
		node.ns.Store.Put(owner, rev or 1800000000, C.EncodeProfs(randomProfs()))
	end
	local function setRoster(node, extra)
		local entries = { { name = old.name, online = true }, { name = recruit.name, online = true } }
		for _, name in ipairs(absent) do
			entries[#entries + 1] = { name = name, online = false }
		end
		for _, name in ipairs(extra or {}) do
			entries[#entries + 1] = { name = name, online = false }
		end
		node.ns.Roster.Set(entries, #entries)
	end

	old.ns.Store.Bind(old.db, GUILD)
	put(old, old.name)
	for i, name in ipairs(absent) do
		aliases[i] = name:gsub(" ", "-")
		put(old, name)
		put(old, aliases[i], 1700000000)
	end
	login(old)
	runUntil(clock + 30) -- nobody answers: the peer takes its table as current

	local lines = {}
	recruit.ns.Log = function(t) lines[#lines + 1] = t end
	setRoster(recruit)
	login(recruit)
	runUntil(clock + 60)
	local S, R = recruit.ns.Store, recruit.ns.Roster
	local held, copies, mentioned = 0, 0, 0
	for i, name in ipairs(absent) do
		if S.Get(name) then held = held + 1 end
		if S.Get(aliases[i]) then copies = copies + 1 end
		for _, l in ipairs(lines) do
			if l:find(aliases[i], 1, true) then mentioned = mentioned + 1 end
		end
	end
	check(held == 3 and S.Get(old.name) ~= nil, "recruit with an empty table: the members' records arrive (" .. held .. "/3)")
	check(copies == 0 and mentioned == 0,
		("recruit with an empty table: aliases not asked for (%d stored, %d records sent)"):format(copies, mentioned))

	-- Aliases stay out of the count that guards departures.
	for i = 1, 3 do put(recruit, aliases[i], 1700000000) end
	put(recruit, "Gone One")
	put(recruit, "Gone Two")
	local sorted = { aliases[1], aliases[2], aliases[3] }
	table.sort(sorted)
	local n, why = R.Prune()
	check(n == 5 and why == "removed Gone One, Gone Two; other spellings removed: " .. table.concat(sorted, ", ")
		and #S.Owners() == 4, "aliases and departures go together (" .. why .. ")")
	put(recruit, aliases[1], 1700000000)
	for i = 1, 5 do put(recruit, "Gone " .. i) end
	n, why = R.Prune()
	check(n == 1 and why == "5 of 9 records would go: skipped; other spellings removed: " .. aliases[1]
		and S.Get("Gone 1") ~= nil and S.Get(aliases[1]) == nil, "departures refused, the alias still goes (" .. why .. ")")
	for i = 1, 5 do S.Remove("Gone " .. i) end

	-- A name heard on the guild channel is a member's, whatever it resembles.
	local speaker = "Third-Other"
	setRoster(recruit, { "Third" })
	check(R.Former(speaker) == "alias", "a name that reads as another spelling of a listed member is an alias")
	recruit.ns.Sync.heard[speaker] = true
	check(R.Former(speaker) == nil, "heard on the guild channel this session: not an alias")
	recruit.ns.Sync.heard[speaker] = nil
	check(R.Former("Gone One") == "left" and R.Former(absent[1]) == nil and R.Former(recruit.name) == nil,
		"departure, member and own record told apart")
	logout(old)
	logout(recruit)
end

-- 9. A player of another guild with the addon: its guild channel never
-- reaches this guild, and whispering a member directly gets no records
-- out and none in.
do
	local member = nodes[names[20]]
	local victim = names[1]
	local before = member.ns.Store.Get(victim).rev
	local outsider = newNode("Outsider Stranger")
	outsider.guild = "OtherGuild"
	login(outsider)
	after(3, function() outsider.ns.Sync.SetOwn(randomProfs()) end)
	runUntil(clock + 30)
	check(member.ns.Store.Get("Outsider Stranger") == nil, "another guild's record never arrives")
	check(#outsider.ns.Store.Owners() == 1, "another guild sees none of this guild's records ("
		.. #outsider.ns.Store.Owners() .. ")")

	local got, lines = 0, {}
	local onMessage = outsider.ns.Comm.OnMessage
	outsider.ns.Comm.OnMessage = function(...) got = got + 1 return onMessage(...) end
	member.ns.Log = function(t) lines[#lines + 1] = t end
	local empty = {}
	for i = 1, 16 do empty[i] = "0" end
	outsider.ns.Comm.Send("WHISPER", "B" .. table.concat(empty, ","), member.name)
	outsider.ns.Comm.Send("WHISPER", "N" .. victim, member.name)
	outsider.ns.Comm.Send("WHISPER", "R" .. victim .. "\t" .. C.ToB36(before + 1000) .. "\t"
		.. C.EncodeProfs(randomProfs()), member.name)
	runUntil(clock + 10)
	check(got == 0, "whispered B and N from outside the guild: no answer (" .. got .. " messages)")
	check(member.ns.Store.Get(victim).rev == before, "whispered R from outside the guild: not stored")
	local ignored = 0
	for _, l in ipairs(lines) do
		if l:find("not heard on the guild channel: ignored", 1, true) then ignored = ignored + 1 end
	end
	check(ignored == 3, "the three whispers logged as ignored (" .. ignored .. ")")
end

-- 10. Versions: a newer copy logs in and every online member is told once;
-- an older copy that logs in later hears of it from one player; a copy
-- without announcements shows as older.
do
	local lines, notified = {}, {}
	for _, node in pairs(nodes) do
		node.ns.Log = function(t) lines[#lines + 1] = node.name .. ": " .. t end
		node.ns.OnNewerVersion = function() notified[node.name] = (notified[node.name] or 0) + 1 end
	end
	local function count(pattern)
		local n = 0
		for _, l in ipairs(lines) do
			if l:find(pattern, 1, true) then n = n + 1 end
		end
		return n
	end
	local newer, newer2 = nodes[names[11]], nodes[names[12]]
	local older, legacy, obs = nodes[names[13]], nodes[names[14]], nodes[names[20]]
	for _, n in ipairs({ newer, newer2, older, legacy }) do logout(n) end
	runUntil(clock + 5)
	newer.ns.Version.mine, newer2.ns.Version.mine = "1.1.0", "1.1.0"
	older.ns.Version.mine, legacy.ns.Version.mine = "0.9.0", nil

	reset()
	login(newer)
	runUntil(clock + 30)
	local told, members = 0, 0
	for _, n in pairs(nodes) do
		if n.online and n.guild == "TestGuild" and n ~= newer then
			members = members + 1
			if n.ns.Version.newest == "1.1.0" and notified[n.name] == 1 then told = told + 1 end
		end
	end
	check(members > 0 and told == members, ("newer copy: %d/%d online members told once"):format(told, members))
	check(not notified["Outsider Stranger"], "another guild is not told")
	check(obs.ns.Version.Of(newer.name) == "1.1.0", "the newer copy's version is known")
	check(obs.ns.Version.Outdated(obs.name) == "1.0.0", "the player's own copy counts as older")
	check(traffic.GUILD == 2, "a newer copy's login costs no extra message (GUILD " .. traffic.GUILD .. ")")

	login(newer2)
	runUntil(clock + 30)
	local again = 0
	for _, c in pairs(notified) do
		if c > 1 then again = again + 1 end
	end
	check(again == 0, "a second copy of the same version tells nobody again (" .. again .. ")")

	reset()
	login(older)
	runUntil(clock + 30)
	check(older.ns.Version.newest == "1.1.0" and notified[older.name] == 1, "an older copy hears of the newer version at login")
	local replies = count("V sent: older copy at " .. older.name)
	check(replies >= 1 and replies <= 2, "one answer to the older copy, rarely two (" .. replies .. ")")
	local silent = count("V for " .. older.name .. " left to another player")
	check(replies + silent == 2, ("each newest copy answered or stayed silent (%d answers, %d silent)"):format(replies, silent))

	login(legacy)
	runUntil(clock + 30)
	check(obs.ns.Version.Of(legacy.name) == "" and obs.ns.Version.Outdated(legacy.name) == "",
		"a copy without announcements shows as older")
	check(count("V sent: older copy at " .. legacy.name) == 0, "a copy without announcements gets no answer")
	check(obs.db.guilds.TestGuild.versions[legacy.name] == "", "versions kept in the SavedVariables")
	check(obs.ns.Version.Outdated(newer.name) == nil, "the newest copy is not older")
end

print(("%d checks, %d failures"):format(checks, failures))
os.exit(failures == 0 and 0 or 1)
