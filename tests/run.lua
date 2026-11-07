-- Headless tests: lua-5.1 tests/run.lua (from the project root).
-- Loads the pure modules once per simulated player, each in its own
-- environment, on a simulated guild channel with a virtual clock.

local ROOT = "GuildProf/Core/"
local MODULES = { "Codec", "Store", "Comm", "Sync", "Index" }

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
local seed = 12345
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
		for _, n in pairs(nodes) do
			if n.online then
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
	local node = { name = name, online = false, db = {} }
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
	node.ns = ns
	nodes[name] = node
	return node
end

local function login(node)
	node.online = true
	node.ns.me = node.guess or node.name
	node.ns.baseName = node.name:match("^%S+")
	node.ns.Store.Bind(node.db, "TestGuild")
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

-- 2. Everyone in sync: a login costs one GUILD message and nothing else.
reset()
local n5 = nodes[names[5]]
logout(n5)
runUntil(clock + 10)
login(n5)
runUntil(clock + 60)
check(traffic.GUILD == 1 and traffic.WHISPER == 0,
	("in-sync login costs 1 message (GUILD %d, WHISPER %d)"):format(traffic.GUILD, traffic.WHISPER))

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

-- 6. Index: crafters per recipe and recipes per profession.
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

print(("%d checks, %d failures"):format(checks, failures))
os.exit(failures == 0 and 0 or 1)
