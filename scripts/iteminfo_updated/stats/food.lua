-- Eating: what an item gives this character (mirrors components/edible.lua, eater.lua, foodaffinity.lua).

local Food = {}

local CFG = ITEMINFO_UPDATED.config

-- foodaffinity data of every character, from prefabs/<character>.lua
local AFFINITIES =
{
	walter = { prefabs = { trailmix = "AFFINITY_15_CALORIES_SMALL" } },
	wanda = { prefabs = { taffy = "AFFINITY_15_CALORIES_MED" } },
	wathgrithr = { prefabs = { turkeydinner = "AFFINITY_15_CALORIES_HUGE" } },
	waxwell = { prefabs = { lobsterdinner = "AFFINITY_15_CALORIES_LARGE" } },
	webber = { prefabs = { icecream = "AFFINITY_15_CALORIES_MED" } },
	wendy = { prefabs = { bananapop = "AFFINITY_15_CALORIES_SMALL" } },
	wes = { prefabs = { freshfruitcrepes = "AFFINITY_15_CALORIES_SUPERHUGE" } },
	wickerbottom = { prefabs = { surfnturf = "AFFINITY_15_CALORIES_LARGE" } },
	willow = { prefabs = { hotchili = "AFFINITY_15_CALORIES_LARGE" } },
	wilson = { prefabs = { baconeggs = "AFFINITY_15_CALORIES_HUGE" } },
	winona = { prefabs = { vegstinger = "AFFINITY_15_CALORIES_MED" } },
	wolfgang = { prefabs = { potato_cooked = "AFFINITY_15_CALORIES_MED" } },
	wonkey = { prefabs = { cave_banana = "AFFINITY_15_CALORIES_SMALL" } },
	woodie = { prefabs = { honeynuggets = "AFFINITY_15_CALORIES_LARGE" } },
	wormwood = { prefabs = { cave_banana_cooked = "AFFINITY_15_CALORIES_SMALL" } },
	wortox = { prefabs = { pomegranate = "AFFINITY_15_CALORIES_TINY", pomegranate_cooked = "AFFINITY_15_CALORIES_SMALL" } },
	wx78 = { prefabs = { butterflymuffin = "AFFINITY_15_CALORIES_LARGE" } },
	wurt =
	{
		foodtypes = { VEGGIE = 1.33 },
		prefabs =
		{
			kelp = 1.33, kelp_cooked = 1.33, boatpatch_kelp = 1.33,
			durian = 1.93, durian_cooked = 1.93,
		},
	},
}

local function ResolveAffinity(value)
	return type(value) == "string" and TUNING[value] or value
end

local spicedfoods = nil
local function GetFoodBasePrefab(prefab)
	if spicedfoods == nil then
		local ok, data = pcall(require, "spicedfoods")
		spicedfoods = ok and type(data) == "table" and data or false
	end
	return spicedfoods and spicedfoods[prefab] ~= nil and spicedfoods[prefab].basename or prefab
end

-- Returns the biggest hunger multiplier and whether it comes from a prefab affinity
local function GetAffinity(owner, item, edible)
	local affinity = AFFINITIES[owner.prefab]
	if affinity == nil then
		return nil, false
	end

	local best = nil
	local from_prefab = false
	local base = GetFoodBasePrefab(item.prefab)
	for _, prefab in ipairs({ item.prefab, base }) do
		local value = affinity.prefabs ~= nil and ResolveAffinity(affinity.prefabs[prefab]) or nil
		if value ~= nil then
			from_prefab = true
			best = math.max(best or value, value)
		end
	end
	local value = affinity.foodtypes ~= nil and edible.foodtype ~= nil and ResolveAffinity(affinity.foodtypes[edible.foodtype]) or nil
	if value ~= nil then
		best = math.max(best or value, value)
	end
	return best, from_prefab
end

-- eater:SetDiet() preferences and eater:SetPrefersEatingTag(), which aren't networked
local PREFERS_FOODTYPES =
{
	wathgrithr = { FOODTYPE.MEAT, FOODTYPE.GOODIES },
	wurt = FOODGROUP.VEGETARIAN ~= nil and FOODGROUP.VEGETARIAN.types or nil, -- guarded: evaluated when the mod loads
}
local PREFERS_TAGS =
{
	warly = { "preparedfood", "pre-preparedfood" },
}

local function ItemHasFoodtype(item, foodtypes)
	for _, foodtype in ipairs(foodtypes) do
		if type(foodtype) == "string" and item:HasTag("edible_"..foodtype) then
			return true
		end
	end
	return false
end

-- eater:CanEat() via the "<diet>_eater" tags the eater component adds to the player
local function CanEat(owner, item)
	-- Mods can add food groups / types: skip anything that isn't shaped like the game's own
	for _, group in pairs(FOODGROUP) do
		if type(group) == "table" and type(group.name) == "string" and type(group.types) == "table"
			and owner:HasTag(group.name.."_eater") and ItemHasFoodtype(item, group.types) then
			return true
		end
	end
	for _, foodtype in pairs(FOODTYPE) do
		if type(foodtype) == "string" and owner:HasTag(foodtype.."_eater") and item:HasTag("edible_"..foodtype) then
			return true
		end
	end
	return false
end

local function PrefersToEat(owner, item)
	if item.prefab == "winter_food4" then -- fruitcake, refused by every player
		return false
	elseif owner:HasTag("nospoiledfood") and item:HasTag("spoiled") then
		return false
	end
	local tags = PREFERS_TAGS[owner.prefab]
	if tags ~= nil and not item:HasAnyTag(tags) then
		return false
	end
	local foodtypes = PREFERS_FOODTYPES[owner.prefab]
	if foodtypes ~= nil and not ItemHasFoodtype(item, foodtypes) then
		return false
	end
	return true
end

-- Eater fields set by character prefabs: stale/spoiled multipliers and absorption
local EATER_STALE =
{
	wickerbottom = { hunger = "WICKERBOTTOM_STALE_FOOD_HUNGER", health = "WICKERBOTTOM_STALE_FOOD_HEALTH" },
}
local ABSORPTION =
{
	wortox = { health = "WORTOX_FOOD_MULT", hunger = "WORTOX_FOOD_MULT", sanity = "WORTOX_FOOD_MULT" },
	wormwood = { health = 0, hunger = 1, sanity = 1 },
}

local function GetAbsorption(owner, stat)
	local absorption = ABSORPTION[owner.prefab]
	local value = absorption ~= nil and absorption[stat] or 1
	return type(value) == "string" and (TUNING[value] or 1) or value
end

local function GetSpiceMult(spice, stat)
	local data = spice ~= nil and TUNING.SPICE_MULTIPLIERS ~= nil and TUNING.SPICE_MULTIPLIERS[spice] or nil
	return data ~= nil and data[stat] or nil
end

-- Hosts: the player and the item have their real components, so ask the game itself
-- (components/eater.lua Eat). Exact for every character, skill, food memory (Warly) and future change.
function Food.GetLiveFood(item, owner)
	local eater = owner.components ~= nil and owner.components.eater or nil
	local edible = item.components ~= nil and item.components.edible or nil
	if eater == nil or edible == nil then
		return nil
	end

	local ok, result = pcall(function()
		local function Absorption(value)
			return type(value) == "number" and value or 1
		end
		local foodmemory = owner.components.foodmemory
		local base_mult = foodmemory ~= nil and foodmemory:GetFoodMultiplier(item.prefab) or 1
		local health, hunger, sanity = 0, 0, 0
		if owner.components.health ~= nil and (edible.healthvalue >= 0 or eater:DoFoodEffects(item)) then
			health = edible:GetHealth(owner) * base_mult * Absorption(eater.healthabsorption)
		end
		if owner.components.hunger ~= nil then
			hunger = edible:GetHunger(owner) * base_mult * Absorption(eater.hungerabsorption)
		end
		if owner.components.sanity ~= nil and (edible.sanityvalue >= 0 or eater:DoFoodEffects(item)) then
			sanity = edible:GetSanity(owner) * base_mult * Absorption(eater.sanityabsorption)
		end
		if eater.custom_stats_mod_fn ~= nil then
			health, hunger, sanity = eater.custom_stats_mod_fn(owner, health, hunger, sanity, item, owner)
		end
		local affinity = owner.components.foodaffinity ~= nil and owner.components.foodaffinity:GetAffinity(item) or nil
		return
		{
			can_eat = eater:CanEat(item) == true,
			refused = not eater:PrefersToEat(item),
			hunger = hunger or 0,
			sanity = sanity or 0,
			health = health or 0,
			favorite = affinity ~= nil and affinity > 1,
		}
	end)
	return ok and result or nil
end

function Food.GetFoodValues(item, edible, owner)
	local stale = item:HasTag("stale")
	local spoiled = item:HasTag("spoiled")
	local eater_stale = EATER_STALE[owner.prefab]
	local ignores_spoilage = owner:HasTag("ignoresspoilage")
	local processes_spoiled = owner:HasTag("spoiledprocessor") and
		(item:HasTag("spoiledfood") or (owner:HasTag("allspoiledprocessor") and spoiled))

	-- Hunger
	local hunger = edible.hunger
	local hunger_mult = 1
	if processes_spoiled then
		hunger = math.max(0, hunger)
	elseif edible.degrades and hunger >= 0 and not ignores_spoilage then
		if stale then
			hunger_mult = eater_stale ~= nil and TUNING[eater_stale.hunger] or edible.stale_hunger or TUNING.STALE_FOOD_HUNGER
		elseif spoiled then
			hunger_mult = edible.spoiled_hunger or TUNING.SPOILED_FOOD_HUNGER
		end
	end
	local affinity, prefab_affinity = GetAffinity(owner, item, edible)
	if affinity ~= nil then
		hunger_mult = hunger_mult * affinity
	end
	hunger = hunger * hunger_mult

	-- Sanity
	local sanity = edible.sanity
	if processes_spoiled then
		sanity = math.max(0, sanity)
	elseif edible.degrades and sanity >= 0 and not ignores_spoilage and (stale or spoiled) then
		sanity = spoiled and -TUNING.SANITY_SMALL or 0
	else
		sanity = sanity * (1 + (GetSpiceMult(edible.spice, "SANITY") or 0))
	end

	-- Health
	local health = edible.health
	local health_mult = 1
	local health_spice = edible.spice
	if processes_spoiled then
		health = math.max(0, health)
	elseif edible.degrades and health >= 0 and not ignores_spoilage then
		if stale then
			health_mult = eater_stale ~= nil and TUNING[eater_stale.health] or edible.stale_health or TUNING.STALE_FOOD_HEALTH
		elseif spoiled then
			health_mult = edible.spoiled_health or TUNING.SPOILED_FOOD_HEALTH
			health_spice = nil
		end
	end
	health_mult = health_mult + (GetSpiceMult(health_spice, "HEALTH") or 0)
	health = health * health_mult

	-- eater:DoFoodEffects(): negative health/sanity are skipped for strong stomachs, raw meat eaters
	-- and favorite foods
	local food_effects = not ((owner:HasTag("strongstomach") and item:HasTag("monstermeat")) or
		(owner:HasTag("eatsrawmeat") and item:HasTag("rawmeat")) or
		prefab_affinity)
	if edible.health < 0 and not food_effects then
		health = 0
	end
	if edible.sanity < 0 and not food_effects then
		sanity = 0
	end

	return hunger * GetAbsorption(owner, "hunger"),
		sanity * GetAbsorption(owner, "sanity"),
		health * GetAbsorption(owner, "health"),
		affinity ~= nil and affinity > 1
end

-- What eating the item does for this character, or nil when it's not shown.
-- Returns { hunger, sanity, health, favorite, refused }
function Food.Compute(item, data, owner)
	-- Wortox souls aren't food, they're eaten by the souleater component (prefabs/wortox.lua OnEatSoul)
	if item:HasTag("soul") and owner:HasTag("souleater") then
		local sanity = -TUNING.SANITY_TINY
		if owner.wortox_inclination == "nice" then
			sanity = -TUNING.SANITY_TINY * 2
		elseif owner.wortox_inclination == "naughty" then
			sanity = 0
		end
		return { hunger = TUNING.CALORIES_MED, sanity = sanity, health = 0, favorite = false, refused = false }
	end

	local edible = data.edible
	local live = Food.GetLiveFood(item, owner)
	local can_eat, refused
	if live ~= nil then
		can_eat, refused = live.can_eat, live.refused
	else
		can_eat = edible ~= nil and CanEat(owner, item)
		refused = can_eat and not PrefersToEat(owner, item)
	end
	if not can_eat or (refused and not CFG.show_refused_food) then
		return nil
	end

	local food = { refused = refused }
	if live ~= nil then
		food.hunger, food.sanity, food.health, food.favorite = live.hunger, live.sanity, live.health, live.favorite
	else
		food.hunger, food.sanity, food.health, food.favorite = Food.GetFoodValues(item, edible, owner)
	end
	return food
end

return Food
