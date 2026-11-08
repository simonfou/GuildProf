local _, ns = ...

-- Reads the player's own professions: levels and known recipes from the
-- spellbook API at any time, and the recipe list again whenever the
-- player's own profession window is open (not a linked, guild or NPC
-- crafting view).
--
-- Every pass writes one line of what it saw to GuildProfDB.diag (shown by
-- /gp status, and readable on disk after a /reload).

local Codec = ns.Codec
local Scan = {}
ns.Scan = Scan

local function diag(key, text)
	ns.db.diag = ns.db.diag or {}
	ns.db.diag[key] = date("%H:%M:%S ") .. text
	ns.Debug(key, text)
end

local function ownProfs()
	local r = ns.me and ns.Store.Get(ns.me)
	return r and Codec.DecodeProfs(r.data) or {}
end

-- Recipe IDs of one profession, from the generated table.
local byProf
local function recipesOf(sl)
	if not byProf then
		byProf = {}
		for id, d in pairs(ns.Recipes) do
			local l = byProf[d[1]] or {}
			l[#l + 1] = id
			byProf[d[1]] = l
		end
	end
	return byProf[sl] or {}
end

-- Ways to ask whether a recipe spell is known without its window, in order
-- of preference. Each is checked before its answer is used.
local METHODS = { "IsSpellKnown", "IsSpellKnownOrInSpellBook" }

-- A method that calls known nearly every recipe of a large profession
-- answers true for any spell.
local CLAIMS_ALL = 0.9
local LARGE = 20

-- Known recipes of one profession, read from the spellbook API against
-- the generated recipe table. A method is rejected when it errors, finds
-- nothing, or claims nearly the whole profession. The data's minimum skill
-- is not a test: some Blacksmithing minimums sit above the skill at which
-- the recipe turns grey, so known recipes can exceed it.
-- Returns ids and the method name, or nil and the reasons.
local function spellbookRecipes(sl)
	if not C_SpellBook then
		return nil, "no C_SpellBook"
	end
	local reasons = {}
	for _, name in ipairs(METHODS) do
		local fn = C_SpellBook[name]
		if fn then
			local ids, total = {}, #recipesOf(sl)
			local ok = pcall(function()
				for _, id in ipairs(recipesOf(sl)) do
					if fn(id) then
						ids[#ids + 1] = id
					end
				end
			end)
			if not ok then
				reasons[#reasons + 1] = name .. " error"
			elseif total > LARGE and #ids >= total * CLAIMS_ALL then
				reasons[#reasons + 1] = name .. " claims " .. #ids .. " of " .. total
			elseif #ids == 0 then
				reasons[#reasons + 1] = name .. " none"
			else
				return ids, name
			end
		end
	end
	return nil, table.concat(reasons, ", ")
end

-- Merges the spellbook's answer into a profession entry and describes the
-- comparison with the last window scan.
local function addSpellbookRecipes(p, sl)
	local sb, how = spellbookRecipes(sl)
	if not sb then
		return "spellbook: " .. how
	end
	local window = p.ids and Codec.DecodeIDs(p.ids) or {}
	local set, both = {}, 0
	for _, id in ipairs(sb) do
		set[id] = true
	end
	local merged = {}
	for _, id in ipairs(sb) do
		merged[#merged + 1] = id
	end
	for _, id in ipairs(window) do
		if set[id] then
			both = both + 1
		else
			merged[#merged + 1] = id
		end
	end
	p.ids = Codec.EncodeIDs(merged)
	return ("%s %d, window %d, both %d"):format(how, #sb, #window, both)
end

function Scan.Basic()
	if not GetProfessions then
		return diag("basic", "no GetProfessions")
	end
	if not ns.Store.IsBound() or not ns.me then
		return diag("basic", "not bound, me=" .. tostring(ns.me))
	end
	local profs = ownProfs()
	local seen, count, notes = {}, 0, {}
	local t = { GetProfessions() }
	for i = 1, 7 do
		local index = t[i]
		if index then
			local name, _, rank, maxRank, _, _, skillLine = GetProfessionInfo(index)
			local note = tostring(name) .. "=" .. tostring(skillLine) .. ":" .. tostring(rank)
			if skillLine and ns.IsTracked(skillLine) then
				seen[skillLine] = true
				count = count + 1
				local p = profs[skillLine] or {}
				p.level, p.max = rank or 0, maxRank or 0
				if #recipesOf(skillLine) > 0 then
					note = note .. " [" .. addSpellbookRecipes(p, skillLine) .. "]"
				end
				profs[skillLine] = p
			end
			notes[#notes + 1] = note
		end
	end
	-- Forget unlearned professions, but never on an empty answer: the
	-- spellbook can be empty for a moment at login.
	if count > 0 then
		for sl in pairs(profs) do
			if not seen[sl] then
				profs[sl] = nil
			end
		end
	end
	diag("basic", count .. " tracked: " .. table.concat(notes, " "))
	ns.Sync.SetOwn(profs)
end

-- The first tracked one of the window's skill lines: Forever hangs recipes
-- on the base line (171) and has a child tier line (2937) above it.
local function windowSkillLine(T)
	local base = T.GetBaseProfessionInfo()
	local child = T.GetChildProfessionInfo()
	local ids = {
		base and base.professionID, child and child.parentProfessionID, child and child.professionID,
	}
	local seenIds = {}
	for i = 1, 3 do
		seenIds[i] = tostring(ids[i])
	end
	local info = (child and child.maxSkillLevel and child.maxSkillLevel > 0) and child or base
	for i = 1, 3 do
		if ids[i] and ns.IsTracked(ids[i]) then
			return ids[i], info, table.concat(seenIds, "/")
		end
	end
	return nil, info, table.concat(seenIds, "/")
end

-- Returns true when it is worth trying again shortly.
function Scan.Window()
	local T = C_TradeSkillUI
	if not T then
		diag("window", "no C_TradeSkillUI")
		return false
	end
	if not ns.Store.IsBound() or not ns.me then
		diag("window", "not bound, me=" .. tostring(ns.me))
		return false
	end
	if not T.IsTradeSkillReady() or T.IsDataSourceChanging() then
		diag("window", "not ready")
		return true
	end
	if (T.IsTradeSkillLinked and T.IsTradeSkillLinked()) or (T.IsTradeSkillGuild and T.IsTradeSkillGuild())
		or (T.IsNPCCrafting and T.IsNPCCrafting()) then
		diag("window", "linked, guild or NPC view: skipped")
		return false
	end
	local sl, info, idsText = windowSkillLine(T)
	if not sl then
		diag("window", "skill lines " .. idsText .. " not tracked")
		return false
	end
	local all = T.GetAllRecipeIDs and T.GetAllRecipeIDs()
	local source = "all"
	if not all or #all == 0 then
		all, source = T.GetFilteredRecipeIDs() or {}, "filtered"
	end
	local ids = {}
	for _, id in ipairs(all) do
		local r = T.GetRecipeInfo(id)
		if r and r.learned then
			ids[#ids + 1] = id
		end
	end
	if #ids == 0 then
		-- List not loaded yet: never replace a list with nothing.
		diag("window", ("skill %s (%s): 0 learned of %d %s"):format(sl, idsText, #all, source))
		return true
	end
	local profs = ownProfs()
	profs[sl] = {
		level = info and info.skillLevel or 0,
		max = info and info.maxSkillLevel or 0,
		ids = Codec.EncodeIDs(ids),
	}
	diag("window", ("skill %s (%s): %d learned of %d %s"):format(sl, idsText, #ids, #all, source))
	ns.Sync.SetOwn(profs)
	return false
end

-- A Lua error lands in GuildProfDB.diag.error too, so it can be read on
-- disk after a /reload even with script errors hidden.
local function onError(err)
	diag("error", tostring(err))
	return err
end

local planned
function Scan.Schedule(event)
	if event then
		diag("event", event)
	end
	if planned then
		return
	end
	planned = true
	local tries = 0
	local function attempt()
		tries = tries + 1
		local ok, retry = xpcall(Scan.Window, onError)
		if ok and retry and tries < 6 then
			C_Timer.After(1, attempt)
		else
			planned = false
		end
	end
	C_Timer.After(0.5, attempt)
end
