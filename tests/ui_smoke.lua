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
GetProfessions = function() return 1, 2 end
GetProfessionInfo = function(i)
	if i == 1 then return "Tailoring", 0, 112, 150, 0, 0, 197 end
	return "Enchanting", 0, 126, 150, 0, 0, 333
end
C_SpellBook = { IsSpellKnown = function(id) return id == 2963 or id == 7418 end }
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

	-- A second member's record arrives over the guild channel.
	local C = ns.Codec
	ns.Store.Put("Bob Jones", 1800000500, C.EncodeProfs({
		[197] = { level = 150, max = 150, ids = C.EncodeIDs({ 2963, 2964, 18560 }) },
		[182] = { level = 112, max = 150 },
	}))

	-- Spellbook scan stored the player's recipes without any window.
	local own = ns.Store.Get(ns.me)
	check(own and C.DecodeProfs(own.data)[197].ids ~= nil, "spellbook scan stored Tailoring recipes")

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

print(("ui smoke: %d failures"):format(failures))
os.exit(failures == 0 and 0 or 1)
