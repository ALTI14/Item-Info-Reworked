-- Spoilage: how fast an item spoils where it is (mirrors components/perishable.lua Update), its freshness
-- and the time until stale / rotten.

local ItemState = require "iteminfo_updated/stats/itemstate"

local Spoilage = {}

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

function Spoilage.GetPerishModifier(item, holder)
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

-- Freshness (0-1), time until stale (nil once stale) and time until rotten
function Spoilage.Compute(item, data, holder)
	if data.perishable == nil then
		return nil
	end
	local perishtime = data.perishable.perishtime
	local modifier = Spoilage.GetPerishModifier(item, holder)
	local percent = ItemState.GetPerishPercent(item, modifier / perishtime)
	if percent == nil then
		return nil
	end
	local function TimeUntil(target)
		if modifier <= 0 then
			return math.huge
		end
		return math.max(0, (percent - target) * perishtime / modifier)
	end
	return percent, percent > TUNING.PERISH_FRESH and TimeUntil(TUNING.PERISH_FRESH) or nil, TimeUntil(0)
end

return Spoilage
