local _, ns = ...

-- Sync protocol. Design and message costs: docs/design.md, "Sync".
--
--   V<version>                     GUILD    the sender's addon version, right before its H;
--                                           also one answer to an older copy's V
--   H<digest>                      GUILD    newcomer: hash of its whole table
--   A<newcomer>\t<digest>          GUILD    one peer whose hash differs: "sync with me"
--   B<d0>,<d1>,...,<d15>           WHISPER  newcomer -> peer: per-bucket hashes
--   M<i>:<owner=rev,...>;...       WHISPER  peer -> newcomer: entries of the buckets that differ
--   N<owner>,<owner>,...           WHISPER  newcomer -> peer: records it needs
--   R<owner>\t<rev>\t<data>        GUILD    a character's own record, when it changes
--                                  WHISPER  any record, during a sync
--
-- Whispers are accepted only from players heard on the guild channel this
-- session: the server delivers that channel to guild members only, and
-- every sync starts there (the newcomer's H, the peer's A).
--
-- In sync (the common case) a login costs two GUILD messages (V and H).
-- Copies without V ignore it: unknown message types are dropped.

local Codec, Store, Comm = ns.Codec, ns.Store, ns.Comm
local Sync = {}
ns.Sync = Sync

local HELLO_WINDOW = 20      -- seconds the newcomer waits for an A
local ACK_DELAY_MIN = 2      -- tenths of a second
local ACK_DELAY_MAX = 15
local ACK_MEMORY = 30        -- seconds an A for a newcomer suppresses others
local PUBLISH_DELAY = 2      -- coalesce several profession scans

local SETTLE = 3             -- seconds for the last records of a sync to arrive
local VREPLY_MIN = 100       -- hundredths of a second before answering an older copy's V
local VREPLY_MAX = 500

local waiting      -- time the player's H went out, while an A is awaited
local syncPeer
-- A player answers others only once its own table is current: after its
-- own sync, or after a HELLO_WINDOW in which nobody answered.
local ready = false
local heardOtherHello -- another player's H with a different digest, while not ready
local retried
local plannedAck = {} -- newcomer -> true while an A to it is scheduled
local heardAck = {}   -- newcomer -> time an A for it was heard
local publishPlanned
local lastAnnounce = -1 -- time a V at least as new as this copy's was last heard or sent

-- Senders heard on the guild channel this session: guild members.
Sync.heard = {}

local function isFormer(owner)
	return ns.Roster ~= nil and ns.Roster.IsFormer(owner)
end

local function now()
	return GetTime()
end

-- Protocol trace for diagnostics (ns.Log keeps the last lines).
local function log(...)
	if ns.Log then
		ns.Log(table.concat({ ... }, " "))
	end
end

local function sendRecord(kind, owner, target)
	local r = Store.Get(owner)
	if r then
		Comm.Send(kind, "R" .. owner .. "\t" .. Codec.ToB36(r.rev) .. "\t" .. r.data, target)
	end
end

function Sync.Hello()
	if not Store.IsBound() or ns.solo then
		return
	end
	waiting, syncPeer = now(), nil
	Sync.lastHello = now()
	log("H sent", Store.Digest(), #Store.Owners() .. " records")
	local Version = ns.Version
	if Version and Version.mine then
		Comm.Send("GUILD", "V" .. Version.mine)
	end
	Comm.Send("GUILD", "H" .. Store.Digest())
	local sent = waiting
	C_Timer.After(HELLO_WINDOW, function()
		if waiting ~= sent then
			return -- answered, or a newer H went out
		end
		waiting = nil
		ready = true
		log("no answer: table taken as current")
		-- Two players who logged in together with stale tables could not
		-- answer each other: try once more now that both answer.
		if heardOtherHello and not retried then
			retried = true
			C_Timer.After(ns.random(5, 30) / 10, Sync.Hello)
		end
	end)
end

-- A sync when none ran in the last `age` seconds (e.g. on opening the window).
function Sync.HelloIfStale(age)
	if not Sync.lastHello or now() - Sync.lastHello > age then
		Sync.Hello()
	end
end

-- Rebuilds the player's own record from the scanner's view and broadcasts it when
-- it changed. `profs` uses the Codec.EncodeProfs shape.
function Sync.SetOwn(profs)
	if not Store.IsBound() or not ns.me then
		return
	end
	local data = Codec.EncodeProfs(profs)
	local cur = Store.Get(ns.me)
	if cur and cur.data == data then
		return
	end
	-- Server time keeps revs increasing across devices and lost SavedVariables.
	local rev = math.max(GetServerTime(), cur and (cur.rev + 1) or 0)
	Store.Put(ns.me, rev, data)
	if ns.OnRecordChanged then
		ns.OnRecordChanged(ns.me)
	end
	if not ns.solo and not publishPlanned then
		publishPlanned = true
		C_Timer.After(PUBLISH_DELAY, function()
			publishPlanned = false
			log("R own published")
			sendRecord("GUILD", ns.me)
		end)
	end
end

-- The player's own record again, e.g. once the server's form of the name is known.
function Sync.PublishOwn()
	if Store.IsBound() and ns.me and Store.Get(ns.me) then
		sendRecord("GUILD", ns.me)
	end
end

-- The key other players see for the player is the `sender` the server puts
-- on the player's messages ("First Surname" on Forever, which the client's
-- own name APIs do not spell the same way). Comm calls this with the sender
-- of the echo of the player's own GUILD message, which gives that exact
-- form. Returns false when the sender cannot be the player.
function Sync.OnOwnEcho(sender)
	local base = ns.baseName
	if not base or type(sender) ~= "string" or sender:sub(1, #base) ~= base then
		return false
	end
	if sender ~= ns.me then
		local renamed = ns.me and Store.Get(ns.me)
		if ns.me then
			Store.Rename(ns.me, sender)
		end
		ns.me = sender
		if ns.OnOwnName then
			ns.OnOwnName(sender)
		end
		-- Anything sent under the guessed name was refused by the others.
		if renamed then
			C_Timer.After(1, Sync.PublishOwn)
		end
	end
	return true
end
ns.OnOwnEcho = Sync.OnOwnEcho

local handlers = {}

handlers.V = function(body, channel, sender)
	local Version = ns.Version
	if channel ~= "GUILD" or not Version then
		return
	end
	local c = Version.OnV(sender, body)
	if c == nil then
		return
	end
	if c >= 0 then
		lastAnnounce = now()
		return
	end
	-- An older copy announced itself: one player on the newest version
	-- answers, so that copy learns a newer one exists.
	if Version.newest then
		return
	end
	local heard = now()
	C_Timer.After(ns.random(VREPLY_MIN, VREPLY_MAX) / 100, function()
		if lastAnnounce >= heard then
			log("V for", sender, "left to another player")
			return
		end
		lastAnnounce = now()
		log("V sent: older copy at", sender, body)
		Comm.Send("GUILD", "V" .. Version.mine)
	end)
end

handlers.H = function(body, channel, sender)
	if channel ~= "GUILD" then
		return
	end
	if ns.Version then
		ns.Version.OnHello(sender)
	end
	if plannedAck[sender] then
		return
	end
	if body == Store.Digest() then
		log("H from", sender, "in sync")
		return
	end
	if not ready then
		heardOtherHello = true
		log("H from", sender, "differs; not answering before own sync")
		return
	end
	plannedAck[sender] = true
	C_Timer.After(ns.random(ACK_DELAY_MIN, ACK_DELAY_MAX) / 10, function()
		plannedAck[sender] = nil
		local heard = heardAck[sender]
		if heard and now() - heard < ACK_MEMORY then
			log("A for", sender, "left to another peer")
			return
		end
		log("A sent for", sender)
		Comm.Send("GUILD", "A" .. sender .. "\t" .. Store.Digest())
	end)
end

handlers.A = function(body, channel, sender)
	local newcomer, digest = body:match("^([^\t]+)\t(.*)$")
	if not newcomer or channel ~= "GUILD" then
		return
	end
	heardAck[newcomer] = now()
	if newcomer ~= ns.me or not waiting or syncPeer then
		return
	end
	if now() - waiting > HELLO_WINDOW then
		return
	end
	if digest == Store.Digest() then
		waiting, ready = nil, true
		return
	end
	syncPeer = sender
	log("A from", sender, "-> B sent")
	local list = {}
	local buckets = Store.BucketDigests()
	for i = 0, Store.BUCKETS - 1 do
		list[#list + 1] = buckets[i]
	end
	Comm.Send("WHISPER", "B" .. table.concat(list, ","), sender)
end

handlers.B = function(body, channel, sender)
	if channel ~= "WHISPER" then
		return
	end
	local theirs = {}
	for d in (body .. ","):gmatch("([^,]*),") do
		theirs[#theirs + 1] = d
	end
	local mine = Store.BucketDigests()
	local parts = {}
	for i = 0, Store.BUCKETS - 1 do
		if theirs[i + 1] ~= mine[i] then
			parts[#parts + 1] = Codec.ToB36(i) .. ":" .. Store.BucketLine(i)
		end
	end
	log("B from", sender, "-> M with", #parts, "buckets")
	Comm.Send("WHISPER", "M" .. table.concat(parts, ";"), sender)
end

handlers.M = function(body, channel, sender)
	if channel ~= "WHISPER" or sender ~= syncPeer then
		return
	end
	syncPeer, waiting = nil, nil
	C_Timer.After(SETTLE, function()
		ready = true
	end)
	local need, pushed = {}, 0
	if body == "" then
		log("M from", sender, "empty")
		return
	end
	for chunk in (body .. ";"):gmatch("([^;]*);") do
		local i, line = chunk:match("^([0-9a-z]+):(.*)$")
		i = i and Codec.FromB36(i)
		if i then
			local theirs = {}
			for owner, rev in (line .. ","):gmatch("([^,=]+)=([0-9a-z]+),") do
				theirs[owner] = Codec.FromB36(rev)
				local r = Store.Get(owner)
				if (not r or r.rev < theirs[owner]) and not isFormer(owner) then
					need[#need + 1] = owner
				end
			end
			for _, owner in ipairs(Store.Owners()) do
				if Store.BucketOf(owner) == i then
					local t = theirs[owner]
					if not t or t < Store.Get(owner).rev then
						-- The player's own record goes to the whole guild:
						-- if this peer had it stale, so may the others.
						if owner == ns.me then
							log("own record stale at", sender, "-> published")
							sendRecord("GUILD", owner)
						else
							sendRecord("WHISPER", owner, sender)
						end
						pushed = pushed + 1
					end
				end
			end
		end
	end
	log("M from", sender, "-> need", #need, "push", pushed)
	if #need > 0 then
		Comm.Send("WHISPER", "N" .. table.concat(need, ","), sender)
	end
end

handlers.N = function(body, channel, sender)
	if channel ~= "WHISPER" then
		return
	end
	local n = 0
	for owner in (body .. ","):gmatch("([^,]+),") do
		sendRecord("WHISPER", owner, sender)
		n = n + 1
	end
	log("N from", sender, "->", n, "records")
end

handlers.R = function(body, channel, sender)
	local owner, rev, data = body:match("^([^\t]+)\t([0-9a-z]+)\t(.*)$")
	rev = rev and Codec.FromB36(rev)
	if not rev then
		return
	end
	-- On the guild channel a character only speaks for itself.
	if channel == "GUILD" and owner ~= sender then
		return
	end
	-- A relayed record of a character who left the guild stays out.
	if channel ~= "GUILD" and isFormer(owner) then
		log("R", channel, "from", sender, "for", owner, "left the guild: dropped")
		return
	end
	if Store.Put(owner, rev, data) then
		log("R", channel, "from", sender, "for", owner, "stored")
		ns.OnRecordChanged(owner)
	else
		log("R", channel, "from", sender, "for", owner, "not newer")
	end
end

function Sync.OnBody(body, channel, sender)
	if channel == "GUILD" then
		Sync.heard[sender] = true
	elseif not Sync.heard[sender] then
		log(body:sub(1, 1), "whisper from", sender, "not heard on the guild channel: ignored")
		return
	end
	if sender == ns.me or not Store.IsBound() then
		return
	end
	local h = handlers[body:sub(1, 1)]
	if h then
		h(body:sub(2), channel, sender)
	end
end

Comm.SetHandler(Sync.OnBody)
