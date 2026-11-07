local _, ns = ...

-- Main window, three columns:
--   professions | recipes someone in the guild knows (search box on top) | detail
-- Hovering a recipe or reagent shows its item tooltip; clicking a recipe
-- shows its reagents and who can craft it; clicking a crafter whispers them;
-- shift-click links the item in chat.

local Index = ns.Index
local UI = {}
ns.UI = UI

local L = {
	TITLE = "GuildProf",
	SEARCH = "Search recipes",
	REAGENTS = "Reagents",
	CRAFTERS = "Can craft it",
	NOBODY = "Nobody in the guild",
	PICK = "Pick a recipe",
	REQUIRES = "Requires %s (%s)",
	MORE = "+%s more",
	NO_GUILD = "Not in a guild",
	CRAFTER_HINT = "Click to whisper",
}
UI.L = L

-- Crafting professions in display order. The gathering ones (Herbalism,
-- Skinning, Fishing) also have a few crafts on Forever; listed separately
-- in ns.GATHERING and left out of the window for now.
ns.CRAFTING = { 171, 164, 333, 202, 165, 197, 185, 129, 186 }
ns.GATHERING = { 182, 393, 356 }
local FALLBACK = {
	[171] = "Alchemy", [164] = "Blacksmithing", [333] = "Enchanting", [202] = "Engineering",
	[165] = "Leatherworking", [197] = "Tailoring", [185] = "Cooking", [129] = "First Aid",
	[186] = "Mining", [182] = "Herbalism", [393] = "Skinning", [356] = "Fishing",
}

local tracked = {}
for _, sl in ipairs(ns.CRAFTING) do tracked[sl] = true end
for _, sl in ipairs(ns.GATHERING) do tracked[sl] = true end
function ns.IsTracked(sl)
	return tracked[sl] == true
end

function ns.ProfName(sl)
	local name = C_TradeSkillUI and C_TradeSkillUI.GetTradeSkillDisplayName
		and C_TradeSkillUI.GetTradeSkillDisplayName(sl)
	if type(name) == "string" and name ~= "" then
		return name
	end
	return FALLBACK[sl] or tostring(sl)
end

local ROW_H = 20
local frame, profButtons, rows, scroll, content, search, detail
local selectedProf, selectedRecipe

---------------------------------------------------------------- helpers

local function recipeData(id)
	return ns.Recipes[id]
end

local function itemOf(id)
	local d = recipeData(id)
	return d and d[3] or 0
end

local function recipeName(id)
	return (C_Spell.GetSpellName and C_Spell.GetSpellName(id)) or ("#" .. id)
end

local function recipeIcon(id)
	local item = itemOf(id)
	if item > 0 then
		local icon = C_Item.GetItemIconByID(item)
		if icon then
			return icon
		end
	end
	return C_Spell.GetSpellTexture(id) or 134400
end

local function qualityColor(item)
	if item and item > 0 then
		local q = C_Item.GetItemQualityByID(item)
		local c = q and ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[q]
		if c then
			return c.r, c.g, c.b
		end
		C_Item.RequestLoadItemDataByID(item)
	end
	return 1, 0.82, 0
end

local function itemName(item)
	local name = C_Item.GetItemNameByID(item)
	if not name then
		C_Item.RequestLoadItemDataByID(item)
	end
	return name
end

local function showRecipeTooltip(owner, id)
	GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
	local item = itemOf(id)
	if item > 0 then
		GameTooltip:SetItemByID(item)
	else
		GameTooltip:SetSpellByID(id)
	end
	GameTooltip:Show()
end

local function linkRecipe(id)
	local item = itemOf(id)
	local link = item > 0 and select(2, C_Item.GetItemInfo(item))
	if not link and C_Spell.GetSpellLink then
		link = C_Spell.GetSpellLink(id)
	end
	return link and HandleModifiedItemClick and HandleModifiedItemClick(link)
end

local function colorOwner(fs, owner)
	local online = ns.IsOnline(owner)
	if online == true then
		fs:SetTextColor(0.25, 1, 0.25)
	elseif online == false then
		fs:SetTextColor(0.55, 0.55, 0.55)
	else
		fs:SetTextColor(1, 1, 1)
	end
end

---------------------------------------------------------------- detail pane

local function buildDetail(parent)
	local d = CreateFrame("Frame", nil, parent)
	d:SetPoint("TOPLEFT", parent, "TOPLEFT", 540, -32)
	d:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -14, 12)

	d.icon = CreateFrame("Button", nil, d)
	d.icon:SetSize(36, 36)
	d.icon:SetPoint("TOPLEFT")
	d.icon.tex = d.icon:CreateTexture(nil, "ARTWORK")
	d.icon.tex:SetAllPoints()
	d.icon:SetScript("OnEnter", function(self)
		if selectedRecipe then showRecipeTooltip(self, selectedRecipe) end
	end)
	d.icon:SetScript("OnLeave", GameTooltip_Hide)
	d.icon:SetScript("OnClick", function()
		if selectedRecipe then linkRecipe(selectedRecipe) end
	end)

	d.name = d:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	d.name:SetPoint("TOPLEFT", d.icon, "TOPRIGHT", 8, -2)
	d.name:SetPoint("RIGHT", d, "RIGHT")
	d.name:SetJustifyH("LEFT")
	d.name:SetWordWrap(true)

	d.req = d:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	d.req:SetPoint("TOPLEFT", d.icon, "BOTTOMLEFT", 0, -6)

	d.reagentsTitle = d:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	d.reagentsTitle:SetPoint("TOPLEFT", d.req, "BOTTOMLEFT", 0, -10)
	d.reagentsTitle:SetText(L.REAGENTS)

	d.reagents = {}
	for i = 1, 8 do
		local b = CreateFrame("Button", nil, d)
		b:SetSize(240, 20)
		b:SetPoint("TOPLEFT", d.reagentsTitle, "BOTTOMLEFT", 0, -4 - (i - 1) * 22)
		b.tex = b:CreateTexture(nil, "ARTWORK")
		b.tex:SetSize(18, 18)
		b.tex:SetPoint("LEFT")
		b.text = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		b.text:SetPoint("LEFT", b.tex, "RIGHT", 6, 0)
		b.text:SetPoint("RIGHT")
		b.text:SetJustifyH("LEFT")
		b:SetScript("OnEnter", function(self)
			GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
			GameTooltip:SetItemByID(self.item)
			GameTooltip:Show()
		end)
		b:SetScript("OnLeave", GameTooltip_Hide)
		d.reagents[i] = b
	end

	d.craftersTitle = d:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	d.craftersTitle:SetText(L.CRAFTERS)

	d.crafters = {}
	for i = 1, 10 do
		local b = CreateFrame("Button", nil, d)
		b:SetSize(240, 16)
		b:SetPoint("TOPLEFT", d.craftersTitle, "BOTTOMLEFT", 0, -4 - (i - 1) * 17)
		b.text = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		b.text:SetAllPoints()
		b.text:SetJustifyH("LEFT")
		b:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
		b:SetScript("OnClick", function(self)
			if self.owner and ChatFrameUtil and ChatFrameUtil.SendTell then
				ChatFrameUtil.SendTell(self.owner)
			end
		end)
		b:SetScript("OnEnter", function(self)
			GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
			GameTooltip:SetText(self.owner or "")
			GameTooltip:AddLine(L.CRAFTER_HINT, 1, 1, 1)
			GameTooltip:Show()
		end)
		b:SetScript("OnLeave", GameTooltip_Hide)
		d.crafters[i] = b
	end
	d.more = d:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	return d
end

local function levelOf(owner, sl)
	for _, m in ipairs(Index.Members(sl)) do
		if m.owner == owner then
			return m.level
		end
	end
end

local function refreshDetail()
	local d = detail
	local id = selectedRecipe
	local shown = id ~= nil
	for _, k in ipairs({ "icon", "req", "reagentsTitle", "craftersTitle" }) do
		d[k]:SetShown(shown)
	end
	for _, b in ipairs(d.reagents) do b:Hide() end
	for _, b in ipairs(d.crafters) do b:Hide() end
	d.more:Hide()
	if not shown then
		d.name:SetText(L.PICK)
		d.name:SetTextColor(0.6, 0.6, 0.6)
		return
	end
	local data = recipeData(id)
	d.icon.tex:SetTexture(recipeIcon(id))
	d.name:SetText(recipeName(id))
	d.name:SetTextColor(qualityColor(itemOf(id)))
	local sl = data and data[1] or selectedProf
	d.req:SetText(L.REQUIRES:format(ns.ProfName(sl), data and data[2] or "?"))

	local last = d.reagentsTitle
	local n = 0
	if data then
		for i = 5, #data - 1, 2 do
			n = n + 1
			local b = d.reagents[n]
			if not b then break end
			b.item = data[i]
			b.tex:SetTexture(C_Item.GetItemIconByID(data[i]) or 134400)
			b.text:SetText((itemName(data[i]) or "...") .. " x" .. data[i + 1])
			b:Show()
			last = b
		end
	end
	d.craftersTitle:ClearAllPoints()
	d.craftersTitle:SetPoint("TOPLEFT", last, "BOTTOMLEFT", 0, -12)

	local owners = Index.Crafters(id)
	-- Online first, then by name.
	local sorted = {}
	for _, o in ipairs(owners) do sorted[#sorted + 1] = o end
	table.sort(sorted, function(a, b)
		local oa, ob = ns.IsOnline(a) == true, ns.IsOnline(b) == true
		if oa ~= ob then return oa end
		return a < b
	end)
	if #sorted == 0 then
		local b = d.crafters[1]
		b.owner = nil
		b.text:SetText(L.NOBODY)
		b.text:SetTextColor(0.55, 0.55, 0.55)
		b:Show()
	end
	for i, owner in ipairs(sorted) do
		local b = d.crafters[i]
		if not b then
			d.more:SetText(L.MORE:format(#sorted - #d.crafters))
			d.more:SetPoint("TOPLEFT", d.crafters[#d.crafters], "BOTTOMLEFT", 0, -2)
			d.more:Show()
			break
		end
		b.owner = owner
		local lvl = levelOf(owner, sl)
		b.text:SetText(owner .. (lvl and ("  (" .. lvl .. ")") or ""))
		colorOwner(b.text, owner)
		b:Show()
	end
end

---------------------------------------------------------------- recipe list

local function filteredRecipes()
	local list = {}
	if not selectedProf then
		return list
	end
	local needle = search and search:GetText():lower() or ""
	for _, id in ipairs(Index.Recipes(selectedProf)) do
		local name = recipeName(id)
		local item = itemOf(id)
		local iname = item > 0 and C_Item.GetItemNameByID(item) or nil
		if needle == "" or name:lower():find(needle, 1, true)
			or (iname and iname:lower():find(needle, 1, true)) then
			list[#list + 1] = { id = id, name = name, min = (recipeData(id) or {})[2] or 0 }
		end
	end
	table.sort(list, function(a, b)
		if a.min ~= b.min then return a.min > b.min end
		return a.name < b.name
	end)
	return list
end

local function getRow(i)
	local r = rows[i]
	if r then
		return r
	end
	r = CreateFrame("Button", nil, content)
	r:SetSize(320, ROW_H)
	r:SetPoint("TOPLEFT", 0, -(i - 1) * ROW_H)
	r:RegisterForClicks("LeftButtonUp")
	r:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
	r.sel = r:CreateTexture(nil, "BACKGROUND")
	r.sel:SetAllPoints()
	r.sel:SetColorTexture(1, 0.82, 0, 0.18)
	r.icon = r:CreateTexture(nil, "ARTWORK")
	r.icon:SetSize(18, 18)
	r.icon:SetPoint("LEFT", 2, 0)
	r.count = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	r.count:SetPoint("RIGHT", -4, 0)
	r.text = r:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	r.text:SetPoint("LEFT", r.icon, "RIGHT", 6, 0)
	r.text:SetPoint("RIGHT", r.count, "LEFT", -4, 0)
	r.text:SetJustifyH("LEFT")
	r.text:SetWordWrap(false)
	r:SetScript("OnEnter", function(self) showRecipeTooltip(self, self.id) end)
	r:SetScript("OnLeave", GameTooltip_Hide)
	r:SetScript("OnClick", function(self)
		if IsModifiedClick("CHATLINK") and linkRecipe(self.id) then
			return
		end
		selectedRecipe = self.id
		UI.Refresh()
	end)
	rows[i] = r
	return r
end

local function refreshList()
	local list = filteredRecipes()
	for i, e in ipairs(list) do
		local r = getRow(i)
		r.id = e.id
		r.icon:SetTexture(recipeIcon(e.id))
		r.text:SetText(e.name)
		r.text:SetTextColor(qualityColor(itemOf(e.id)))
		r.count:SetText(#Index.Crafters(e.id))
		r.sel:SetShown(e.id == selectedRecipe)
		r:Show()
	end
	for i = #list + 1, #rows do
		rows[i]:Hide()
	end
	content:SetHeight(math.max(1, #list * ROW_H))
end

---------------------------------------------------------------- professions

local function refreshProfessions()
	for _, b in ipairs(profButtons) do
		local n = #Index.Recipes(b.sl)
		b.text:SetText(ns.ProfName(b.sl) .. "  |cffaaaaaa" .. n .. "|r")
		b.sel:SetShown(b.sl == selectedProf)
		if n > 0 then
			b.text:SetTextColor(1, 0.82, 0)
		else
			b.text:SetTextColor(0.55, 0.55, 0.55)
		end
	end
end

---------------------------------------------------------------- frame

local function build()
	frame = CreateFrame("Frame", "GuildProfFrame", UIParent, "BasicFrameTemplateWithInset")
	frame:SetSize(820, 500)
	frame:SetPoint("CENTER")
	frame:SetFrameStrata("HIGH")
	frame:SetMovable(true)
	frame:SetClampedToScreen(true)
	frame:EnableMouse(true)
	frame:RegisterForDrag("LeftButton")
	frame:SetScript("OnDragStart", frame.StartMoving)
	frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
	frame.TitleText:SetText(L.TITLE)
	frame:Hide()
	tinsert(UISpecialFrames, "GuildProfFrame")

	profButtons = {}
	for i, sl in ipairs(ns.CRAFTING) do
		local b = CreateFrame("Button", nil, frame)
		b:SetSize(160, 24)
		b:SetPoint("TOPLEFT", 12, -32 - (i - 1) * 26)
		b.sl = sl
		b:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
		b.sel = b:CreateTexture(nil, "BACKGROUND")
		b.sel:SetAllPoints()
		b.sel:SetColorTexture(1, 0.82, 0, 0.18)
		b.text = b:CreateFontString(nil, "OVERLAY", "GameFontNormal")
		b.text:SetPoint("LEFT", 8, 0)
		b:SetScript("OnClick", function(self)
			selectedProf, selectedRecipe = self.sl, nil
			scroll:SetVerticalScroll(0)
			UI.Refresh()
		end)
		profButtons[i] = b
	end

	search = CreateFrame("EditBox", nil, frame, "SearchBoxTemplate")
	search:SetSize(320, 20)
	search:SetPoint("TOPLEFT", 190, -32)
	search.Instructions:SetText(L.SEARCH)
	search:HookScript("OnTextChanged", function() UI.Refresh() end)

	scroll = CreateFrame("ScrollFrame", nil, frame, "UIPanelScrollFrameTemplate")
	scroll:SetPoint("TOPLEFT", 186, -58)
	scroll:SetPoint("BOTTOMLEFT", 186, 12)
	scroll:SetWidth(322)
	content = CreateFrame("Frame", nil, scroll)
	content:SetSize(320, 1)
	scroll:SetScrollChild(content)
	rows = {}

	detail = buildDetail(frame)

	frame:SetScript("OnShow", function()
		ns.RequestRoster()
		UI.Refresh()
	end)
end

function UI.Refresh()
	if not frame or not frame:IsShown() then
		return
	end
	if ns.solo or not ns.Store.IsBound() then
		frame.TitleText:SetText(L.TITLE .. " - " .. L.NO_GUILD)
	else
		frame.TitleText:SetText(L.TITLE)
	end
	if not selectedProf then
		for _, sl in ipairs(ns.CRAFTING) do
			if #Index.Recipes(sl) > 0 then
				selectedProf = sl
				break
			end
		end
		selectedProf = selectedProf or ns.CRAFTING[1]
	end
	refreshProfessions()
	refreshList()
	refreshDetail()
end

-- Item data arrives in bursts: one redraw per burst.
local planned
function UI.RefreshSoon()
	if planned or not frame or not frame:IsShown() then
		return
	end
	planned = true
	C_Timer.After(0.2, function()
		planned = false
		UI.Refresh()
	end)
end

function UI.Toggle()
	if not frame then
		build()
	end
	frame:SetShown(not frame:IsShown())
end
