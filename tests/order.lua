-- Work-order planner tests: lua-5.1 tests/order.lua (from the project root).

local ns = {}
assert(loadfile("GuildProf/Data/Recipes.lua"))("GuildProf", ns)
assert(loadfile("GuildProf/Core/Order.lua"))("GuildProf", ns)
local Order = ns.Order

local failures, checks = 0, 0
local function check(cond, msg)
	checks = checks + 1
	if not cond then
		failures = failures + 1
		print("FAIL: " .. msg)
	end
end

local function stack(bag, slot, item, count, extra)
	local s = { bag = bag, slot = slot, item = item, count = count }
	for k, v in pairs(extra or {}) do
		s[k] = v
	end
	return s
end

local function freeSlots(n)
	local f = {}
	for i = 1, n do
		f[i] = { bag = 4, slot = i }
	end
	return f
end

local function describe(steps)
	local t = {}
	for _, s in ipairs(steps or {}) do
		t[#t + 1] = ("%d:%d:%d x%d%s"):format(s.item, s.bag, s.slot, s.count,
			s.to and (" ->" .. s.to.bag .. ":" .. s.to.slot) or "")
	end
	return table.concat(t, ", ")
end

local function problem(problems, code)
	for _, p in ipairs(problems or {}) do
		if p.code == code then
			return p
		end
	end
end

---------------------------------------------------------------- reagents

do
	local r = Order.Reagents(2163)
	check(r and #r == 3, "2163 has three reagents")
	check(r and r[1].item == 2318 and r[1].count == 8, "2163 first reagent 8 x 2318")
	check(r and r[3].item == 2324 and r[3].count == 1, "2163 last reagent 1 x 2324")
	check(Order.Reagents(1) == nil, "unknown recipe gives nil")
	local thorium = Order.Reagents(16729)
	local bars
	for _, x in ipairs(thorium or {}) do
		if x.item == 12359 then
			bars = x.count
		end
	end
	check(bars == 80, "16729 needs 80 Thorium Bar (" .. tostring(bars) .. ")")
end

---------------------------------------------------------------- choices

-- A stack of the exact size is sent as it is.
do
	local steps = Order.Plan({ { item = 2318, count = 8 } },
		{ stack(0, 1, 2318, 20), stack(0, 2, 2318, 8) }, freeSlots(1))
	check(describe(steps) == "2318:0:2 x8", "exact stack: " .. describe(steps))
end

-- Whole stacks that add up need no split.
do
	local steps = Order.Plan({ { item = 2318, count = 5 } },
		{ stack(0, 1, 2318, 20), stack(0, 2, 2318, 3), stack(1, 1, 2318, 2) }, freeSlots(1))
	check(describe(steps) == "2318:0:2 x3, 2318:1:1 x2", "whole stacks: " .. describe(steps))
end

-- One split from the smallest stack larger than the need.
do
	local steps = Order.Plan({ { item = 2318, count = 5 } },
		{ stack(0, 1, 2318, 20), stack(0, 2, 2318, 10) }, freeSlots(1))
	check(describe(steps) == "2318:0:2 x5 ->4:1", "single split: " .. describe(steps))
end

-- Whole stacks first, then the rest split off the smallest unused stack.
do
	local steps = Order.Plan({ { item = 2318, count = 7 } },
		{ stack(0, 1, 2318, 5), stack(0, 2, 2318, 4) }, freeSlots(1))
	check(describe(steps) == "2318:0:1 x5, 2318:0:2 x2 ->4:1", "whole + split: " .. describe(steps))
end

-- Locked (already attached) and bound stacks do not count.
do
	local steps, problems = Order.Plan({ { item = 2318, count = 10 } }, {
		stack(0, 1, 2318, 6),
		stack(0, 2, 2318, 20, { locked = true }),
		stack(0, 3, 2318, 20, { bound = true }),
	}, freeSlots(2))
	local p = problem(problems, "missing")
	check(steps == nil, "missing: no plan")
	check(p and p.item == 2318 and p.need == 10 and p.have == 6, "missing: 6 of 10")
end

-- Every missing reagent is reported, not just the first.
do
	local _, problems = Order.Plan({ { item = 2318, count = 2 }, { item = 2320, count = 1 } }, {}, {})
	check(problems and #problems == 2, "two missing reagents reported")
end

-- Each split needs its own free slot.
do
	local steps, problems = Order.Plan({ { item = 2318, count = 5 }, { item = 2320, count = 1 } },
		{ stack(0, 1, 2318, 20), stack(0, 2, 2320, 10) }, freeSlots(1))
	local p = problem(problems, "slots")
	check(steps == nil and p and p.need == 2 and p.have == 1, "slots: 2 splits, 1 free slot")
	steps = Order.Plan({ { item = 2318, count = 5 }, { item = 2320, count = 1 } },
		{ stack(0, 1, 2318, 20), stack(0, 2, 2320, 10) }, freeSlots(2))
	check(describe(steps) == "2318:0:1 x5 ->4:1, 2320:0:2 x1 ->4:2", "slots: distinct targets: " .. describe(steps))
end

-- A need of zero sends nothing.
do
	local steps = Order.Plan({ { item = 2318, count = 0 } }, {}, {})
	check(steps and #steps == 0, "zero need: empty plan")
end

---------------------------------------------------------------- attachments

-- Thirteen small stacks would exceed the mail: one split of a big stack instead.
do
	local stacks = { stack(1, 1, 12359, 40) }
	for i = 1, 13 do
		stacks[#stacks + 1] = stack(2, i, 12359, 2)
	end
	local steps = Order.Plan({ { item = 12359, count = 26 } }, stacks, freeSlots(1))
	check(describe(steps) == "12359:1:1 x26 ->4:1", "compact retry: " .. describe(steps))
end

-- Thirteen reagents cannot fit in one mail.
do
	local needs, stacks = {}, {}
	for i = 1, 13 do
		needs[i] = { item = 1000 + i, count = 1 }
		stacks[i] = stack(0, i, 1000 + i, 1)
	end
	local steps, problems = Order.Plan(needs, stacks, {})
	local p = problem(problems, "attachments")
	check(steps == nil and p and p.need == 13 and p.max == 12, "13 attachments refused")
end

-- 80 Thorium Bar in stacks of 20: four attachments, no split.
do
	local stacks = {}
	for i = 1, 5 do
		stacks[i] = stack(1, i, 12359, 20)
	end
	local steps = Order.Plan({ { item = 12359, count = 80 } }, stacks, {})
	check(steps and #steps == 4, "80 bars: four whole stacks (" .. describe(steps) .. ")")
end

---------------------------------------------------------------- random bags

local seed = tonumber(os.getenv("SEED") or "") or 12345
local function rand(lo, hi)
	seed = (seed * 1103515245 + 12345) % 2147483648
	return lo + seed % (hi - lo + 1)
end

for case = 1, 3000 do
	local items = rand(1, 6)
	local stacks, needs, slot = {}, {}, 0
	for i = 1, items do
		local item = 100 + i
		for _ = 1, rand(0, 8) do
			slot = slot + 1
			stacks[#stacks + 1] = stack(rand(0, 4), slot, item, rand(1, 20), {
				locked = rand(1, 10) == 1,
				bound = rand(1, 15) == 1,
			})
		end
		needs[i] = { item = item, count = rand(0, 45) }
	end
	local free = freeSlots(rand(0, 4))
	local steps, problems = Order.Plan(needs, stacks, free)
	local again = Order.Plan(needs, stacks, free)
	local tag = "case " .. case .. ": "
	check(describe(steps) == describe(again), tag .. "same bags, same plan")
	check((steps == nil) ~= (problems == nil), tag .. "either a plan or problems")

	local have = {}
	for _, s in ipairs(stacks) do
		if not s.locked and not s.bound then
			have[s.item] = (have[s.item] or 0) + s.count
		end
	end
	local missing = false
	for _, n in ipairs(needs) do
		if (have[n.item] or 0) < n.count then
			missing = true
			check(problem(problems, "missing"), tag .. "missing reported")
		end
	end

	if steps then
		check(not missing, tag .. "no plan when a reagent is missing")
		check(#steps <= Order.MAX_ATTACHMENTS, tag .. "at most 12 attachments")
		local sent, usedStack, usedTo, splitsOf = {}, {}, {}, {}
		local bySlot = {}
		for _, s in ipairs(stacks) do
			bySlot[s.bag .. ":" .. s.slot] = s
		end
		for _, st in ipairs(steps) do
			local key = st.bag .. ":" .. st.slot
			local src = bySlot[key]
			check(src and src.item == st.item and not src.locked and not src.bound, tag .. "step uses a mailable stack")
			check(not usedStack[key], tag .. "stack used once")
			usedStack[key] = true
			check(st.count > 0 and src and st.count <= src.count, tag .. "count within the stack")
			if st.to then
				local k = st.to.bag .. ":" .. st.to.slot
				check(not usedTo[k], tag .. "one free slot per split")
				usedTo[k] = true
				check(src and st.count < src.count, tag .. "a split leaves part of the stack")
				splitsOf[st.item] = (splitsOf[st.item] or 0) + 1
			else
				check(src and st.count == src.count, tag .. "whole stack sent whole")
			end
			sent[st.item] = (sent[st.item] or 0) + st.count
		end
		for _, n in ipairs(needs) do
			check((sent[n.item] or 0) == n.count, tag .. "exact count of " .. n.item)
			check((splitsOf[n.item] or 0) <= 1, tag .. "at most one split per reagent")
		end
	else
		for _, p in ipairs(problems) do
			check(p.code == "missing" or p.code == "slots" or p.code == "attachments", tag .. "known problem " .. tostring(p.code))
		end
	end
end

print(("%d checks, %d failures"):format(checks, failures))
os.exit(failures == 0 and 0 or 1)
