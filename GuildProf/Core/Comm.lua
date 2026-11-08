local _, ns = ...

-- Transport: splits a protocol body into addon messages, paces them under
-- the client throttle, and reassembles them on arrival.
--
-- Wire: "<id>.<index>.<count>:<part>", numbers in base 36, one id per
-- sender per body. Client limits: 255 bytes per
-- message, 10 messages per prefix refilled 1/s; whispers outside instances
-- are exempt but are still paced here.

local Codec = ns.Codec
local Comm = {}
ns.Comm = Comm

Comm.PREFIX = "GuildProf"
local PART = 240           -- body bytes per message, header excluded
local TICK = 0.1
local PARTIAL_TTL = 60     -- seconds before an incomplete body is dropped
local ECHO_TTL = 10

-- Token buckets: GUILD stays under the documented 10/1 s with headroom.
local buckets = {
	GUILD = { cap = 8, rate = 1, tokens = 8 },
	WHISPER = { cap = 20, rate = 10, tokens = 20 },
}
local queues = { GUILD = {}, WHISPER = {} }
local ticker
local lastPump
local nextId = 0
local partials = {}
local sentGuild = {} -- text -> time, to recognize the player's own echo
local handler

Comm.stats = { sent = 0, received = 0, dropped = 0 }

function Comm.SetHandler(fn)
	handler = fn
end

-- Cut at a UTF-8 boundary so no message carries half a character.
local function splitBody(body)
	local parts, i, n = {}, 1, #body
	while i <= n do
		local j = math.min(i + PART - 1, n)
		while j < n and j > i do
			local b = body:byte(j + 1)
			if b < 0x80 or b >= 0xC0 then
				break
			end
			j = j - 1
		end
		parts[#parts + 1] = body:sub(i, j)
		i = j + 1
	end
	if #parts == 0 then
		parts[1] = ""
	end
	return parts
end

local function refill(now)
	local dt = lastPump and (now - lastPump) or 0
	lastPump = now
	for _, b in pairs(buckets) do
		b.tokens = math.min(b.cap, b.tokens + dt * b.rate)
	end
end

local function trySend(kind, item)
	local result = C_ChatInfo.SendAddonMessage(Comm.PREFIX, item.text, kind, item.target)
	-- Older clients return a boolean; Forever returns Enum.SendAddonMessageResult.
	if result == nil or result == true or result == 0 then
		return "ok"
	end
	if result == 3 or result == 8 then -- AddonMessageThrottle, ChannelThrottle
		return "retry"
	end
	return "drop", result
end

local function pump()
	refill(GetTime())
	local idle = true
	for kind, q in pairs(queues) do
		local b = buckets[kind]
		while q[1] and b.tokens >= 1 do
			local status, code = trySend(kind, q[1])
			if status == "retry" then
				b.tokens = 0
				break
			end
			b.tokens = b.tokens - 1
			local item = table.remove(q, 1)
			if status == "ok" then
				Comm.stats.sent = Comm.stats.sent + 1
				if kind == "GUILD" then
					sentGuild[item.text] = GetTime()
				end
			else
				Comm.stats.dropped = Comm.stats.dropped + 1
				ns.Debug("send dropped", kind, item.target or "", code)
				if ns.Log then
					ns.Log("send dropped " .. kind .. " " .. (item.target or "") .. " code " .. tostring(code))
				end
			end
		end
		if q[1] then
			idle = false
		end
	end
	if idle and ticker then
		ticker:Cancel()
		ticker = nil
	end
end

-- kind: "GUILD" or "WHISPER" (target required).
function Comm.Send(kind, body, target)
	nextId = (nextId + 1) % 1296
	local id = Codec.ToB36(nextId)
	local parts = splitBody(body)
	local n = Codec.ToB36(#parts)
	local q = queues[kind]
	for i, part in ipairs(parts) do
		q[#q + 1] = { text = id .. "." .. Codec.ToB36(i) .. "." .. n .. ":" .. part, target = target }
	end
	if not ticker then
		refill(GetTime())
		ticker = C_Timer.NewTicker(TICK, pump)
		pump()
	end
end

function Comm.Pending()
	return #queues.GUILD + #queues.WHISPER
end

function Comm.OnMessage(prefix, text, channel, sender)
	if prefix ~= Comm.PREFIX then
		return
	end
	local now = GetTime()
	-- The server echoes GUILD messages to their sender: that echo carries
	-- the exact form the server gives the player's name.
	if channel == "GUILD" and sentGuild[text] and now - sentGuild[text] < ECHO_TTL
		and ns.OnOwnEcho(sender) then
		sentGuild[text] = nil
		return
	end
	local id, idx, n, part = text:match("^([0-9a-z]+)%.([0-9a-z]+)%.([0-9a-z]+):(.*)$")
	if not id then
		return
	end
	idx, n = Codec.FromB36(idx), Codec.FromB36(n)
	if not idx or not n or idx < 1 or idx > n then
		return
	end
	Comm.stats.received = Comm.stats.received + 1
	if n == 1 then
		if handler then
			handler(part, channel, sender)
		end
		return
	end
	local key = sender .. "\001" .. id
	local p = partials[key]
	if not p or p.n ~= n then
		p = { n = n, got = 0, parts = {}, t = now }
		partials[key] = p
	end
	if not p.parts[idx] then
		p.parts[idx] = part
		p.got = p.got + 1
	end
	if p.got == n then
		partials[key] = nil
		if handler then
			handler(table.concat(p.parts), channel, sender)
		end
	end
	for k, v in pairs(partials) do
		if now - v.t > PARTIAL_TTL then
			partials[k] = nil
		end
	end
	for k, t in pairs(sentGuild) do
		if now - t > ECHO_TTL then
			sentGuild[k] = nil
		end
	end
end
