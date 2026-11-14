-- UI smoke test: lua-5.1 tests/ui_smoke.lua (from the project root).
-- Runs the window code against a permissive fake client: every widget
-- method exists and does nothing unless modelled below. Catches runtime
-- errors (nil fields, wrong calls) in paths the headless sync tests skip.

local failures = 0
local function check(cond, msg)
	if not cond then
		failures = failures + 1
		print("FAIL: " .. msg)
	end
end

---------------------------------------------------------------- fake widgets

local Widget = {}
local created = {} -- every widget, so the test can find the window's rows
local function newWidget(kind, name, parent)
	local w = setmetatable({ _kind = kind, _shown = kind ~= "Frame" or false, _scripts = {}, _parent = parent,
		_w = 100, _h = 100, _text = "" }, Widget)
	if name then
		_G[name] = w
	end
	created[#created + 1] = w
	return w
end
Widget.__index = function(self, key)
	local m = rawget(Widget, key)
	if m then
		return m
	end
	-- Unknown methods: accept and do nothing.
	return function() return nil end
end
function Widget:Show() self._shown = true; local f = self._scripts.OnShow; if f then f(self) end end
function Widget:Hide()
	local was = self._shown
	self._shown = false
	local f = self._scripts.OnHide
	if f and was then f(self) end
end
function Widget:SetShown(v) if v then self:Show() else self:Hide() end end
function Widget:IsShown() return self._shown end
function Widget:IsVisible() return self._shown end
function Widget:SetScript(n, f) self._scripts[n] = f end
function Widget:GetScript(n) return self._scripts[n] end
function Widget:HookScript(n, f)
	local old = self._scripts[n]
	self._scripts[n] = function(...) if old then old(...) end f(...) end
end
function Widget:SetSize(w, h) self._w, self._h = w, h end
function Widget:SetWidth(w) self._w = w end
function Widget:SetHeight(h) self._h = h end
function Widget:GetWidth() return self._w end
function Widget:GetHeight() return self._h end
function Widget:SetText(t) self._text = t end
function Widget:GetText() return self._text end
function Widget:SetChecked(v) self._checked = v end
function Widget:GetChecked() return self._checked end
function Widget:CreateTexture() return newWidget("Texture") end
function Widget:CreateFontString() return newWidget("FontString") end
function Widget:GetFrameLevel() return 1 end
function Widget:SetFontObject(f) self._font = f end
function Widget:Click(button) local f = self._scripts.OnClick; if f then f(self, button or "LeftButton") end end

CreateFrame = function(kind, name, parent, template)
	local w = newWidget(kind, name, parent)
	w._shown = true
	if template == "BasicFrameTemplateWithInset" then
		w.TitleText = newWidget("FontString")
		w.CloseButton = newWidget("Button")
	elseif template == "SearchBoxTemplate" then
		w.Instructions = newWidget("FontString")
	elseif template == "RightSideTabTemplate" then
		w.Icon = newWidget("Texture")
	end
	return w
end

---------------------------------------------------------------- fake API

local clock = 0
local timers = {}
UIParent = newWidget("Frame")
UISpecialFrames = {}
SlashCmdList = {}
ITEM_QUALITY_COLORS = { [1] = { r = 1, g = 1, b = 1 } }
GameTooltip = newWidget("GameTooltip")
GameTooltip_Hide = function() end
tinsert = table.insert
date = os.date
GetTime = function() return clock end
GetServerTime = function() return 1800000000 + math.floor(clock) end
C_Timer = {
	After = function(sec, fn) timers[#timers + 1] = { at = clock + sec, fn = fn } end,
	NewTicker = function(sec, fn) return { Cancel = function() end } end,
}
local function runTimers(limit)
	while true do
		table.sort(timers, function(a, b) return a.at < b.at end)
		local t = timers[1]
		if not t or t.at > limit then break end
		table.remove(timers, 1)
		clock = t.at
		t.fn()
	end
	clock = limit
end
C_ChatInfo = { RegisterAddonMessagePrefix = function() return 0 end, SendAddonMessage = function() return 0 end }
C_GuildInfo = { GuildRoster = function() end }
IsInGuild = function() return true end
GetGuildInfo = function() return "Test Guild", "Member", 1, nil end
GetNumGuildMembers = function() return 2 end
GetGuildRosterInfo = function(i)
	if i == 1 then return "Alice Smith", "", 0, 60, "", "", "", "", true end
	return "Bob Jones", "", 0, 60, "", "", "", "", false
end
UnitName = function() return "Alice" end
UnitFullName = function() return "Alice", nil end
Ambiguate = function(n) return n end
-- The spellbook answers nothing during the first seconds, as on a first login.
GetProfessions = function()
	if clock < 5 then return end
	return 1, 2, 3
end
GetProfessionInfo = function(i)
	if i == 1 then return "Tailoring", 0, 112, 150, 0, 0, 197 end
	if i == 2 then return "Enchanting", 0, 126, 150, 0, 0, 333 end
	return "Blacksmithing", 0, 126, 150, 0, 0, 164
end
-- 2675: a Blacksmithing recipe whose data minimum (135) is above the skill.
local known = { [2963] = true, [7418] = true, [2672] = true, [2675] = true }
local claimAll
C_SpellBook = { IsSpellKnown = function(id) return claimAll or known[id] or false end }
C_TradeSkillUI = { GetTradeSkillDisplayName = function() return nil end }
C_Spell = {
	GetSpellName = function(id) return "Spell " .. id end,
	GetSpellTexture = function() return 1 end,
	GetSpellLink = function() return nil end,
}
C_Item = {
	GetItemIconByID = function() return 2 end,
	GetItemQualityByID = function() return 1 end,
	GetItemNameByID = function(id) return "Item " .. id end,
	RequestLoadItemDataByID = function() end,
	GetItemInfo = function() return nil end,
}
IsModifiedClick = function() return false end
HandleModifiedItemClick = function() return false end
local whispered
ChatFrameUtil = { SendTell = function(name) whispered = name end }
hooksecurefunc = function(t, name, fn)
	local old = t[name]
	t[name] = function(...) local r = old(...) fn(...) return r end
end

-- Bags, cursor and the Send Mail tab. A split dropped on an empty slot
-- lands locked and unlocks a moment later, as when the server confirms it.
local bags = { [0] = {} }      -- bag -> slot -> { itemID, stackCount, isLocked, isBound }
local BAG_SIZE = { [0] = 16 }
local cursor                   -- { stack } or { split, from, count }
local attached = {}            -- { itemID, count } per attachment
local redErrors = {}
NUM_BAG_SLOTS = 4
ATTACHMENTS_MAX_SEND = 12
C_Container = {
	GetContainerNumSlots = function(b) return BAG_SIZE[b] or 0 end,
	GetContainerNumFreeSlots = function(b)
		local n = 0
		for s = 1, BAG_SIZE[b] or 0 do
			if not (bags[b] and bags[b][s]) then n = n + 1 end
		end
		return n, 0
	end,
	GetContainerItemInfo = function(b, s)
		local i = bags[b] and bags[b][s]
		if i then
			return { itemID = i.itemID, stackCount = i.stackCount, isLocked = i.isLocked or false, isBound = i.isBound or false }
		end
	end,
	SplitContainerItem = function(b, s, n)
		local i = bags[b] and bags[b][s]
		assert(i and not cursor and n < i.stackCount, "split of a stack larger than n, empty cursor")
		cursor = { split = true, from = i, count = n }
	end,
	PickupContainerItem = function(b, s)
		local i = bags[b] and bags[b][s]
		if cursor and cursor.split then
			assert(not i, "a split goes to an empty slot")
			cursor.from.stackCount = cursor.from.stackCount - cursor.count
			local placed = { itemID = cursor.from.itemID, stackCount = cursor.count, isLocked = true }
			bags[b] = bags[b] or {}
			bags[b][s] = placed
			C_Timer.After(0.25, function() placed.isLocked = false end)
			cursor = nil
		else
			assert(not cursor, "pickup with an item on the cursor")
			assert(i and not i.isLocked, "pickup of an empty or locked slot")
			cursor = { stack = i }
		end
	end,
}
ClickSendMailItemButton = function()
	assert(cursor and cursor.stack, "attach with a whole stack on the cursor")
	cursor.stack.isLocked = true
	attached[#attached + 1] = { itemID = cursor.stack.itemID, count = cursor.stack.stackCount }
	cursor = nil
end
HasSendMailItem = function(i) return attached[i] ~= nil end
GetCursorInfo = function() if cursor then return "item" end end
ClearCursor = function() cursor = nil end
UIErrorsFrame = { AddMessage = function(_, text) redErrors[#redErrors + 1] = text end }
MailFrame = newWidget("Frame")
SendMailFrame = newWidget("Frame")
SendMailNameEditBox = newWidget("EditBox")
SendMailSubjectEditBox = newWidget("EditBox")
SendMailBodyEditBox = newWidget("EditBox")
MailFrameTab_OnClick = function(_, tab) SendMailFrame:SetShown(tab == 2) end

local tocVersion
for line in io.lines("GuildProf/GuildProf.toc") do
	tocVersion = tocVersion or line:match("^## Version: (%S+)")
end
C_AddOns = {
	GetAddOnMetadata = function(name, field)
		if name == "GuildProf" and field == "Version" then return tocVersion end
	end,
}

---------------------------------------------------------------- load

local ns = {}
local files = {}
for line in io.lines("GuildProf/GuildProf.toc") do
	local f = line:match("^([%w\\_]+%.lua)$")
	if f then
		files[#files + 1] = "GuildProf/" .. f:gsub("\\", "/")
	end
end
local onEvent
local realCreate = CreateFrame
CreateFrame = function(kind, ...)
	local w = realCreate(kind, ...)
	local set = w.SetScript
	w.SetScript = function(self, n, f) if n == "OnEvent" then onEvent = f end return set(self, n, f) end
	return w
end
for _, f in ipairs(files) do
	assert(loadfile(f))("GuildProf", ns)
end
CreateFrame = realCreate

local function event(name, ...)
	onEvent(nil, name, ...)
end

local ok, err = pcall(function()
	event("ADDON_LOADED", "GuildProf")
	event("PLAYER_LOGIN")
	runTimers(clock + 3)
	local early = ns.Store.Get(ns.me)
	check(not (early and ns.Codec.DecodeProfs(early.data)[197]), "spellbook still empty at the first scan")
	runTimers(clock + 9) -- the follow-up scan at 10 s

	-- A second member's record arrives over the guild channel.
	local C = ns.Codec
	ns.Store.Put("Bob Jones", 1800000500, C.EncodeProfs({
		[197] = { level = 150, max = 150, ids = C.EncodeIDs({ 2963, 2964, 18560 }) },
		[182] = { level = 112, max = 150 },
	}))

	-- Spellbook scan stored the player's recipes without any window.
	local own = ns.Store.Get(ns.me)
	check(own and C.DecodeProfs(own.data)[197].ids ~= nil, "a later scan stored Tailoring recipes")
	local bs = own and C.DecodeProfs(own.data)[164]
	local bsIds = bs and bs.ids and C.DecodeIDs(bs.ids) or {}
	check(#bsIds == 2, "Blacksmithing recipes kept despite a data minimum above the skill (" .. #bsIds .. ")")

	ns.UI.Toggle()
	check(GuildProfFrame:IsShown(), "window opens")
	runTimers(clock + 1)
end)
check(ok, "load and open: " .. tostring(err))

-- Collect row buttons: Buttons whose entry field is set by refreshList.
local function rows()
	local out = {}
	for _, w in ipairs(created) do
		if rawget(w, "entry") then
			out[#out + 1] = w
		end
	end
	return out
end

ok, err = pcall(function()
	-- The window opens on the first profession with members (Enchanting);
	-- switch to Tailoring like a player would.
	for _, w in ipairs(created) do
		if rawget(w, "sl") == 197 then
			w:Click()
		end
	end
	local kinds = {}
	for _, r in ipairs(rows()) do
		kinds[r.entry.kind] = (kinds[r.entry.kind] or 0) + 1
	end
	check((kinds.header or 0) >= 2, "two section headers")
	check((kinds.member or 0) >= 1, "member rows listed")
	check((kinds.recipe or 0) >= 1, "recipe rows listed")

	-- Hover and click every row kind.
	for _, r in ipairs(rows()) do
		if r:IsShown() then
			r._scripts.OnEnter(r)
		end
	end
	local member, foldHeader
	for _, r in ipairs(rows()) do
		if r.entry.kind == "member" and r.entry.m.owner == "Bob Jones" then member = r end
		if r.entry.kind == "header" and r.entry.key == "members" then foldHeader = r end
	end
	check(member ~= nil, "Bob listed as a tailor")
	member:Click("LeftButton") -- filter to Bob's recipes
	local recipes = 0
	for _, r in ipairs(rows()) do
		if r:IsShown() and r.entry.kind == "recipe" then recipes = recipes + 1 end
	end
	check(recipes == 3, "filter shows Bob's 3 recipes (" .. recipes .. ")")
	for _, r in ipairs(rows()) do
		if r:IsShown() and r.entry.kind == "member" and r.entry.m.owner == "Bob Jones" then
			r:Click("RightButton")
		end
	end
	check(whispered == "Bob Jones", "right-click whispers")
	for _, r in ipairs(rows()) do
		if r:IsShown() and r.entry.kind == "recipe" then r:Click("LeftButton") break end
	end
	foldHeader:Click("LeftButton")
	local members = 0
	for _, r in ipairs(rows()) do
		if r:IsShown() and r.entry.kind == "member" then members = members + 1 end
	end
	check(members == 0, "folded section hides members")
end)
check(ok, "rows: " .. tostring(err))

-- Recipe categories: in the profession window's order, foldable, and
-- unfolded while a search is set.
ok, err = pcall(function()
	local C, cats = ns.Codec, ns.RecipeCategories
	local camping, bags = cats[2591][3], cats[2578][3]
	ns.Store.Put("Dana Bags", 1800000700, C.EncodeProfs({
		[197] = { level = 100, max = 150, ids = C.EncodeIDs({ camping, bags }) },
	}))
	for _, r in ipairs(rows()) do
		if r:IsShown() and r.entry.kind == "header" and r.entry.key == "recipes" then r:Click("LeftButton") end
	end
	local function shown()
		local out = {}
		for _, r in ipairs(rows()) do
			if r:IsShown() then out[#out + 1] = r.entry end
		end
		return out
	end
	local names, under = {}, {}
	local current
	for _, e in ipairs(shown()) do
		if e.kind == "category" then
			current = e.text:sub(3)
			names[#names + 1] = current
		elseif e.kind == "recipe" then
			under[e.id] = current
		end
	end
	check(table.concat(names, ",") == "Camping,Reagents,Bags", "categories in window order: " .. table.concat(names, ","))
	for _, r in ipairs(rows()) do
		if r:IsShown() and r.entry.kind == "category" then
			check(r.text._font == "GameFontNormal" and r.band:IsShown(), "category header: normal font and band")
		elseif r:IsShown() and r.entry.kind == "recipe" then
			check(not r.band:IsShown(), "no band behind a recipe row")
		end
	end
	check(under[camping] == "Camping" and under[bags] == "Bags" and under[2963] == "Reagents", "recipes under their category")
	local function count(id)
		local n = 0
		for _, e in ipairs(shown()) do
			if e.kind == "recipe" and e.id == id then n = n + 1 end
		end
		return n
	end
	for _, r in ipairs(rows()) do
		if r:IsShown() and r.entry.kind == "category" and r.entry.key == 2576 then
			r._scripts.OnEnter(r)
			r:Click("LeftButton")
			break
		end
	end
	check(count(2963) == 0 and count(bags) == 1, "a folded category hides only its recipes")
	local searchBox
	for _, w in ipairs(created) do
		if rawget(w, "Instructions") then searchBox = w end
	end
	searchBox:SetText("Spell")
	ns.UI.Refresh()
	check(count(2963) == 1, "a search shows recipes of folded categories")
	searchBox:SetText("")
	ns.UI.Refresh()
	check(count(2963) == 0, "the fold returns when the search is cleared")
end)
check(ok, "categories: " .. tostring(err))

-- Detail: the required skill shows only when the data has a real minimum.
ok, err = pcall(function()
	local function texts()
		local out = {}
		for _, w in ipairs(created) do
			if w._kind == "FontString" and w._shown and type(w._text) == "string" then out[#out + 1] = w._text end
		end
		return table.concat(out, "\n")
	end
	local function pick(sl, id)
		for _, w in ipairs(created) do
			if rawget(w, "sl") == sl then w:Click() end
		end
		for _, r in ipairs(rows()) do
			if r:IsShown() and r.entry.kind == "category" and r.entry.text:sub(1, 1) == "+" then r:Click("LeftButton") end
		end
		for _, r in ipairs(rows()) do
			if r:IsShown() and r.entry.kind == "recipe" and r.entry.id == id then r:Click("LeftButton") return true end
		end
	end
	check(pick(197, 2963), "Tailoring recipe 2963 listed")
	check(not texts():find("Requires Tailoring", 1, true), "no 'Requires (1)' for a minimum of 1")
	check(pick(164, 2675), "Blacksmithing recipe 2675 listed")
	check(texts():find("Requires Blacksmithing (135)", 1, true), "a real minimum is shown")
end)
check(ok, "detail: " .. tostring(err))

-- Work order: reagent boxes follow the bags; the mail icon fills the Send
-- Mail tab, attaches whole stacks at once and a split once it lands.
ok, err = pcall(function()
	local C, Mail = ns.Codec, ns.Mail
	-- 1292963: 3 x 274030, 2 x 14342, 16 x 14048, 8 x 14341.
	ns.Store.Put("Erin Cloth", 1800000800, C.EncodeProfs({
		[197] = { level = 150, max = 150, ids = C.EncodeIDs({ 1292963 }) },
	}))
	local function fill()
		bags[0] = {
			[1] = { itemID = 274030, stackCount = 3 },  -- exact stack
			[2] = { itemID = 14342, stackCount = 5 },   -- split 2 off
			[3] = { itemID = 14048, stackCount = 10 },  -- 10 + 6, whole
			[4] = { itemID = 14048, stackCount = 6 },
			[5] = { itemID = 14341, stackCount = 8, isBound = true }, -- not mailable
		}
		attached, redErrors, cursor = {}, {}, nil
		SendMailNameEditBox:SetText("")
	end
	fill()
	local function pick(id)
		for _, w in ipairs(created) do
			if rawget(w, "sl") == 197 then w:Click() end
		end
		for _, r in ipairs(rows()) do
			if r:IsShown() and r.entry.kind == "category" and r.entry.text:sub(1, 1) == "+" then r:Click("LeftButton") end
		end
		for _, r in ipairs(rows()) do
			if r:IsShown() and r.entry.kind == "recipe" and r.entry.id == id then r:Click("LeftButton") return true end
		end
	end
	local function boxes()
		local out = {}
		for _, w in ipairs(created) do
			if rawget(w, "check") and w._shown and rawget(w, "item") then out[w.item] = w end
		end
		return out
	end
	local function order(owner)
		for _, w in ipairs(created) do
			if rawget(w, "mail") and w._shown and rawget(w, "owner") == owner then
				check(w.mail:IsShown(), "mail icon on " .. owner)
				w.mail._scripts.OnEnter(w.mail)
				w.mail:Click()
				return true
			end
		end
	end
	local function sent(item)
		local n = 0
		for _, a in ipairs(attached) do
			if a.itemID == item then n = n + 1 end
		end
		return n
	end

	check(pick(1292963), "recipe 1292963 listed")
	local b = boxes()
	check(b[274030] and b[274030].check:GetChecked(), "box checked: bags hold 3 of 3")
	check(b[14048] and b[14048].check:GetChecked(), "box checked: 16 of 16 over two stacks")
	check(b[14341] and not b[14341].check:GetChecked(), "box unchecked: the only stack is soulbound")
	check(b[14341].text:GetText():find("(0)", 1, true), "soulbound stack counted as none: " .. b[14341].text:GetText())

	-- No mailbox: a red error and nothing filled.
	check(order("Erin Cloth"), "Erin listed as a crafter")
	check(redErrors[1] == Mail.L.NO_MAILBOX, "red error without a mailbox: " .. tostring(redErrors[1]))
	check(SendMailNameEditBox:GetText() == "" and #attached == 0, "nothing filled without a mailbox")

	-- Mailbox open on the inbox tab.
	MailFrame:Show()
	SendMailFrame:Hide()
	order("Erin Cloth")
	check(#redErrors == 1, "no error with a mailbox: " .. tostring(redErrors[2]))
	check(SendMailFrame:IsShown(), "switched to the Send Mail tab")
	check(SendMailNameEditBox:GetText() == "Erin Cloth", "recipient")
	check(SendMailSubjectEditBox:GetText() == "Work order: Spell 1292963", "subject: " .. SendMailSubjectEditBox:GetText())
	local body = SendMailBodyEditBox:GetText()
	check(body:find("Included: 3 Item 274030, 2 Item 14342, 16 Item 14048.", 1, true), "body lists the sent reagents:\n" .. body)
	check(body:find("Please use your own: 8 Item 14341.", 1, true), "body lists the crafter's reagents")
	check(#body <= 500, "body within the mail limit")
	check(#attached == 3 and Mail.Busy(), "whole stacks at once, the split waits (" .. #attached .. ")")
	runTimers(clock + 1)
	check(#attached == 4 and not Mail.Busy(), "split attached once it landed (" .. #attached .. ")")
	check(sent(274030) == 1 and sent(14342) == 1 and sent(14048) == 2, "one attachment per stack")
	check(attached[4].itemID == 14342 and attached[4].count == 2, "the split sends exactly 2")
	check(bags[0][2].stackCount == 3, "3 left of the split stack")

	-- A second order while the mail holds items: refused.
	order("Erin Cloth")
	check(redErrors[#redErrors] == Mail.L.NOT_EMPTY, "refused while the mail has items")

	-- Ticking a reagent the bags lack: every shortfall named, nothing attached.
	fill()
	pick(1292963)
	local box = boxes()[14341].check
	box:SetChecked(true)
	box:Click()
	order("Erin Cloth")
	check(redErrors[1] and redErrors[1]:find("Item 14341 (0 of 8)", 1, true), "missing reagent named: " .. tostring(redErrors[1]))
	check(#attached == 0, "nothing attached when a reagent is missing")
	box:SetChecked(false)
	box:Click()

	-- The mailbox closes while a split is on its way.
	fill()
	order("Erin Cloth")
	MailFrame:Hide()
	runTimers(clock + 1)
	check(redErrors[#redErrors] == Mail.L.CLOSED and not Mail.Busy(), "closing the mailbox ends the order")

	-- Bag changes refresh the counts.
	fill()
	MailFrame:Show()
	bags[0][5] = nil
	ns.UI.OnBagsChanged()
	runTimers(clock + 1)
	check(boxes()[14341].text:GetText():find("(0)", 1, true), "counts refreshed after a bag change")
	MailFrame:Hide()
	-- Later sections count the guild's records.
	ns.Store.Remove("Erin Cloth")
end)
check(ok, "work order: " .. tostring(err))

-- Guild frame tab.
ok, err = pcall(function()
	local cf = CreateFrame("Frame", "CommunitiesFrame", UIParent)
	cf._w = 814
	for _, k in ipairs({ "ChatTab", "RosterTab", "GuildBenefitsTab", "GuildInfoTab", "GuildPreferredPlaySettingsTab" }) do
		cf[k] = CreateFrame("CheckButton", nil, cf)
	end
	cf.GuildPreferredPlaySettingsTab._shown = false
	function cf:UpdateCommunitiesTabs() end
	function cf:SetDisplayMode() end
	ns.UI.Toggle() -- close the floating window first
	event("ADDON_LOADED", "Blizzard_Communities")
	cf:UpdateCommunitiesTabs()
	check(GuildProfGuildTab and GuildProfGuildTab:IsShown(), "guild tab shown under the guild tabs")
	GuildProfGuildTab:Click()
	check(GuildProfFrame:IsShown(), "tab opens the window on the guild frame")
	cf:SetDisplayMode(2)
	check(not GuildProfFrame:IsShown(), "a Blizzard tab takes the content back")
	GuildProfGuildTab:Click()
	cf:Hide()
	check(not GuildProfFrame:IsShown(), "closing the guild frame closes the window")
	ns.UI.Toggle()
	check(GuildProfFrame:IsShown() and GuildProfFrame:GetWidth() == 820, "/gp floats it again at full size")
end)
check(ok, "guild tab: " .. tostring(err))

-- Departed members: a roster update removes the record of a character the
-- roster no longer lists, once the roster finds the player under the
-- server's form of the name.
ok, err = pcall(function()
	local C = ns.Codec
	local gone = C.EncodeProfs({ [197] = { level = 90, max = 150, ids = C.EncodeIDs({ 2963 }) } })
	ns.Store.Put("Carol Gone", 1800000600, gone)
	event("GUILD_ROSTER_UPDATE")
	check(ns.Store.Get("Carol Gone") ~= nil, "roster without the player's server name: nothing removed")
	check(ns.db.diag.roster:find("trusted false"), "diag.roster: " .. tostring(ns.db.diag.roster))
	ns.Sync.OnOwnEcho("Alice Smith")
	event("GUILD_ROSTER_UPDATE")
	check(ns.Store.Get("Carol Gone") == nil, "a roster update removes the departed member")
	check(ns.Store.Get("Bob Jones") ~= nil and ns.Store.Get("Alice Smith") ~= nil, "members and own record kept")
	check(ns.db.diag.roster == "2/2 listed, trusted true, first Alice Smith", "diag.roster: " .. tostring(ns.db.diag.roster))
	check(ns.IsOnline("Alice Smith") == true and ns.IsOnline("Bob Jones") == false, "online state from the roster")
	runTimers(clock + 2)
	for _, r in ipairs(rows()) do
		check(not (r:IsShown() and r.entry.kind == "member" and r.entry.m.owner == "Carol Gone"), "departed member left the list")
	end
	local realPrint, out = print, {}
	print = function(...) out[#out + 1] = table.concat({ ... }, " ") end
	SlashCmdList.GUILDPROF("status")
	print = realPrint
	local found
	for _, l in ipairs(out) do
		if l:find("prune: removed Carol Gone", 1, true) then found = true end
	end
	check(found, "/gp status shows the last prune")

	-- A record left under the guessed name while another table was bound
	-- moves under the server's form when the guild is bound again.
	check(ns.guess == "Alice" and ns.me == "Alice Smith", "guessed name kept beside the server's form")
	local rev = ns.Store.Get(ns.me).rev
	ns.Store.Put(ns.guess, rev - 10, gone)
	IsInGuild = function() return false end
	event("PLAYER_GUILD_UPDATE")
	IsInGuild = function() return true end
	event("PLAYER_GUILD_UPDATE")
	check(ns.Store.Get("Alice") == nil and ns.Store.Get("Alice Smith").rev == rev and ns.Store.Get("Bob Jones") ~= nil,
		"guild bound again: no record under the guessed name")
	event("GUILD_ROSTER_UPDATE")
end)
check(ok, "prune: " .. tostring(err))

-- Spellbook scans: a method that calls every recipe known is rejected and
-- the record keeps its recipes; SPELLS_CHANGED rescans.
ok, err = pcall(function()
	local C = ns.Codec
	local function tailoring()
		local p = C.DecodeProfs(ns.Store.Get(ns.me).data)[197]
		return p and p.ids and C.DecodeIDs(p.ids) or {}
	end
	claimAll = true
	ns.Scan.Basic()
	claimAll = nil
	check(#tailoring() == 1, "a method claiming every recipe is rejected (" .. #tailoring() .. " kept)")
	check(ns.db.diag.basic:find("claims", 1, true), "diag names the rejection: " .. tostring(ns.db.diag.basic))
	check(ns.Recipes[2964] and ns.Recipes[2964][1] == 197, "2964 is a Tailoring recipe")
	known[2964] = true
	event("SPELLS_CHANGED")
	runTimers(clock + 2)
	check(#tailoring() == 2, "SPELLS_CHANGED rescans (" .. #tailoring() .. ")")
end)
check(ok, "scans: " .. tostring(err))

-- Versions: a member's newer V puts an update row at the top of the list;
-- clicking it shows the download link, selected and read-only.
ok, err = pcall(function()
	check(ns.Version.mine == tocVersion, "version read from the TOC (" .. tostring(ns.Version.mine) .. ")")
	local realPrint, out = print, {}
	print = function(...) out[#out + 1] = table.concat({ ... }, " ") end
	ns.Sync.OnBody("V9.0.0", "GUILD", "Bob Jones")
	ns.Sync.OnBody("V9.0.0", "GUILD", "Bob Jones")
	runTimers(clock + 1)
	print = realPrint
	check(ns.Version.newest == "9.0.0", "newer version noted")
	check(#out == 1 and out[1]:find("/gp update", 1, true), "said once in chat: " .. tostring(out[1]))
	local update
	for _, r in ipairs(rows()) do
		if r:IsShown() and r.entry.kind == "update" then update = r end
	end
	check(update ~= nil and update.entry == rows()[1].entry, "update row first in the list")
	update._scripts.OnEnter(update)
	update:Click("LeftButton")
	local edit
	for _, w in ipairs(created) do
		if w._kind == "EditBox" and w._text == ns.Version.URL then edit = w end
	end
	check(edit ~= nil, "link box shows the download link")
	edit:SetText("typed over")
	edit._scripts.OnTextChanged(edit)
	check(edit:GetText() == ns.Version.URL, "the link cannot be edited away")
	for _, r in ipairs(rows()) do
		if r:IsShown() and r.entry.kind == "member" then r._scripts.OnEnter(r) end
	end
	out = {}
	print = function(...) out[#out + 1] = table.concat({ ... }, " ") end
	SlashCmdList.GUILDPROF("update")
	SlashCmdList.GUILDPROF("status")
	print = realPrint
	local line
	for _, l in ipairs(out) do
		if l:find("version:", 1, true) then line = l end
	end
	check(line and line:find("older: Alice Smith (" .. tocVersion .. ")", 1, true), "status: " .. tostring(line))
	check(GuildProfFrame.members:GetText():find("1 on an older version", 1, true), "older count under the professions")
end)
check(ok, "versions: " .. tostring(err))

print(("ui smoke: %d failures"):format(failures))
os.exit(failures == 0 and 0 or 1)
