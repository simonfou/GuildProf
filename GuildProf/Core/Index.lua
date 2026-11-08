local _, ns = ...

-- Pure Lua 5.1: lookup tables for the UI, rebuilt from the Store whenever
-- its digest changes.
--   Index.Crafters(recipeID)  -> sorted array of owners
--   Index.Recipes(skillLine)  -> array of recipe IDs someone in the guild knows
--   Index.Members(skillLine)  -> array of { owner, level, max, count }, best first

local Codec, Store = ns.Codec, ns.Store
local Index = {}
ns.Index = Index

local builtFor
local byRecipe, byProf, members = {}, {}, {}

local function build()
	byRecipe, byProf, members = {}, {}, {}
	local profOf = {}
	for _, owner in ipairs(Store.Owners()) do
		local profs = Codec.DecodeProfs(Store.Get(owner).data) or {}
		for sl, p in pairs(profs) do
			local ids = p.ids and Codec.DecodeIDs(p.ids) or {}
			local m = members[sl] or {}
			m[#m + 1] = { owner = owner, level = p.level or 0, max = p.max or 0, count = #ids }
			members[sl] = m
			for _, id in ipairs(ids) do
				local list = byRecipe[id]
				if not list then
					list = {}
					byRecipe[id] = list
					-- The generated data decides the profession; a recipe it
					-- does not know (newer client build) keeps the sender's.
					local data = ns.Recipes and ns.Recipes[id]
					profOf[id] = data and data[1] or sl
				end
				list[#list + 1] = owner
			end
		end
	end
	for id, sl in pairs(profOf) do
		local l = byProf[sl] or {}
		l[#l + 1] = id
		byProf[sl] = l
	end
	for _, m in pairs(members) do
		table.sort(m, function(a, b)
			if a.level ~= b.level then
				return a.level > b.level
			end
			return a.owner < b.owner
		end)
	end
	builtFor = Store.Digest()
end

local function fresh()
	if not Store.IsBound() then
		byRecipe, byProf, members, builtFor = {}, {}, {}, nil
	elseif builtFor ~= Store.Digest() then
		build()
	end
end

function Index.Crafters(id)
	fresh()
	return byRecipe[id] or {}
end

function Index.Recipes(sl)
	fresh()
	return byProf[sl] or {}
end

function Index.Members(sl)
	fresh()
	return members[sl] or {}
end
