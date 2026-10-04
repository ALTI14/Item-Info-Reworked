-- Turns an item into rows of {icon, text} cells.
-- All formulas mirror the game code (components/perishable, edible, eater, foodaffinity,
-- combat, fueled, finiteuses, armor) using only data a client can actually see.

local Cache = require "iteminfo_updated/cache"
local Sets = require "iteminfo_updated/sets"

local Stats = {}

local IIU = ITEMINFO_UPDATED
local CFG = IIU.config

--------------------------------------------------------------------------
-- Icons

local MOD_ATLAS = "images/iteminfo_images.xml"
local PLANAR_ATLAS = "images/iteminfo_planar.xml"
local SCRAPBOOK_ATLAS = "images/scrapbook_icons1.xml"

local ICONS =
{
	hunger = { MOD_ATLAS, "hunger.tex" },
	sanity = { MOD_ATLAS, "sanity.tex" },
	health = { MOD_ATLAS, "health.tex" },
	freshness = { MOD_ATLAS, "freshness.tex" },
	stale = { MOD_ATLAS, "stale.tex" },
	spoiled = { MOD_ATLAS, "spoiled.tex" },
	armor = { MOD_ATLAS, "armor.tex" },
	weapon = { MOD_ATLAS, "weapon.tex" },
	uses = { MOD_ATLAS, "uses.tex" },
	waterproof = { MOD_ATLAS, "waterproof.tex" },
	insulation_winter = { MOD_ATLAS, "insulation_winter.tex" },
	insulation_summer = { MOD_ATLAS, "insulation_summer.tex" },
	fuel_light = { MOD_ATLAS, "fuel_light.tex" },
	fuel_wearable = { MOD_ATLAS, "fuel_wearable.tex" },
	label = { MOD_ATLAS, "label.tex" },
	planar = { PLANAR_ATLAS, "planar.tex" },
	lunar = { PLANAR_ATLAS, "lunar.tex" },
	shadow = { PLANAR_ATLAS, "shadow.tex" },
	heat = { SCRAPBOOK_ATLAS, "icon_heat.tex" },
	cold = { SCRAPBOOK_ATLAS, "icon_cold.tex" },
	vs_lunar = { SCRAPBOOK_ATLAS, "icon_moonaligned.tex" },
	vs_shadow = { SCRAPBOOK_ATLAS, "icon_shadowaligned.tex" },
	favorite = { "images/global_redux.xml", "star_checked.tex" },
}

local speed_icon = nil
local function GetSpeedIcon()
	if speed_icon == nil then
		local atlas = GetInventoryItemAtlas("cane.tex", true)
		speed_icon = atlas ~= nil and { atlas, "cane.tex" } or ICONS.uses
	end
	return speed_icon
end

-- The few words the tooltip shows, in the game's language (fonts have CJK fallbacks)
local TEXT = CFG.chinese and
{
	days = "天",
	seconds = "秒",
	per_minute = "/分",
	heatrock = { "冰冻", "冰凉", "", "温暖", "炽热" },
} or
{
	days = "d",
	seconds = "s",
	per_minute = "/min",
	heatrock = { "Frozen", "Cold", "", "Warm", "Hot" },
}

local COLOUR_NEGATIVE = { 1, .6, .6, 1 }
local COLOUR_FAVORITE = { 1, .82, .35, 1 }
local COLOUR_DISABLED = { .6, .6, .6, 1 }
local COLOUR_LOW = { 1, .45, .4, 1 }
local COLOUR_BONUS = { .55, 1, .55, 1 } -- set bonuses and skills

-- Durability at or below 20% is tinted red
local function DurabilityColour(percent)
	return percent <= .2 and COLOUR_LOW or nil
end

--------------------------------------------------------------------------
-- Formatting

local function FormatNumber(value)
	local str = string.format("%.1f", value)
	str = str:gsub("%.0$", "")
	return str == "-0" and "0" or str
end

local function FormatSigned(value)
	local str = FormatNumber(value)
	return value > 0 and ("+"..str) or str
end

local function FormatPercent(value)
	return string.format("%d%%", math.floor(value * 100 + .5))
end

local function FormatTime(t)
	if t == nil or t ~= t then
		return "?"
	elseif t == math.huge then
		return "-"
	end
	t = math.max(0, t)
	if CFG.time_format == 1 then
		return FormatNumber(t / TUNING.TOTAL_DAY_TIME)..TEXT.days
	end
	t = math.floor(t + .5)
	local hours = math.floor(t / 3600)
	local mins = math.floor((t % 3600) / 60)
	local secs = t % 60
	if hours > 0 then
		return string.format("%d:%02d:%02d", hours, mins, secs)
	end
	return string.format("%d:%02d", mins, secs)
end

local function Cell(icon, text, colour)
	return { atlas = icon[1], tex = icon[2], text = text, colour = colour }
end

--------------------------------------------------------------------------
-- Networked item state

local function GetClassified(item)
	return item.replica.inventoryitem ~= nil and item.replica.inventoryitem.classified or nil
end

-- percentused: 0-100, 255 = not used by this item
local function GetPercentUsed(item)
	local classified = GetClassified(item)
	local value = classified ~= nil and classified.percentused ~= nil and classified.percentused:value() or 255
	return value ~= 255 and value / 100 or nil
end

-- perish: 0-62, 63 = not perishable. The server sends floor(percent * 62 + .5), so a step
-- change happens exactly when the real percent crosses (v +/- .5) / 62. When we see one we
-- anchor to that boundary and count down from it; otherwise we use the step centre.
-- The estimate is always clamped to the range the networked step allows.
local perish_tracking = setmetatable({}, { __mode = "k" })

local function GetPerishPercent(item, rate)
	local classified = GetClassified(item)
	local value = classified ~= nil and classified.perish ~= nil and classified.perish:value() or 63
	if value == 63 then
		return nil
	end

	local now = GetTime()
	local track = perish_tracking[item]
	if track == nil or track.value ~= value then
		local anchor = nil
		if track ~= nil and now - track.seen < 1 then
			if value == track.value - 1 then
				anchor = (value + .5) / 62
			elseif value == track.value + 1 then
				anchor = (value - .5) / 62
			end
		end
		track = { value = value, anchor = anchor, anchor_time = now }
		perish_tracking[item] = track
	end
	track.seen = now

	local percent = value / 62
	if track.anchor ~= nil and rate ~= nil then
		percent = track.anchor - (now - track.anchor_time) * rate
	end
	return math.clamp(percent, math.max(0, (value - .5) / 62), math.min(1, (value + .5) / 62))
end

--------------------------------------------------------------------------
-- Spoilage (mirrors components/perishable.lua Update)

local function FindInContainer(holder, tag)
	local container = holder.replica.container
	if container ~= nil and container.FindItem ~= nil then
		local ok, found = pcall(container.FindItem, container, function(v) return v:HasTag(tag) end)
		return ok and found ~= nil
	end
	return false
end

local function LightPreserverRate(holder)
	return FindInContainer(holder, "fulllighter") and 0 or TUNING.PERISH_MUSHROOM_LIGHT_MULT
end

-- Containers / owners with a server side "preserver" component, by prefab.
-- Return nil when the preserver doesn't affect this item (the game then falls back to 1).
local PRESERVERS =
{
	beargerfur_sack = function() return TUNING.BEARGERFUR_SACK_PRESERVER_RATE end,
	fish_box = function() return TUNING.FISH_BOX_PRESERVER_RATE end,
	saltbox = function() return TUNING.PERISH_SALTBOX_MULT end,
	seedpouch = function() return TUNING.SEEDPOUCH_PRESERVER_RATE end,
	alterguardianhat = function() return 0 end,
	alterguardianhatshard = function() return 0 end,
	pirate_stash = function() return 0 end,
	mushroom_light = LightPreserverRate,
	mushroom_light2 = LightPreserverRate,
	wurt = function(holder, item) return item:HasTag("fish") and TUNING.WURT_FISH_PRESERVER_RATE or nil end,
	-- These depend on server only state (sisturn skill, trawler lowered, WX modules): rate 1 unless active.
	sisturn = function() return nil end,
	ocean_trawler = function() return nil end,
	wx78 = function() return nil end,
	wx78_inventorycontainer = function() return nil end,
}

local function GetPreserverFn(holder)
	local fn = PRESERVERS[holder.prefab]
	if fn == nil and holder.prefab ~= nil and holder.prefab:find("lantern_post", 1, true) then
		fn = LightPreserverRate
	end
	return fn
end

local function GetAmbientTemperature(holder)
	-- Defined by components/temperatureoverrider.lua, which a client may never load (rawget: strict mode)
	local GetTemperatureAtXZ = rawget(_G, "GetTemperatureAtXZ")
	if holder ~= nil and not holder:HasTag("pocketdimension_container") and GetTemperatureAtXZ ~= nil and holder.Transform ~= nil then
		local x, y, z = holder.Transform:GetWorldPosition()
		local ok, temp = pcall(GetTemperatureAtXZ, x, z)
		if ok and type(temp) == "number" then
			return temp
		end
	end
	return TheWorld.state.temperature
end

function Stats.GetPerishModifier(item, holder)
	local modifier = 1

	if holder ~= nil then
		local live_preserver = holder.components ~= nil and holder.components.preserver or nil
		local preserver = GetPreserverFn(holder)
		if live_preserver ~= nil then
			-- Hosts: the real component, exact for every container including new / modded ones
			local ok, rate = pcall(live_preserver.GetPerishRateMultiplier, live_preserver, item)
			modifier = ok and type(rate) == "number" and rate or modifier
		elseif preserver ~= nil then
			modifier = preserver(holder, item) or modifier
		elseif holder:HasTag("fridge") then
			if item:HasTag("frozen") and not holder:HasTag("nocool") and not holder:HasTag("lowcool") then
				modifier = TUNING.PERISH_COLD_FROZEN_MULT
			else
				modifier = TUNING.PERISH_FRIDGE_MULT
			end
		elseif holder:HasTag("foodpreserver") then
			modifier = TUNING.PERISH_FOOD_PRESERVER_MULT
		elseif holder:HasTag("cage") and item:HasTag("small_livestock") then
			modifier = TUNING.PERISH_CAGE_MULT
		end

		if holder:HasTag("spoiler") then
			modifier = modifier * TUNING.PERISH_GROUND_MULT
		end
	else
		modifier = TUNING.PERISH_GROUND_MULT
	end

	if item.replica.inventoryitem ~= nil and item.replica.inventoryitem:IsWet() then
		modifier = modifier * TUNING.PERISH_WET_MULT
	end

	local temperature = GetAmbientTemperature(holder)
	if temperature < 0 then
		if item:HasTag("frozen") then
			modifier = TUNING.PERISH_COLD_FROZEN_MULT
		else
			modifier = modifier * TUNING.PERISH_WINTER_MULT
		end
	end
	if temperature > TUNING.OVERHEAT_TEMP then
		modifier = modifier * TUNING.PERISH_SUMMER_MULT
	end

	return modifier * TUNING.PERISH_GLOBAL_MULT
end

--------------------------------------------------------------------------
-- Eating (mirrors components/edible.lua, eater.lua, foodaffinity.lua)

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
function Stats.GetLiveFood(item, owner)
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

function Stats.GetFoodValues(item, edible, owner)
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

--------------------------------------------------------------------------
-- Damage (mirrors components/combat.lua CalcDamage; character multipliers never apply to planar)

local MIGHTINESS_DAMAGE = { wimpy = .75, normal = 1, mighty = 2 } -- components/mightiness.lua STATE_DATA

local function GetWandaAgeState(owner)
	if owner.age_state ~= nil then
		return owner.age_state
	end
	local health = owner.replica.health ~= nil and owner.replica.health:GetPercent() or 1
	return (health <= TUNING.WANDA_AGE_THRESHOLD_OLD and "old")
		or (health >= TUNING.WANDA_AGE_THRESHOLD_YOUNG and "young")
		or "normal"
end

--------------------------------------------------------------------------
-- Skill tree (components/skilltreeupdater.lua exists on clients and knows the local player's skills)

local function IsSkillActivated(owner, skill)
	local updater = owner.components ~= nil and owner.components.skilltreeupdater or nil
	if updater == nil then
		return false
	end
	local ok, activated = pcall(updater.IsActivated, updater, skill)
	return ok and activated == true
end

local function GetMightiness(owner)
	local classified = owner.player_classified
	return classified ~= nil and classified.currentmightiness ~= nil and classified.currentmightiness:value() or nil
end

-- prefabs/skilltree_*.lua allegiance skills: the player deals more damage to the opposite alignment.
-- Every character uses 1.1, Wolfgang's three tiers go up to 1.3.
function Stats.GetAllegianceBonus(owner)
	-- Hosts: read the player's real bonuses (any character, any future skill)
	local damagetypebonus = owner.components ~= nil and owner.components.damagetypebonus or nil
	if damagetypebonus ~= nil and type(damagetypebonus.tags) == "table" then
		local live = nil
		for tag, list in pairs(damagetypebonus.tags) do
			local ok, mult = pcall(list.Get, list)
			if ok and type(mult) == "number" and mult ~= 1 then
				live = live or {}
				live[tag] = mult
			end
		end
		return live
	end

	local bonuses = nil
	local function Add(vs_tag, side)
		local vs = vs_tag == "lunar_aligned" and "LUNAR" or "SHADOW"
		local mult = (TUNING.SKILLS or {})["WILSON_ALLEGIANCE_VS_"..vs.."_BONUS"] or 1.1
		if owner.prefab == "wolfgang" then
			mult = (TUNING.SKILLS or {})["WOLFGANG_ALLEGIANCE_VS_"..vs.."_BONUS_1"] or mult
			for tier = 2, 3 do
				if IsSkillActivated(owner, "wolfgang_allegiance_"..side.."_"..tier) then
					mult = mult * ((TUNING.SKILLS or {})["WOLFGANG_ALLEGIANCE_VS_"..vs.."_BONUS_"..tier] or 1)
				end
			end
		end
		bonuses = bonuses or {}
		bonuses[vs_tag] = mult
	end
	if owner:HasTag("player_shadow_aligned") then
		Add("lunar_aligned", "shadow")
	end
	if owner:HasTag("player_lunar_aligned") then
		Add("shadow_aligned", "lunar")
	end
	return bonuses
end

-- prefabs/wolfgang.lua RecalculatePlanarDamage: +5 planar per skill while mighty
function Stats.GetWolfgangPlanarBonus(owner, item)
	if owner.prefab ~= "wolfgang" or item:HasTag("magicweapon") then
		return 0
	end
	local mightiness = GetMightiness(owner)
	if mightiness == nil or mightiness < TUNING.MIGHTY_THRESHOLD then
		return 0
	end
	local bonus = 0
	for i = 1, 5 do
		if IsSkillActivated(owner, "wolfgang_planardamage_"..i) then
			bonus = bonus + ((TUNING.SKILLS or {})["WOLFGANG_PLANARDAMAGE_"..i] or 0)
		end
	end
	return bonus
end

-- prefabs/hats.lua wathgrithr_refreshattunedskills: Wigfrid's improved helm gains planar defense
function Stats.GetSkillPlanarDefense(owner, item)
	if owner.prefab == "wathgrithr" and item.prefab == "wathgrithr_improvedhat" and IsSkillActivated(owner, "wathgrithr_arsenal_helmet_4") then
		local wathgrithr = TUNING.SKILLS ~= nil and TUNING.SKILLS.WATHGRITHR or nil
		return wathgrithr ~= nil and wathgrithr.HELM_PLANAR_DEF or 0
	end
	return 0
end

function Stats.GetDamageMultiplier(owner, item)
	-- Hosts: the real combat multipliers, including buffs (mighty, coaching, battle songs...)
	local combat = owner.components ~= nil and owner.components.combat or nil
	if combat ~= nil then
		local ok, mult = pcall(function()
			local m = (combat.damagemultiplier or 1) * combat.externaldamagemultipliers:Get()
			if combat.customdamagemultfn ~= nil then
				m = m * (combat.customdamagemultfn(owner, nil, item, nil, nil) or 1)
			end
			return m
		end)
		if ok and type(mult) == "number" then
			return mult
		end
	end

	local prefab = owner.prefab
	if prefab == "wendy" then
		return TUNING.WENDY_DAMAGE_MULT
	elseif prefab == "wathgrithr" then
		return TUNING.WATHGRITHR_DAMAGE_MULT
	elseif prefab == "wes" then
		return TUNING.WES_DAMAGE_MULT
	elseif prefab == "wolfgang" then
		local classified = owner.player_classified
		local value = classified ~= nil and classified.currentmightiness ~= nil and classified.currentmightiness:value() or nil
		if value == nil then
			return 1
		elseif value >= TUNING.MIGHTY_THRESHOLD then
			return MIGHTINESS_DAMAGE.mighty
		elseif value >= TUNING.WIMPY_THRESHOLD then
			return MIGHTINESS_DAMAGE.normal
		end
		return MIGHTINESS_DAMAGE.wimpy
	elseif prefab == "wanda" then
		local age = GetWandaAgeState(owner)
		if item:HasTag("shadow_item") then
			return (age == "old" and TUNING.WANDA_SHADOW_DAMAGE_OLD)
				or (age == "normal" and TUNING.WANDA_SHADOW_DAMAGE_NORMAL)
				or TUNING.WANDA_SHADOW_DAMAGE_YOUNG
		end
		return (age == "old" and TUNING.WANDA_REGULAR_DAMAGE_OLD)
			or (age == "normal" and TUNING.WANDA_REGULAR_DAMAGE_NORMAL)
			or TUNING.WANDA_REGULAR_DAMAGE_YOUNG
	end
	return 1
end

-- prefabs/wortox_nabbag.lua UpdateStats: damage grows with how full the main inventory is (3 steps),
-- and with the wortox_souljar_3 skill, with the souls carried (stacks, soul jars, cursor item).
-- Returns damage and whether the soul bonus is part of it.
local function GetNabbagDamage(owner)
	local wortox = TUNING.SKILLS ~= nil and TUNING.SKILLS.WORTOX or nil
	local inventory = owner.replica.inventory
	if wortox == nil or wortox.NABBAG_DAMAGE_MIN == nil or wortox.NABBAG_DAMAGE_MAX == nil or inventory == nil then
		return nil
	end

	local count, souls = 0, 0
	local function CountSouls(other)
		if other.prefab == "wortox_soul" then
			local stackable = other.replica.stackable
			souls = souls + (stackable ~= nil and stackable:StackSize() or 1)
		elseif other.prefab == "wortox_souljar" then
			-- One slot holding one soul stack: the jar's durability is souls / stack size, networked to 1%,
			-- which is precise enough to get the exact count back
			local percent = GetPercentUsed(other)
			if percent ~= nil then
				souls = souls + math.floor(percent * (TUNING.STACK_SIZE_SMALLITEM or 40) + .5)
			end
		end
	end
	for _, other in pairs(inventory:GetItems() or {}) do
		count = count + 1
		CountSouls(other)
	end
	local active = inventory:GetActiveItem()
	if active ~= nil then
		CountSouls(active)
	end

	local maxslots = inventory:GetNumSlots() or 0
	local bucket = math.clamp(math.ceil((maxslots == 0 and 0 or count / maxslots) * 3), 1, 3)
	local damage = (wortox.NABBAG_DAMAGE_MAX - wortox.NABBAG_DAMAGE_MIN) * (bucket - 1) / 2 + wortox.NABBAG_DAMAGE_MIN

	local soul_bonus = false
	if wortox.SOUL_DAMAGE_MAX_SOULS ~= nil and wortox.SOUL_DAMAGE_NABBAG_BONUS_MULT ~= nil and IsSkillActivated(owner, "wortox_souljar_3") then
		local souls_clamped = math.min(souls, wortox.SOUL_DAMAGE_MAX_SOULS)
		damage = damage * (1 + (wortox.SOUL_DAMAGE_NABBAG_BONUS_MULT - 1) * souls_clamped / wortox.SOUL_DAMAGE_MAX_SOULS)
		soul_bonus = souls_clamped > 0
	end
	return damage, soul_bonus
end

-- Returns min damage, max damage, and whether a skill bonus is included
local function GetBaseDamage(item, data, owner)
	if item.prefab == "wortox_nabbag" then
		local damage, soul_bonus = GetNabbagDamage(owner)
		if damage ~= nil then
			return damage, damage, soul_bonus
		end
	elseif item.prefab == "hambat" then
		local percent = GetPerishPercent(item) or 1
		local damage = TUNING.HAMBAT_DAMAGE * percent
		damage = Remap(damage, 0, TUNING.HAMBAT_DAMAGE, TUNING.HAMBAT_MIN_DAMAGE_MODIFIER * TUNING.HAMBAT_DAMAGE, TUNING.HAMBAT_DAMAGE)
		return damage, damage
	elseif item.prefab == "trident" and TUNING.TRIDENT ~= nil then
		local x, y, z = owner.Transform:GetWorldPosition()
		local on_ground = TheWorld.Map:IsVisualGroundAtPoint(x, y, z)
		local damage = on_ground and TUNING.TRIDENT.DAMAGE or TUNING.TRIDENT.OCEAN_DAMAGE
		return damage, damage
	end

	local damage = data.weapon.damage
	if damage == nil then
		local tuning = TUNING[string.upper(item.prefab).."_DAMAGE"]
		if type(tuning) == "number" then
			return tuning, tuning
		end
		return nil
	end
	return damage[1], damage[2]
end

-- Icons for "against lunar / shadow creatures" (bonus damage, resistance), deliberately different
-- from the item's own alignment icons used for its planar damage / defense
local ALIGNMENT_ICONS =
{
	lunar_aligned = ICONS.vs_lunar,
	shadow_aligned = ICONS.vs_shadow,
}

-- Gear has no lunar_aligned / shadow_aligned tags (only creatures do), so the alignment comes from
-- what the gear does: lunar gear hits shadow creatures harder and resists lunar damage, and the
-- other way around. Then the game's tags, then the prefab name for gear with neither (staffs, bombs).
local function GetAlignment(item, data)
	local bonus, resist = data.damagetypebonus, data.damagetyperesist
	if (bonus ~= nil and (bonus.shadow_aligned or 1) > 1) or (resist ~= nil and (resist.lunar_aligned or 1) < 1) then
		return "lunar"
	elseif (bonus ~= nil and (bonus.lunar_aligned or 1) > 1) or (resist ~= nil and (resist.shadow_aligned or 1) < 1) then
		return "shadow"
	elseif item:HasTag("lunar_aligned") or item:HasTag("lunarplant") then
		return "lunar"
	elseif item:HasTag("shadow_aligned") or item:HasTag("shadow_item") or item:HasTag("shadowlevel") then
		return "shadow"
	end
	local prefab = item.prefab or ""
	if prefab:find("lunarplant", 1, true) then
		return "lunar"
	elseif prefab:find("voidcloth", 1, true) or prefab:find("dreadstone", 1, true) or prefab:find("horrorfuel", 1, true) then
		return "shadow"
	end
end

local function GetAlignmentIcon(item, data)
	local alignment = GetAlignment(item, data)
	return (alignment == "lunar" and ICONS.lunar) or (alignment == "shadow" and ICONS.shadow) or ICONS.planar
end

--------------------------------------------------------------------------
-- Sanity from equipment (mirrors components/equippable.lua GetDapperness and the
-- sanity.get_equippable_dappernessfn / no_moisture_penalty overrides of the characters)

local NO_MOISTURE_PENALTY = { wurt = true, wormwood = true }

function Stats.GetDapperness(item, equippable, owner)
	-- Hosts: exactly what components/sanity.lua Recalc uses
	local sanity = owner.components ~= nil and owner.components.sanity or nil
	local live_equippable = item.components ~= nil and item.components.equippable or nil
	if sanity ~= nil and live_equippable ~= nil then
		local ok, value = pcall(function()
			local dapperness = sanity.get_equippable_dappernessfn ~= nil and sanity.get_equippable_dappernessfn(owner, live_equippable)
				or live_equippable:GetDapperness(owner, sanity.no_moisture_penalty)
			return dapperness * (sanity.dapperness_mult or 1)
		end)
		if ok and type(value) == "number" then
			return value
		end
	end

	local dapperness = equippable.dapperness
	if equippable.flipdapperonmerms and owner:HasTag("merm") then
		dapperness = -dapperness
	end
	if not NO_MOISTURE_PENALTY[owner.prefab] and item.replica.inventoryitem ~= nil and item.replica.inventoryitem:IsWet() then
		dapperness = dapperness + TUNING.WET_ITEM_DAPPERNESS
	end

	if owner.prefab == "walter" then
		return equippable.is_magic_dapperness and dapperness or 0
	elseif owner.prefab == "waxwell" and item:HasTag("shadow_item") then
		return dapperness * TUNING.WAXWELL_SHADOW_ITEM_RESISTANCE
	elseif owner.prefab == "wanda" and item:HasTag("shadow_item") then
		local age = GetWandaAgeState(owner)
		return dapperness * ((age == "old" and TUNING.WANDA_SHADOW_RESISTANCE_OLD)
			or (age == "normal" and TUNING.WANDA_SHADOW_RESISTANCE_NORMAL)
			or TUNING.WANDA_SHADOW_RESISTANCE_YOUNG)
	end
	return dapperness
end

local function CanPlayerEquip(item, owner)
	local inventoryitem = item.replica.inventoryitem
	local tag = inventoryitem ~= nil and inventoryitem:GetEquipRestrictedTag() or nil
	return tag == nil or owner:HasTag(tag)
end

--------------------------------------------------------------------------
-- Row builders

local function AddFoodRows(rows, item, data, owner)
	-- Wortox souls aren't food, they're eaten by the souleater component (prefabs/wortox.lua OnEatSoul)
	if item:HasTag("soul") and owner:HasTag("souleater") then
		local sanity = -TUNING.SANITY_TINY
		if owner.wortox_inclination == "nice" then
			sanity = -TUNING.SANITY_TINY * 2
		elseif owner.wortox_inclination == "naughty" then
			sanity = 0
		end
		local row = { Cell(ICONS.hunger, FormatNumber(TUNING.CALORIES_MED)) }
		if sanity ~= 0 then
			table.insert(row, Cell(ICONS.sanity, FormatNumber(sanity), COLOUR_NEGATIVE))
		end
		table.insert(rows, row)
		return
	end

	local edible = data.edible
	local live = Stats.GetLiveFood(item, owner)
	local can_eat, refused
	if live ~= nil then
		can_eat, refused = live.can_eat, live.refused
	else
		can_eat = edible ~= nil and CanEat(owner, item)
		refused = can_eat and not PrefersToEat(owner, item)
	end
	if not can_eat or (refused and not CFG.show_refused_food) then
		return
	end

	local hunger, sanity, health, favorite
	if live ~= nil then
		hunger, sanity, health, favorite = live.hunger, live.sanity, live.health, live.favorite
	else
		hunger, sanity, health, favorite = Stats.GetFoodValues(item, edible, owner)
	end
	local row = {}
	local function Add(icon, value, highlight)
		if math.abs(value) >= .05 then
			local colour = (refused and COLOUR_DISABLED) or (value < 0 and COLOUR_NEGATIVE) or highlight or nil
			table.insert(row, Cell(icon, FormatNumber(value), colour))
		end
	end
	Add(ICONS.hunger, hunger, favorite and COLOUR_FAVORITE or nil)
	if favorite and not refused and #row > 0 then
		-- Star right next to the hunger value: the character's favorite food (or Wurt's veggie bonus)
		table.insert(row, { atlas = ICONS.favorite[1], tex = ICONS.favorite[2], text = "", icon_size = 34, gap = 2 })
	end
	Add(ICONS.sanity, sanity)
	Add(ICONS.health, health)
	if #row > 0 then
		table.insert(rows, row)
	end

	if edible ~= nil and edible.temperaturedelta ~= 0 and edible.temperatureduration > 0 then
		local icon = edible.temperaturedelta > 0 and ICONS.heat or ICONS.cold
		table.insert(rows, { Cell(icon, FormatNumber(edible.temperatureduration)..TEXT.seconds, refused and COLOUR_DISABLED or nil) })
	end
end

local function AddPerishRows(rows, item, data, holder)
	if CFG.perish_display == 3 or data.perishable == nil then
		return
	end

	local perishtime = data.perishable.perishtime
	local modifier = Stats.GetPerishModifier(item, holder)
	local percent = GetPerishPercent(item, modifier / perishtime)
	if percent == nil then
		return
	end

	local function TimeUntil(target)
		if modifier <= 0 then
			return math.huge
		end
		return math.max(0, (percent - target) * perishtime / modifier)
	end

	local row = { Cell(ICONS.freshness, FormatPercent(percent)) }
	local stale_time = percent > TUNING.PERISH_FRESH and TimeUntil(TUNING.PERISH_FRESH) or nil
	local rot_time = TimeUntil(0)

	-- Stale timers only make sense for food
	if data.edible == nil or CFG.perish_display == 0 then
		table.insert(row, Cell(ICONS.spoiled, FormatTime(rot_time)))
	elseif CFG.perish_display == 1 then
		if stale_time ~= nil then
			table.insert(row, Cell(ICONS.stale, FormatTime(stale_time)))
		else
			table.insert(row, Cell(ICONS.spoiled, FormatTime(rot_time)))
		end
	else
		if stale_time ~= nil then
			table.insert(row, Cell(ICONS.stale, FormatTime(stale_time)))
		end
		table.insert(row, Cell(ICONS.spoiled, FormatTime(rot_time)))
	end
	table.insert(rows, row)
end

local function AddWeaponRow(rows, item, data, owner)
	if data.weapon == nil or not CanPlayerEquip(item, owner) then
		return
	end

	-- Everything coming from set bonuses and skills is shown in green
	local bonus = Sets.GetWeaponBonus(owner, item)
	local bonus_mult = bonus ~= nil and bonus.damage_mult ~= nil and TUNING[bonus.damage_mult] or 1
	local planar_bonus = (bonus ~= nil and bonus.planar_bonus ~= nil and TUNING[bonus.planar_bonus] or 0)

	local row = {}
	local min, max, skill_bonus = GetBaseDamage(item, data, owner)
	if min ~= nil and max > 0 then
		local mult = Stats.GetDamageMultiplier(owner, item) * bonus_mult
		local text = FormatNumber(min * mult)
		if max ~= min then
			text = text.."-"..FormatNumber(max * mult)
		end
		table.insert(row, Cell(ICONS.weapon, text, (bonus_mult ~= 1 or skill_bonus) and COLOUR_BONUS or nil))
	end

	if data.planardamage ~= nil and data.planardamage > 0 then
		planar_bonus = planar_bonus + Stats.GetWolfgangPlanarBonus(owner, item)
		local planar = data.planardamage + planar_bonus
		local text = FormatNumber(planar)
		-- Full Void set: every hit adds planar damage to shadow weapons, up to 6 hits (prefabs/hats.lua)
		local ramp = Sets.GetVoidclothRamp(owner, item)
		if ramp > 0 then
			text = text.."-"..FormatNumber(planar + ramp)
		end
		table.insert(row, Cell(GetAlignmentIcon(item, data), text, (planar_bonus ~= 0 or ramp > 0) and COLOUR_BONUS or nil))
	end

	-- Bonus damage against an alignment: the weapon's own bonus stacks with the player's
	-- allegiance skill (components/combat.lua CalcDamage), applied to normal and planar damage
	local vs = {}
	local from_skill = {}
	for tag, mult in pairs(data.damagetypebonus or {}) do
		vs[tag] = mult
	end
	for tag, mult in pairs(Stats.GetAllegianceBonus(owner) or {}) do
		vs[tag] = (vs[tag] or 1) * mult
		from_skill[tag] = true
	end
	for _, tag in ipairs({ "lunar_aligned", "shadow_aligned" }) do
		local mult = vs[tag]
		if mult ~= nil and mult > 1.0005 then
			table.insert(row, Cell(ALIGNMENT_ICONS[tag], "+"..FormatPercent(mult - 1), from_skill[tag] and COLOUR_BONUS or nil))
		end
	end

	if #row > 0 then
		table.insert(rows, row)
	end
end

local function AddArmorRow(rows, item, data, owner)
	if data.armor == nil then
		return
	end

	local row = {}
	if data.armor.absorb > 0 then
		table.insert(row, Cell(ICONS.armor, FormatPercent(data.armor.absorb)))
	end
	local percent = GetPercentUsed(item)
	if percent ~= nil then
		table.insert(row, Cell(ICONS.health, string.format("%d", math.floor(data.armor.maxcondition * percent + .5)), DurabilityColour(percent)))
	end
	if #row > 0 then
		table.insert(rows, row)
	end

	-- Planar defense and less damage taken from aligned creatures (set bonus / skills in green)
	row = {}
	local skill_defense = Stats.GetSkillPlanarDefense(owner, item)
	local planardefense = (data.planardefense or 0) + skill_defense
	if planardefense > 0 then
		table.insert(row, Cell(GetAlignmentIcon(item, data), FormatNumber(planardefense), skill_defense > 0 and COLOUR_BONUS or nil))
	end
	if data.damagetyperesist ~= nil then
		local set = Sets.GetActiveArmorSet(owner, item)
		local set_resist = set ~= nil and Sets.RESIST[set] or nil
		for _, tag in ipairs({ "lunar_aligned", "shadow_aligned" }) do
			local mult = data.damagetyperesist[tag]
			if mult ~= nil then
				local boosted = set_resist ~= nil and set_resist.tag == tag and TUNING[set_resist.mult] ~= nil
				if boosted then
					mult = mult * TUNING[set_resist.mult]
				end
				if mult < .9995 then
					table.insert(row, Cell(ALIGNMENT_ICONS[tag], "-"..FormatPercent(1 - mult), boosted and COLOUR_BONUS or nil))
				end
			end
		end
	end
	if #row > 0 then
		table.insert(rows, row)
	end
end

local function AddClothingRows(rows, item, data, owner)
	local row = {}

	local equippable = data.equippable
	if equippable ~= nil then
		local dapperness = Stats.GetDapperness(item, equippable, owner)
		if math.abs(dapperness * 60) >= .05 then
			table.insert(row, Cell(ICONS.sanity, FormatSigned(dapperness * 60)..TEXT.per_minute, dapperness < 0 and COLOUR_NEGATIVE or nil))
		end

		local speed = equippable.walkspeedmult
		if speed < 1 and owner:HasTag("vigorbuff") then
			speed = math.min(1, speed + .25)
		end
		if math.abs(speed - 1) >= .005 then
			table.insert(row, Cell(GetSpeedIcon(), FormatSigned((speed - 1) * 100).."%", speed < 1 and COLOUR_NEGATIVE or nil))
		end
	end
	if #row > 0 then
		table.insert(rows, row)
		row = {}
	end

	if data.insulator ~= nil then
		table.insert(row, Cell(ICONS["insulation_"..data.insulator.type], FormatNumber(data.insulator.insulation)))
	end
	if data.waterproofer ~= nil then
		table.insert(row, Cell(ICONS.waterproof, FormatPercent(data.waterproofer)))
	end
	if #row > 0 then
		table.insert(rows, row)
	end
end

local HEATROCK_RANGES =
{
	[1] = ICONS.cold, [2] = ICONS.cold, [4] = ICONS.heat, [5] = ICONS.heat,
}

local function GetHeatrockRange(item)
	local inventoryitem = item.replica.inventoryitem
	if inventoryitem == nil then
		return nil
	end
	local image = inventoryitem:GetImage()
	local skin = item:GetSkinName() or "heat_rock"
	for range = 1, 5 do
		local name = skin..range..".tex"
		if image == name or image == hash(name) then
			return range
		end
	end
end

local function AddDurabilityRows(rows, item, data, owner)
	local percent = GetPercentUsed(item)

	if data.finiteuses ~= nil and percent ~= nil then
		-- Tools use their cheapest action, pure weapons wear per hit
		local per_use = data.finiteuses.per_action or (data.weapon ~= nil and data.weapon.attackwear) or 1
		-- The knapsack's durability counts nabbed items (NABBAG_USES); its bug net action costs more
		if item.prefab == "wortox_nabbag" then
			per_use = 1
		end
		if per_use > 0 then
			local maxuses = data.finiteuses.total / per_use
			local uses = data.finiteuses.total * percent / per_use
			table.insert(rows, { Cell(ICONS.uses, string.format("%d/%d", math.floor(uses + .5), math.floor(maxuses + .5)), DurabilityColour(percent)) })
		end
	end

	if data.fueled ~= nil and percent ~= nil then
		if data.fueled.uses ~= nil then
			local row = { Cell(ICONS.uses, string.format("%d/%d", math.floor(data.fueled.uses * percent + .5), data.fueled.uses), DurabilityColour(percent)) }
			if item.prefab == "heatrock" then
				local range = GetHeatrockRange(item)
				if range ~= nil and HEATROCK_RANGES[range] ~= nil then
					table.insert(row, Cell(HEATROCK_RANGES[range], TEXT.heatrock[range]))
				end
			end
			table.insert(rows, row)
		else
			local rate = data.fueled.rate
			-- prefabs/torch.lua raises fueled.rate while it rains; live (host) data already includes it
			if item.prefab == "torch" and not data.live and TheWorld.state.israining then
				rate = rate * (1 + TUNING.TORCH_RAIN_RATE * TheWorld.state.precipitationrate)
			end
			if rate > 0 then
				local remaining = data.fueled.maxfuel * percent / rate
				table.insert(rows, { Cell(ICONS["fuel_"..data.fueled.kind], FormatTime(remaining), DurabilityColour(percent)) })
			end
		end
	end
end

-- Health of the structure a kit / wall item places (boat bumpers, walls)
local function AddPlacedHealthRow(rows, data)
	if data.placed_health ~= nil then
		table.insert(rows, { Cell(ICONS.health, FormatNumber(data.placed_health)) })
	end
end

local function AddHealerRow(rows, item, data, owner)
	if data.healer ~= nil then
		table.insert(rows, { Cell(ICONS.health, FormatSigned(data.healer)) })
	end
end

--------------------------------------------------------------------------

local function BuildRows(item, holder, owner)
	local rows = {}
	local data = Cache.Get(item)

	if data ~= nil then
		if CFG.show_food then
			AddFoodRows(rows, item, data, owner)
			AddHealerRow(rows, item, data, owner)
		end
		AddPerishRows(rows, item, data, holder)
		if CFG.show_combat then
			AddWeaponRow(rows, item, data, owner)
			AddArmorRow(rows, item, data, owner)
		end
		if CFG.show_clothing then
			AddClothingRows(rows, item, data, owner)
		end
		if CFG.show_durability then
			AddDurabilityRows(rows, item, data, owner)
			AddPlacedHealthRow(rows, data)
		end
	end

	if CFG.show_prefabname then
		table.insert(rows, { Cell(ICONS.label, item.prefab) })
	end

	return rows
end

local function Signature(rows)
	local parts = {}
	for _, row in ipairs(rows) do
		for _, cell in ipairs(row) do
			parts[#parts + 1] = tostring(cell.tex)
			parts[#parts + 1] = cell.text
			parts[#parts + 1] = cell.colour ~= nil and tostring(cell.colour) or ""
		end
		parts[#parts + 1] = "\n"
	end
	return table.concat(parts, "|")
end

local reported_errors = {}

-- Returns rows, signature. Never throws: a broken item just shows nothing.
function Stats.GetRows(item, holder, owner)
	if item == nil or not item:IsValid() or item.replica.inventoryitem == nil or owner == nil then
		return {}, ""
	end

	local ok, rows = pcall(BuildRows, item, holder, owner)
	if not ok then
		if not reported_errors[item.prefab] then
			reported_errors[item.prefab] = true
			print("[Item Info Reworked] Error while reading "..tostring(item.prefab)..": "..tostring(rows))
		end
		return {}, ""
	end
	return rows, Signature(rows)
end

return Stats
