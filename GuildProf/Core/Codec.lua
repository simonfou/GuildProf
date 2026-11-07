local _, ns = ...

-- Pure Lua 5.1: compact text encodings safe for addon messages and
-- SavedVariables. No "|", no NUL, no separator characters inside values.

local Codec = {}
ns.Codec = Codec

local floor = math.floor

-- Base 36 for non-negative integers. string.format("%d"/"%x") fails in the
-- client above 2^31, so numbers are always written with this.
local B36 = "0123456789abcdefghijklmnopqrstuvwxyz"

function Codec.ToB36(n)
	n = floor(n)
	if n <= 0 then
		return "0"
	end
	local out = {}
	while n > 0 do
		local d = n % 36
		out[#out + 1] = B36:sub(d + 1, d + 1)
		n = floor(n / 36)
	end
	return string.reverse(table.concat(out))
end

function Codec.FromB36(s)
	if type(s) ~= "string" or s == "" or s:find("[^0-9a-z]") then
		return nil
	end
	return tonumber(s, 36)
end

-- Sorted recipe IDs as a varint stream of deltas: each number is written
-- most significant group first, 5 bits per character; continuation
-- characters and terminal characters come from two disjoint alphabets, so
-- no separator is needed. A delta under 32 costs 1 character, under 1024
-- costs 2.
local TERM = "0123456789ABCDEFGHIJKLMNOPQRSTUV"
local CONT = "WXYZabcdefghijklmnopqrstuvwxyz@_"
local termVal, contVal = {}, {}
for i = 1, 32 do
	termVal[TERM:byte(i)] = i - 1
	contVal[CONT:byte(i)] = i - 1
end

local function putVarint(out, n)
	local digits = {}
	repeat
		digits[#digits + 1] = n % 32
		n = floor(n / 32)
	until n == 0
	for i = #digits, 2, -1 do
		local d = digits[i]
		out[#out + 1] = CONT:sub(d + 1, d + 1)
	end
	out[#out + 1] = TERM:sub(digits[1] + 1, digits[1] + 1)
end

function Codec.EncodeIDs(ids)
	local sorted, seen = {}, {}
	for _, id in ipairs(ids) do
		id = floor(id)
		if id > 0 and not seen[id] then
			seen[id] = true
			sorted[#sorted + 1] = id
		end
	end
	table.sort(sorted)
	local out, prev = {}, 0
	for _, id in ipairs(sorted) do
		putVarint(out, id - prev)
		prev = id
	end
	return table.concat(out)
end

-- Returns an ascending array, or nil when the string is malformed.
function Codec.DecodeIDs(s)
	local ids, acc, prev, pending = {}, 0, 0, false
	for i = 1, #s do
		local b = s:byte(i)
		local c = contVal[b]
		if c then
			acc = acc * 32 + c
			pending = true
		else
			local t = termVal[b]
			if not t then
				return nil
			end
			prev = prev + acc * 32 + t
			ids[#ids + 1] = prev
			acc, pending = 0, false
		end
	end
	if pending then
		return nil
	end
	return ids
end

-- 32-bit djb2 variant in plain arithmetic (h * 33 stays below 2^53).
function Codec.Hash(s, h)
	h = h or 5381
	for i = 1, #s do
		h = (h * 33 + s:byte(i)) % 4294967296
	end
	return h
end

-- Professions of one character:
--   profs[skillLineID] = { level = n, max = n, ids = "<EncodeIDs>" or nil }
-- Wire form, sorted by skill line: "sl,level,max,ids;sl,level,max,ids"
-- (ids empty when the window was never scanned).
function Codec.EncodeProfs(profs)
	local keys = {}
	for sl in pairs(profs) do
		keys[#keys + 1] = sl
	end
	table.sort(keys)
	local parts = {}
	for _, sl in ipairs(keys) do
		local p = profs[sl]
		parts[#parts + 1] = Codec.ToB36(sl) .. "," .. Codec.ToB36(p.level or 0) .. ","
			.. Codec.ToB36(p.max or 0) .. "," .. (p.ids or "")
	end
	return table.concat(parts, ";")
end

function Codec.DecodeProfs(s)
	local profs = {}
	if s == "" then
		return profs
	end
	for chunk in (s .. ";"):gmatch("([^;]*);") do
		local sl, level, max, ids = chunk:match("^([0-9a-z]+),([0-9a-z]+),([0-9a-z]+),(.*)$")
		if not sl then
			return nil
		end
		if ids ~= "" and not Codec.DecodeIDs(ids) then
			return nil
		end
		profs[Codec.FromB36(sl)] = {
			level = Codec.FromB36(level),
			max = Codec.FromB36(max),
			ids = ids ~= "" and ids or nil,
		}
	end
	return profs
end
