-- Base stats of every item prefab, read once per prefab and cached.
--
-- Clients only receive an item's networked percentages (freshness / durability), never the
-- real component values. To get the max values we spawn a throwaway copy of the prefab in
-- a fake "master sim" context, copy the numbers we need and remove it straight away.
--
-- Everything the copy creates is tracked and removed again, every step is protected with
-- pcall, and the game's own scrapbook data is used as fallback (creatures, crashing prefabs,
-- weapons whose damage is a function).

local Sets = require "iteminfo_updated/sets"

local Cache = {}

local cached = {}

local SPAWN_BLOCKLIST =
{
	blueprint = true,
	sketch = true,
	tacklesketch = true,
}

--------------------------------------------------------------------------
-- Scrapbook fallback

local scrapbook = nil

local function GetScrapbookEntry(prefab)
	if scrapbook == nil then
		local ok, data = pcall(require, "screens/redux/scrapbookdata")
		scrapbook = ok and type(data) == "table" and data or false
	end
	return scrapbook and scrapbook[prefab] or nil
end

-- Normalizes the different weapon damage formats to {min, max}.
-- Accepts a number, a {min, max} table (scrapbook_weapondamage) or a "51-76" string (scrapbook data).
local function NormalizeDamage(value)
	if type(value) == "number" then
		return { value, value }
	elseif type(value) == "table" and type(value[1]) == "number" then
		return { value[1], type(value[2]) == "number" and value[2] or value[1] }
	elseif type(value) == "string" then
		local lo, hi = value:match("^%s*([%d%.]+)%s*%-%s*([%d%.]+)%s*$")
		if lo ~= nil then
			return { tonumber(lo), tonumber(hi) }
		end
		local n = tonumber(value)
		if n ~= nil then
			return { n, n }
		end
	end
end

--------------------------------------------------------------------------
-- Safe prefab spawning

local function SpawnAndRead(prefab, readfn)
	if Prefabs[prefab] == nil or TheWorld == nil then
		return nil
	end

	local created = {}
	local created_set = {}
	local foreign_tasks = {}
	local foreign_listeners = {}
	local _CreateEntity = CreateEntity
	local _RegisterComponentActions = EntityScript.RegisterComponentActions
	local _DoTaskInTime = EntityScript.DoTaskInTime
	local _DoPeriodicTask = EntityScript.DoPeriodicTask
	local _DoStaticTaskInTime = EntityScript.DoStaticTaskInTime
	local _DoStaticPeriodicTask = EntityScript.DoStaticPeriodicTask
	local _ListenForEvent = EntityScript.ListenForEvent
	local _ismastersim = TheWorld.ismastersim

	-- Track every entity the prefab (and anything it spawns) creates, so nothing can leak.
	CreateEntity = function(...)
		local ent = _CreateEntity(...)
		created[#created + 1] = ent
		created_set[ent] = true
		return ent
	end
	-- Tasks / listeners the copy puts on OTHER entities (e.g. TheWorld:DoTaskInTime) would
	-- outlive it and could run on a removed entity later: record them and undo them afterwards.
	local function WrapTask(original)
		return function(self, ...)
			local task = original(self, ...)
			if not created_set[self] and task ~= nil then
				foreign_tasks[#foreign_tasks + 1] = task
			end
			return task
		end
	end
	EntityScript.DoTaskInTime = WrapTask(_DoTaskInTime)
	EntityScript.DoPeriodicTask = WrapTask(_DoPeriodicTask)
	EntityScript.DoStaticTaskInTime = WrapTask(_DoStaticTaskInTime)
	EntityScript.DoStaticPeriodicTask = WrapTask(_DoStaticPeriodicTask)
	EntityScript.ListenForEvent = function(self, event, fn, source)
		_ListenForEvent(self, event, fn, source)
		if not created_set[self] then
			foreign_listeners[#foreign_listeners + 1] = { self, event, fn, source }
		end
	end
	-- The copy must never register actions: on modded servers that desyncs the action tables.
	EntityScript.RegisterComponentActions = function() end
	TheWorld.ismastersim = true

	local result = nil
	local ok, copy = pcall(SpawnPrefab, prefab)
	if ok and copy ~= nil then
		local read_ok, value = pcall(readfn, copy)
		if read_ok then
			result = value
		else
			print("[Item Info Reworked] Failed to read stats of "..tostring(prefab)..": "..tostring(value))
		end
	elseif not ok then
		print("[Item Info Reworked] Failed to spawn "..tostring(prefab)..": "..tostring(copy))
	end

	for i = #created, 1, -1 do
		local ent = created[i]
		if ent:IsValid() then
			pcall(ent.Remove, ent)
		end
	end

	-- Restore everything before undoing foreign tasks / listeners
	TheWorld.ismastersim = _ismastersim
	EntityScript.RegisterComponentActions = _RegisterComponentActions
	EntityScript.DoTaskInTime = _DoTaskInTime
	EntityScript.DoPeriodicTask = _DoPeriodicTask
	EntityScript.DoStaticTaskInTime = _DoStaticTaskInTime
	EntityScript.DoStaticPeriodicTask = _DoStaticPeriodicTask
	EntityScript.ListenForEvent = _ListenForEvent
	CreateEntity = _CreateEntity

	for _, task in ipairs(foreign_tasks) do
		pcall(task.Cancel, task)
	end
	for _, listener in ipairs(foreign_listeners) do
		local ent = listener[1]
		if ent.IsValid ~= nil and ent:IsValid() then
			pcall(ent.RemoveEventCallback, ent, listener[2], listener[3], listener[4])
		end
	end

	return result
end

--------------------------------------------------------------------------
-- Readers

local function GetModifierListValue(list, fallback)
	if list ~= nil and list.Get ~= nil then
		local ok, value = pcall(list.Get, list)
		if ok and type(value) == "number" then
			return value
		end
	end
	return fallback
end

local function ReadWeapon(inst, data)
	local weapon = inst.components.weapon
	if weapon == nil then
		return
	end

	local damage = NormalizeDamage(weapon.damage) or NormalizeDamage(inst.scrapbook_weapondamage)
	-- Live items (hosts) may have their set bonus applied already: store the base damage,
	-- stats.lua applies the bonus itself
	local set = Sets.WEAPONS[inst.prefab]
	if damage ~= nil and inst._bonusenabled and set ~= nil and set.damage_mult ~= nil and TUNING[set.damage_mult] then
		local mult = TUNING[set.damage_mult]
		damage = { damage[1] / mult, damage[2] / mult }
	end

	data.weapon =
	{
		damage = damage,
		attackwear = (weapon.attackwear or 1) * GetModifierListValue(weapon.attackwearmultipliers, 1),
	}

	if inst.components.planardamage ~= nil then
		local planar = inst.components.planardamage
		data.planardamage = planar.GetBaseDamage ~= nil and planar:GetBaseDamage() or planar.basedamage
	end

	if inst.components.damagetypebonus ~= nil and inst.components.damagetypebonus.tags ~= nil then
		local bonuses = {}
		for tag, list in pairs(inst.components.damagetypebonus.tags) do
			local mult = GetModifierListValue(list, 1)
			if mult ~= 1 then
				bonuses[tag] = mult
			end
		end
		if next(bonuses) ~= nil then
			data.damagetypebonus = bonuses
		end
	end
end

local function ReadStats(inst)
	local data = {}
	local c = inst.components

	if c.equippable ~= nil then
		local equippable = c.equippable
		data.equippable =
		{
			dapperness = type(equippable.dapperness) == "number" and equippable.dapperness or 0,
			flipdapperonmerms = equippable.flipdapperonmerms,
			is_magic_dapperness = equippable.is_magic_dapperness,
			walkspeedmult = type(equippable.walkspeedmult) == "number" and equippable.walkspeedmult or 1,
		}
	end

	if c.perishable ~= nil and type(c.perishable.perishtime) == "number" and c.perishable.perishtime > 0 then
		data.perishable = { perishtime = c.perishable.perishtime }
	end

	if c.insulator ~= nil and type(c.insulator.insulation) == "number" and c.insulator.insulation ~= 0 then
		data.insulator =
		{
			insulation = c.insulator.insulation,
			type = c.insulator.type == SEASONS.SUMMER and "summer" or "winter",
		}
	end

	if c.waterproofer ~= nil then
		local effectiveness = c.waterproofer:GetEffectiveness()
		if type(effectiveness) == "number" and effectiveness > 0 then
			data.waterproofer = effectiveness
		end
	end

	if c.finiteuses ~= nil and type(c.finiteuses.total) == "number" and c.finiteuses.total > 0 then
		-- Uses per action: the cheapest action of a tool, else 1 (weapons use attackwear, see stats.lua)
		local per_action = nil
		for _, v in pairs(c.finiteuses.consumption or {}) do
			if type(v) == "number" and v > 0 and (per_action == nil or v < per_action) then
				per_action = v
			end
		end
		data.finiteuses = { total = c.finiteuses.total, per_action = per_action }
	end

	ReadWeapon(inst, data)

	if c.fueled ~= nil and type(c.fueled.maxfuel) == "number" and c.fueled.maxfuel > 0 then
		data.fueled =
		{
			maxfuel = c.fueled.maxfuel,
			rate = (c.fueled.rate or 1) * GetModifierListValue(c.fueled.rate_modifiers, 1),
			kind = (c.fueled.fueltype == FUELTYPE.USAGE or c.fueled.fueltype == FUELTYPE.MAGIC) and "wearable" or "light",
			-- Thermal stone style items lose a fixed fraction per use instead of burning over time
			uses = inst.scrapbook_fueled_uses and inst.scrapbook_fueled_rate or nil,
		}
	end

	if c.armor ~= nil and type(c.armor.maxcondition) == "number" and c.armor.maxcondition > 0 then
		data.armor =
		{
			absorb = c.armor.absorb_percent or 0,
			maxcondition = c.armor.maxcondition,
		}
	end

	if c.planardefense ~= nil then
		local planar = c.planardefense
		local value = planar.GetBaseDefense ~= nil and planar:GetBaseDefense() or planar.basedefense
		if type(value) == "number" and value > 0 then
			data.planardefense = value
		end
	end

	-- Damage taken from aligned creatures, without set bonuses (stats.lua applies those)
	if c.damagetyperesist ~= nil and c.damagetyperesist.tags ~= nil then
		local resists = {}
		for tag, list in pairs(c.damagetyperesist.tags) do
			local mult = GetModifierListValue(list, 1)
			if list.CalculateModifierFromKey ~= nil then
				local ok, setbonus = pcall(list.CalculateModifierFromKey, list, "setbonus")
				if ok and type(setbonus) == "number" and setbonus > 0 then
					mult = mult / setbonus
				end
			end
			if math.abs(mult - 1) > .001 then
				resists[tag] = mult
			end
		end
		if next(resists) ~= nil then
			data.damagetyperesist = resists
		end
	end

	if c.healer ~= nil and type(c.healer.health) == "number" and c.healer.health ~= 0 then
		data.healer = c.healer.health
	end

	if c.edible ~= nil then
		local edible = c.edible
		data.edible =
		{
			foodtype = edible.foodtype,
			hunger = edible.hungervalue or 0,
			sanity = edible.sanityvalue or 0,
			health = edible.healthvalue or 0,
			degrades = edible.degrades_with_spoilage ~= false,
			stale_hunger = edible.stale_hunger,
			stale_health = edible.stale_health,
			spoiled_hunger = edible.spoiled_hunger,
			spoiled_health = edible.spoiled_health,
			spice = edible.spice,
			temperaturedelta = edible.temperaturedelta or 0,
			temperatureduration = edible.temperatureduration or 0,
		}
	end

	return data
end

local function ReadProjectile(inst)
	local data = {}
	ReadWeapon(inst, data)
	return data
end

--------------------------------------------------------------------------
-- Scrapbook merge (fills gaps, never overrides spawned values)

-- Kits and wall items (boat_bumper_kelp_kit, wall_stone_item...) place a structure: show that
-- structure's health. Uses the game's scrapbook, so new kits / walls are covered automatically.
local function AddPlacedHealth(prefab, data)
	local placed = prefab:match("^(.+)_kit$") or prefab:match("^(.+)_item$")
	local entry = placed ~= nil and GetScrapbookEntry(placed) or nil
	if entry ~= nil and entry.type ~= "creature" and type(entry.health) == "number" and entry.health > 1 then
		data.placed_health = entry.health
	end
end

local function MergeScrapbook(prefab, data)
	AddPlacedHealth(prefab, data)
	local entry = GetScrapbookEntry(prefab)
	if entry == nil then
		return data
	end

	if data.perishable == nil and type(entry.perishable) == "number" and entry.perishable > 0 then
		data.perishable = { perishtime = entry.perishable }
	end

	if data.edible == nil and type(entry.hungervalue) == "number" and entry.foodtype ~= nil then
		data.edible =
		{
			foodtype = entry.foodtype,
			hunger = entry.hungervalue or 0,
			sanity = entry.sanityvalue or 0,
			health = entry.healthvalue or 0,
			degrades = true,
			temperaturedelta = 0,
			temperatureduration = 0,
		}
	end

	local scrap_damage = NormalizeDamage(entry.weapondamage)
	if scrap_damage ~= nil then
		if data.weapon == nil then
			data.weapon = { damage = scrap_damage, attackwear = 1 }
		elseif data.weapon.damage == nil then
			data.weapon.damage = scrap_damage
		end
	end
	if data.planardamage == nil and type(entry.planardamage) == "number" and entry.planardamage > 0 then
		data.planardamage = entry.planardamage
	end

	if data.armor == nil and type(entry.armor) == "number" and entry.armor > 0 then
		data.armor = { absorb = entry.absorb_percent or 0, maxcondition = entry.armor }
	end
	if data.planardefense == nil and type(entry.armor_planardefense) == "number" and entry.armor_planardefense > 0 then
		data.planardefense = entry.armor_planardefense
	end

	if data.finiteuses == nil and type(entry.finiteuses) == "number" and entry.finiteuses > 0 then
		data.finiteuses = { total = entry.finiteuses }
	end

	if data.fueled == nil and type(entry.fueledmax) == "number" and entry.fueledmax > 0 then
		data.fueled =
		{
			maxfuel = entry.fueledmax,
			rate = entry.fueleduses and 1 or (entry.fueledrate or 1),
			kind = (entry.fueledtype1 == "USAGE" or entry.fueledtype1 == "MAGIC") and "wearable" or "light",
			uses = entry.fueleduses and entry.fueledrate or nil,
		}
	end

	if data.insulator == nil and type(entry.insulator) == "number" and entry.insulator ~= 0 then
		data.insulator = { insulation = entry.insulator, type = entry.insulator_type == "summer" and "summer" or "winter" }
	end
	if data.waterproofer == nil and type(entry.waterproofer) == "number" and entry.waterproofer > 0 then
		data.waterproofer = entry.waterproofer
	end
	if data.equippable == nil and type(entry.dapperness) == "number" and entry.dapperness ~= 0 then
		data.equippable = { dapperness = entry.dapperness, walkspeedmult = 1 }
	end

	return data
end

--------------------------------------------------------------------------

local function Build(item)
	local prefab = item.prefab
	local entry = GetScrapbookEntry(prefab)

	-- Creatures (rabbits, spiders, birds...) run brains and stategraphs when spawned;
	-- the scrapbook already has everything we show for them.
	local data = nil
	if not SPAWN_BLOCKLIST[prefab] and not (entry ~= nil and entry.type == "creature") then
		data = SpawnAndRead(prefab, ReadStats)
	end
	data = MergeScrapbook(prefab, data or {})

	-- Slingshot ammo: the damage lives on the projectile prefab
	if Prefabs[prefab.."_proj"] ~= nil then
		local proj = SpawnAndRead(prefab.."_proj", ReadProjectile) or {}
		proj = MergeScrapbook(prefab.."_proj", proj)
		if proj.weapon ~= nil then
			data.weapon = proj.weapon
			data.planardamage = proj.planardamage or data.planardamage
			data.damagetypebonus = proj.damagetypebonus or data.damagetypebonus
			data.is_ammo = true
		end
	end

	return data
end

-- Hosts (non dedicated servers) already have every component on the real item, so we read it
-- directly instead of spawning a copy: spawning on the master sim would create a real networked
-- entity, with world side effects for every player. Live values (set bonuses, upgrades) can
-- change, so they are re-read every LIVE_REFRESH_TIME seconds per item.
local LIVE_REFRESH_TIME = 1
local live_cached = setmetatable({}, { __mode = "k" })

local function BuildLive(item)
	local data = ReadStats(item)
	data.live = true
	-- Slingshot ammo: the scrapbook has the projectile damage, no need to spawn one on the server
	return MergeScrapbook(item.prefab, data)
end

local function GetLive(item)
	local now = GetTime()
	local entry = live_cached[item]
	if entry == nil or now - entry.time >= LIVE_REFRESH_TIME then
		local ok, result = pcall(BuildLive, item)
		if not ok then
			print("[Item Info Reworked] Failed to read "..tostring(item.prefab)..": "..tostring(result))
		end
		entry = { time = now, data = ok and result or false }
		live_cached[item] = entry
	end
	return entry.data or nil
end

function Cache.Get(item)
	local prefab = item ~= nil and item.prefab or nil
	if prefab == nil then
		return nil
	end

	if TheWorld ~= nil and TheWorld.ismastersim and item.components ~= nil then
		return GetLive(item)
	end

	local data = cached[prefab]
	if data == nil then
		local ok, result = pcall(Build, item)
		if not ok then
			print("[Item Info Reworked] Failed to cache "..tostring(prefab)..": "..tostring(result))
		end
		data = ok and result or false
		cached[prefab] = data
	end
	return data or nil
end

return Cache
