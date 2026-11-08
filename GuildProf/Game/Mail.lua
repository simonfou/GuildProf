local _, ns = ...

-- Work-order mail: fills the open Send Mail tab for one craft of one
-- recipe, addressed to a crafter, with the reagents the player provides.
-- Whole stacks are attached at once. A partial stack is split into a free
-- bag slot first and attached once the server has placed it, because the
-- mail only attaches whole bag slots. The player checks the mail and
-- clicks Send.

local Order = ns.Order
local Mail = {}
ns.Mail = Mail

local L = {
	NO_MAILBOX = "GuildProf: open a mailbox first.",
	SELF = "GuildProf: that is you.",
	BUSY = "GuildProf: a work order is still being prepared.",
	NOT_EMPTY = "GuildProf: the mail already has items; remove them first.",
	CURSOR = "GuildProf: drop the item on the cursor first.",
	UNKNOWN = "GuildProf: no reagent data for this recipe.",
	MISSING = "GuildProf: not enough in your bags: %s.",
	MISSING_ITEM = "%s (%s of %s)",
	SLOTS = "GuildProf: %s free bag slots needed to split stacks (%s free).",
	TOO_MANY = "GuildProf: %s stacks do not fit in one mail (at most %s).",
	CLOSED = "GuildProf: the mailbox closed before the work order was ready.",
	FAILED = "GuildProf: could not attach %s; check the mail.",
	READY = "work order for %s to %s ready: check the mail and click Send.",
	SUBJECT = "Work order: %s",
	BODY = "Could you craft %s for me?",
	SENT = "Included: %s.",
	OWN = "Please use your own: %s.",
	NOTHING = "No reagents included.",
	SIGNED = "(GuildProf work order)",
}
Mail.L = L

local WAIT = 0.1   -- seconds between checks of a split stack
local TIMEOUT = 5  -- seconds before giving up on a split stack
local SUBJECT_MAX, BODY_MAX = 64, 500 -- the Send Mail edit boxes' limits

local job -- the work order being attached

local function fail(text)
	if UIErrorsFrame then
		UIErrorsFrame:AddMessage(text, 1.0, 0.1, 0.1, 1.0)
	else
		ns.Print(text)
	end
	return false
end

local function itemName(item)
	local name = C_Item.GetItemNameByID(item)
	if not name then
		C_Item.RequestLoadItemDataByID(item)
	end
	return name or ("item " .. item)
end

local function recipeName(id)
	return (C_Spell.GetSpellName and C_Spell.GetSpellName(id)) or ("#" .. id)
end

local function mailOpen()
	return MailFrame ~= nil and MailFrame:IsShown()
end

-- Every item stack in the bags, and the empty slots of plain bags (a
-- profession bag only takes its own kind of item).
local function readBags()
	local stacks, free = {}, {}
	local plain = NUM_BAG_SLOTS or 4
	local last = NUM_TOTAL_EQUIPPED_BAG_SLOTS or plain
	for bag = 0, last do
		local _, family = C_Container.GetContainerNumFreeSlots(bag)
		for slot = 1, C_Container.GetContainerNumSlots(bag) or 0 do
			local info = C_Container.GetContainerItemInfo(bag, slot)
			if info then
				stacks[#stacks + 1] = {
					bag = bag, slot = slot, item = info.itemID, count = info.stackCount,
					locked = info.isLocked, bound = info.isBound,
				}
			elseif bag <= plain and family == 0 then
				free[#free + 1] = { bag = bag, slot = slot }
			end
		end
	end
	return stacks, free
end

-- Mailable count per item in the bags (soulbound stacks left out).
function Mail.Counts()
	local counts = {}
	for _, s in ipairs((readBags())) do
		if not s.bound then
			counts[s.item] = (counts[s.item] or 0) + s.count
		end
	end
	return counts
end

local function listOf(reagents)
	local parts = {}
	for _, r in ipairs(reagents) do
		parts[#parts + 1] = r.count .. " " .. itemName(r.item)
	end
	return table.concat(parts, ", ")
end

local function problemText(problems)
	local missing = {}
	for _, p in ipairs(problems) do
		if p.code == "missing" then
			missing[#missing + 1] = L.MISSING_ITEM:format(itemName(p.item), p.have, p.need)
		end
	end
	if #missing > 0 then
		return L.MISSING:format(table.concat(missing, ", "))
	end
	local p = problems[1]
	if p.code == "slots" then
		return L.SLOTS:format(p.need, p.have)
	end
	return L.TOO_MANY:format(p.need, p.max)
end

local function bodyText(recipe, sent, own)
	local lines = { L.BODY:format(recipe), "" }
	lines[#lines + 1] = #sent > 0 and L.SENT:format(listOf(sent)) or L.NOTHING
	if #own > 0 then
		lines[#lines + 1] = L.OWN:format(listOf(own))
	end
	lines[#lines + 1] = ""
	lines[#lines + 1] = L.SIGNED
	return table.concat(lines, "\n"):sub(1, BODY_MAX)
end

local function attach(bag, slot)
	C_Container.PickupContainerItem(bag, slot)
	ClickSendMailItemButton()
end

local function finish(text)
	local done = job
	job = nil
	if text then
		return fail(text)
	end
	ns.Print(L.READY:format(done.recipe, done.owner))
	return true
end

-- Attaches each split stack once it sits, unlocked, in its target slot.
local function poll()
	if not job then
		return
	end
	if not mailOpen() then
		return finish(L.CLOSED)
	end
	-- An item on the cursor would be swapped into the bag: wait for it to go.
	if not GetCursorInfo() then
		for i = #job.pending, 1, -1 do
			local s = job.pending[i]
			local info = C_Container.GetContainerItemInfo(s.to.bag, s.to.slot)
			if info and info.itemID == s.item and info.stackCount == s.count and not info.isLocked then
				attach(s.to.bag, s.to.slot)
				table.remove(job.pending, i)
			end
		end
	end
	if #job.pending == 0 then
		return finish()
	end
	if GetTime() > job.deadline then
		return finish(L.FAILED:format(listOf(job.pending)))
	end
	C_Timer.After(WAIT, poll)
end

-- Prepares the mail: `provided` is a set of reagent item IDs the player
-- sends; the crafter supplies the others. Returns true once the mail is
-- filled, or false after showing the reason in red.
function Mail.Prepare(recipeID, owner, provided)
	if job then
		return fail(L.BUSY)
	end
	if not mailOpen() then
		return fail(L.NO_MAILBOX)
	end
	if owner == ns.me then
		return fail(L.SELF)
	end
	local reagents = Order.Reagents(recipeID)
	if not reagents then
		return fail(L.UNKNOWN)
	end
	if GetCursorInfo() then
		return fail(L.CURSOR)
	end
	for i = 1, ATTACHMENTS_MAX_SEND or Order.MAX_ATTACHMENTS do
		if HasSendMailItem(i) then
			return fail(L.NOT_EMPTY)
		end
	end
	local sent, own = {}, {}
	for _, r in ipairs(reagents) do
		if provided[r.item] then
			sent[#sent + 1] = r
		else
			own[#own + 1] = r
		end
	end
	local stacks, free = readBags()
	local steps, problems = Order.Plan(sent, stacks, free)
	if not steps then
		return fail(problemText(problems))
	end

	if SendMailFrame and not SendMailFrame:IsShown() and MailFrameTab_OnClick then
		MailFrameTab_OnClick(nil, 2)
	end
	local recipe = recipeName(recipeID)
	SendMailNameEditBox:SetText(owner)
	SendMailSubjectEditBox:SetText(L.SUBJECT:format(recipe):sub(1, SUBJECT_MAX))
	SendMailBodyEditBox:SetText(bodyText(recipe, sent, own))

	local pending = {}
	for _, s in ipairs(steps) do
		if s.to then
			C_Container.SplitContainerItem(s.bag, s.slot, s.count)
			C_Container.PickupContainerItem(s.to.bag, s.to.slot)
			pending[#pending + 1] = s
		else
			attach(s.bag, s.slot)
		end
	end
	job = { recipe = recipe, owner = owner, pending = pending, deadline = GetTime() + TIMEOUT }
	if #pending == 0 then
		return finish()
	end
	C_Timer.After(WAIT, poll)
	return true
end

function Mail.Busy()
	return job ~= nil
end
