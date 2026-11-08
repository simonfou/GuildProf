local _, ns = ...

-- Pure Lua 5.1: plans the attachments of a work-order mail, one craft of
-- one recipe per mail. The player sends the reagents they provide; the
-- crafter supplies the others.
--
--   Order.Reagents(recipeID) -> array of { item, count }, nil if unknown
--   Order.Plan(needs, stacks, free) -> steps, problems
--     needs  : array of { item, count } the player provides
--     stacks : array of { bag, slot, item, count, locked, bound }
--     free   : array of { bag, slot }, empty slots of plain bags
--     steps  : array of { item, bag, slot, count, to }, one per attachment;
--              `to` = { bag, slot } when `count` is split off into that
--              empty slot first (the mail only attaches whole bag slots)
--     problems: nil when the plan is complete, else an array of
--              { code = "missing", item, need, have }
--              { code = "slots", need, have }   (free slots for splits)
--              { code = "attachments", need, max }

local Order = {}
ns.Order = Order

Order.MAX_ATTACHMENTS = 12 -- ATTACHMENTS_MAX_SEND of the mail frame

function Order.Reagents(id)
	local r = ns.Recipes and ns.Recipes[id]
	if not r then
		return nil
	end
	local list, at = {}, {}
	for i = 5, #r - 1, 2 do
		local item, count = r[i], r[i + 1]
		if at[item] then
			list[at[item]].count = list[at[item]].count + count
		else
			list[#list + 1] = { item = item, count = count }
			at[item] = #list
		end
	end
	return list
end

-- Mailable stacks of one item, largest first; ties in bag order so a plan
-- is the same for the same bags.
local function candidates(stacks, item)
	local c = {}
	for _, s in ipairs(stacks) do
		if s.item == item and not s.locked and not s.bound and (s.count or 0) > 0 then
			c[#c + 1] = s
		end
	end
	table.sort(c, function(a, b)
		if a.count ~= b.count then
			return a.count > b.count
		end
		if a.bag ~= b.bag then
			return a.bag < b.bag
		end
		return a.slot < b.slot
	end)
	return c
end

-- One stack larger than the whole need, cut down to it: the smallest such
-- stack, so the larger ones stay whole.
local function oneSplit(c, need)
	for i = #c, 1, -1 do
		if c[i].count > need then
			return { { stack = c[i], count = need, split = true } }
		end
	end
end

-- The stacks giving exactly `need` of one item: a stack of that size, else
-- whole stacks with at most one split. Whole stacks need no free slot and
-- no wait, so they come first; `compact` puts a single split first to save
-- attachments. Returns the pieces as { stack, count, split }; a split
-- keeps its source stack in the bag.
local function choose(c, need, compact)
	for _, s in ipairs(c) do
		if s.count == need then
			return { { stack = s, count = need } }
		end
	end
	if compact then
		local one = oneSplit(c, need)
		if one then
			return one
		end
	end
	local picked, used, rest = {}, {}, need
	for i, s in ipairs(c) do
		if s.count <= rest then
			picked[#picked + 1] = { stack = s, count = s.count }
			used[i] = true
			rest = rest - s.count
			if rest == 0 then
				return picked
			end
		end
	end
	-- A split is needed anyway: one attachment beats whole stacks plus one.
	local one = oneSplit(c, need)
	if one then
		return one
	end
	-- Every unused stack is larger than what is left: split the smallest.
	for i = #c, 1, -1 do
		if not used[i] then
			picked[#picked + 1] = { stack = c[i], count = rest, split = true }
			return picked
		end
	end
end

local function plan(needs, stacks, free, compact)
	local steps, problems, splits = {}, {}, {}
	for _, n in ipairs(needs) do
		local c = candidates(stacks, n.item)
		local have = 0
		for _, s in ipairs(c) do
			have = have + s.count
		end
		if have < n.count then
			problems[#problems + 1] = { code = "missing", item = n.item, need = n.count, have = have }
		elseif n.count > 0 then
			for _, p in ipairs(choose(c, n.count, compact)) do
				local step = { item = n.item, bag = p.stack.bag, slot = p.stack.slot, count = p.count }
				steps[#steps + 1] = step
				if p.split then
					splits[#splits + 1] = step
				end
			end
		end
	end
	free = free or {}
	if #splits > #free then
		problems[#problems + 1] = { code = "slots", need = #splits, have = #free }
	else
		for i, step in ipairs(splits) do
			step.to = { bag = free[i].bag, slot = free[i].slot }
		end
	end
	if #steps > Order.MAX_ATTACHMENTS then
		problems[#problems + 1] = { code = "attachments", need = #steps, max = Order.MAX_ATTACHMENTS }
	end
	if #problems > 0 then
		return nil, problems
	end
	return steps
end

function Order.Plan(needs, stacks, free)
	local steps, problems = plan(needs, stacks, free, false)
	if not steps then
		for _, p in ipairs(problems) do
			if p.code == "attachments" then
				return plan(needs, stacks, free, true)
			end
		end
	end
	return steps, problems
end
