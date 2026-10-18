-- Heat sources around a Thermal Stone, as far as a client can tell their heat (components/heater.lua,
-- and each heater's prefab). When the strength can't be known on a client (hot springs, cave vents, WX-78's
-- modules, modded heaters...), the possible values are given as several states, which the model (model.lua)
-- turns into bounds.

local Upvalue = require "iteminfo_updated/upvalue"

local Heaters = {}

-- By prefab. Each source gives a list of possible states { heat, exo, endo }; OFF is a
-- source that currently does nothing (no thermics). One state means the client knows it exactly.

local OFF = { off = true }
local function Exo(heat) return { heat = heat, exo = true } end
local function Endo(heat) return { heat = heat, endo = true } end

-- components/firefx.lua: each fire level plays its own animations (loop, and for some fires ignition,
-- going out and controlled burn variants); the heat comes from the level ({ heat, animations... }).
-- default: the heat before the first level is set.
local function Level(heat, ...) return { heat = heat, anims = { ... } } end
local function Burning(heat, size) -- character_fire / lavalight style names
	return Level(heat, "loop_"..size, "pre_"..size, "post_"..size, "post_"..size.."_fast",
		"loop_"..size.."_controlled_burn", "pre_"..size.."_controlled_burn", "post_"..size.."_controlled_burn")
end
local FIRES =
{
	-- prefabs/campfirefire.lua (campfire, fire pit...)
	campfirefire = { default = 20, levels = { Level(70, "level1"), Level(85, "level2"), Level(100, "level3"), Level(115, "level4") } },
	portable_campfirefire = { default = 20, levels = { Level(70, "level1"), Level(77.5, "level1a"), Level(85, "level2") } },
	-- prefabs/coldfirefire.lua (endothermic fire)
	coldfirefire = { default = -20, endo = true, levels = { Level(-10, "level1_redux"), Level(-20, "level2_redux"), Level(-30, "level3_redux"), Level(-40, "level4_redux") } },
	-- prefabs/fire.lua (burning objects, wildfires): levels 4 and 5 share an animation, their light
	-- radius (radii below) tells them apart
	fire =
	{
		default = 20,
		radii = { 2, 3, 4, 5, 6, 7 },
		levels =
		{
			Level(30, "level1", "level1_controlled_burn"), Level(70, "level2", "level2_controlled_burn"),
			Level(120, "level3", "level3_controlled_burn"), Level(180, "level4", "level4_controlled_burn"),
			Level(220, "level4", "level4_controlled_burn"), Level(240, "level5", "level5_controlled_burn"),
		},
	},
	-- prefabs/character_fire.lua (burning creatures) and prefabs/lavalight.lua (Willow's Lavae light)
	character_fire = { default = 40, levels = { Burning(50, "small"), Burning(65, "med"), Burning(80, "large") } },
	lavalight = { default = 40, levels = { Burning(50, "small"), Burning(65, "med"), Burning(100, "large") } },
}

local FIXED =
{
	dragonflyfurnace = { Exo(115) },           -- prefabs/dragonfurnace.lua (also the salad furnace)
	lava_pond = { Exo(500) },                  -- prefabs/lava_pond.lua
	stafflight = { Exo(100) },                 -- prefabs/stafflight.lua: Star Caller's Staff (dwarf star)
	emberlight = { Exo(100) },                 -- Willow's ember star
	staffcoldlight = { Endo(-100) },           -- Moon Caller's Staff (polar light)
	staffcoldlightfx = { Endo(-100) },
	character_fire_flicker = { Exo(65) },      -- prefabs/character_fire.lua
	oceanfish_small_8_inv = { Exo(70) },       -- prefabs/oceanfishdef.lua: Scorching Sunfish
	oceanfish_medium_8_inv = { Endo(-5) },     -- Ice Bream
}

-- Heaters whose heat only applies when worn or carried: lying around they do nothing (no heat value)
local NO_HEAT =
{
	blueamulet = true,
	icehat = true,
	watermelonhat = true,
	minifan = true,
}

-- Winona's spotlight beam is aimed on the client from synced values: near the edge of its circle the
-- client may be a little off, so there it counts as maybe heating
local SPOTLIGHT_EDGE_MARGIN = 1

-- WX-78 (and its backup / possessed bodies): prefabs/wx78_common.lua GetThermicTemperatureFn,
-- TUNING.WX78_HEATERTEMPPERMODULE per active heat circuit minus active cold circuit. Only the local
-- player's own circuits are known (wx78_classified); others are bounded generously.
local WX78_BODIES = { wx78 = true, wx78_backupbody = true, wx78_possessedbody = true }
local WX78_MAX_LEAN = 10

-- components/upgrademoduleowner.lua UpdateActivatedModules: in each circuit bar the charge powers the
-- circuits in order, each using its slots; wx78_moduledefs.lua: heat circuits lean +1, cold -1
local moduledefs = nil
local function CountWX78Lean(classified)
	moduledefs = moduledefs or require("wx78_moduledefs")
	local charge = classified:GetEnergyLevel()
	local total = 0
	for _, netids in pairs(classified:GetModulesData()) do
		local remaining = charge
		for _, netid in ipairs(netids) do
			local def = netid ~= 0 and moduledefs.GetModuleDefinitionFromNetID(netid) or nil
			if def ~= nil then
				remaining = remaining - (def.slots or 0)
				if remaining >= 0 then
					total = total + ((def.name == "heat" and 1) or (def.name == "cold" and -1) or 0)
				end
			end
		end
	end
	return total
end

local function GetWX78Lean(ent)
	local classified = ent.wx78_classified
	if classified == nil or classified.GetModulesData == nil or classified.GetEnergyLevel == nil then
		return nil
	end
	local ok, lean = pcall(CountWX78Lean, classified)
	return ok and type(lean) == "number" and lean or nil
end

local function ReadLightRadius(ent)
	if ent.Light == nil then
		return nil
	end
	local ok, radius = pcall(ent.Light.GetRadius, ent.Light)
	return ok and type(radius) == "number" and radius or nil
end

local function FireState(def, heat)
	return def.endo and Endo(heat) or Exo(heat)
end

-- components/firefx.lua: the light's radius is current_radius + .025 + a flicker of +-.0375, where
-- current_radius runs from the previous level's radius to this level's
local FIRE_LIGHT_MIN, FIRE_LIGHT_MAX = .025 - .0375, .025 + .0375

-- The heat of each level as the fire's own prefab has it (its heat function's table: campfirefire.lua heats,
-- MakeFire heatlevels...), so the mod follows the game's numbers; the values above if it has other levels
local function ReadFireHeats(prefab, def)
	def.read = true
	local fn = Upvalue.PrefabFn(prefab)
	local heats = Upvalue.Numbers(Upvalue.Find(fn, "heats", 2) or Upvalue.Find(fn, "heatlevels", 2), #def.levels)
	if heats ~= nil then
		for i, level in ipairs(def.levels) do
			level.heat = heats[i]
		end
	end
end

-- GetLightRadius: called only when the animation alone leaves more than one level
local function GetFireStates(ent, def, GetLightRadius)
	local matches = {}
	for index, level in ipairs(def.levels) do
		for _, anim in ipairs(level.anims) do
			if ent.AnimState:IsCurrentAnimation(anim) then
				table.insert(matches, index)
				break
			end
		end
	end
	local light_radius = #matches > 1 and def.radii ~= nil and GetLightRadius ~= nil and GetLightRadius(ent) or nil
	if light_radius ~= nil then
		local fitting = {}
		for _, index in ipairs(matches) do
			local low = index > 1 and def.radii[index - 1] or 0
			if light_radius >= low + FIRE_LIGHT_MIN and light_radius <= def.radii[index] + FIRE_LIGHT_MAX then
				table.insert(fitting, index)
			end
		end
		if #fitting > 0 then
			matches = fitting
		end
	end

	local states = {}
	if #matches == 0 then
		-- Unknown animation: any level
		table.insert(states, FireState(def, def.default))
		for _, level in ipairs(def.levels) do
			table.insert(states, FireState(def, level.heat))
		end
	else
		for _, index in ipairs(matches) do
			table.insert(states, FireState(def, def.levels[index].heat))
		end
	end
	return states
end

local function IsLightOn(ent)
	if ent.Light == nil then
		return nil
	end
	local ok, enabled = pcall(ent.Light.IsEnabled, ent.Light)
	if ok and type(enabled) == "boolean" then
		return enabled
	end
	return nil
end

local function IsAnim(ent, ...)
	if ent.AnimState == nil then
		return false
	end
	for i = 1, select("#", ...) do
		if ent.AnimState:IsCurrentAnimation((select(i, ...))) then
			return true
		end
	end
	return false
end

local function SpringHeat(key, fallback)
	local heats = TUNING.HOTSPRING_HEAT
	return heats ~= nil and heats[key] or fallback
end

-- Hot springs (prefabs/hotspring.lua, hermithotspring.lua): bath bombed = light on = ACTIVE; plain water =
-- PASSIVE; no water (empty, or moonglass for the oasis spring) = no heat
local function GetSpringStates(ent, hermit)
	local active, passive = Exo(SpringHeat("ACTIVE", 90)), Exo(SpringHeat("PASSIVE", 45))
	if not hermit and ent:HasTag("moonglass") then
		return {}
	end
	local lit = IsLightOn(ent)
	if lit == true then
		return { active }
	elseif lit == false then
		if IsAnim(ent, "empty", "drain", "place") then
			return {}
		elseif hermit and IsAnim(ent, "refill") then
			return { OFF, passive } -- the water counts as there 3 frames before the refill ends
		elseif not hermit or IsAnim(ent, "idle") then
			return { passive }
		end
	end
	return { OFF, passive, active }
end

-- Describes a heat source at distance² dsq for the model: { states, falloff, cutoff } or nil when it
-- does nothing. Sources the mod doesn't know (other mods) return { unknown = true }.
function Heaters.Describe(ent, dsq, context)
	local prefab = ent.prefab
	if prefab ~= nil and NO_HEAT[prefab] then
		return nil
	end

	local fire = prefab ~= nil and FIRES[prefab] or nil
	if fire ~= nil and ent.AnimState ~= nil then
		if not fire.read then
			ReadFireHeats(prefab, fire)
		end
		return { states = GetFireStates(ent, fire, context ~= nil and context.GetFireLightRadius or nil), falloff = true }
	end

	if prefab == "hotspring" or prefab == "hermithotspring" then
		local states = GetSpringStates(ent, prefab == "hermithotspring")
		return #states > 0 and { states = states, falloff = true } or nil
	end

	-- prefabs/cave_vents.lua GetVentType: hot (CAVE_VENTS.HEAT.HOT_ACTIVE), or miasma while a shadow rift is
	-- open (tag miasma_venter); the cold and gas types are never used. No falloff.
	if prefab == "cave_vent_rock" then
		local heats = TUNING.CAVE_VENTS ~= nil and TUNING.CAVE_VENTS.HEAT or {}
		local heat = ent:HasTag("miasma_venter") and (heats.MIASMA_ACTIVE or 90) or (heats.HOT_ACTIVE or 120)
		return { states = { Exo(heat) }, falloff = false }
	end

	local fixed = prefab ~= nil and FIXED[prefab] or nil
	if fixed ~= nil then
		return { states = fixed, falloff = true }
	end

	if prefab == "lavae_pet" then
		-- prefabs/lavae_pet.lua OnHungerDelta: heat Lerp(15, 100, hunger) and light radius Lerp(.33, 1, hunger)
		local radius = ReadLightRadius(ent)
		if radius ~= nil then
			local hunger = math.clamp((radius - .33) / (1 - .33), 0, 1)
			return { states = { Exo(15 + (100 - 15) * hunger) }, falloff = true }
		end
		return { states = { Exo(15), Exo(100) }, falloff = true }
	end

	if prefab ~= nil and WX78_BODIES[prefab] then
		local per_module = TUNING.WX78_HEATERTEMPPERMODULE or 25
		local lean = GetWX78Lean(ent)
		if lean == nil then
			local max = WX78_MAX_LEAN * per_module
			return { states = { OFF, Exo(max), Endo(-max) }, falloff = true }
		elseif lean == 0 then
			return nil -- no thermics
		end
		return { states = { lean > 0 and Exo(lean * per_module) or Endo(lean * per_module) }, falloff = true }
	end

	-- prefabs/winona_spotlight.lua: the beam's light, a local (unnetworked) entity on every machine, child
	-- of the spotlight at the lit spot. With Winona's winona_spotlight_heated skill, outside summer and
	-- while lit, it heats (the client adds HASHEATER itself from the synced state):
	-- SPOTLIGHT_HEAT_VALUE, no falloff, only inside the light's radius (bigger with the range skill)
	if prefab == nil and ent.DoEnableHeat ~= nil then
		local heat = TUNING.SKILLS ~= nil and TUNING.SKILLS.WINONA ~= nil and TUNING.SKILLS.WINONA.SPOTLIGHT_HEAT_VALUE or 60
		local radius = ReadLightRadius(ent)
		if radius ~= nil and dsq ~= nil and math.abs(math.sqrt(dsq) - radius) > SPOTLIGHT_EDGE_MARGIN then
			return { states = { Exo(heat) }, falloff = false, cutoff = radius }
		end
		return { states = { OFF, Exo(heat) }, falloff = false }
	end

	return { unknown = true }
end

-- Hosts (no caves): the heater component itself, exactly as components/temperature.lua reads it.
-- Returns false when the component can't be read (then the client description is used).
function Heaters.DescribeLive(ent, observer)
	local heater = ent.components ~= nil and ent.components.heater or nil
	if heater == nil then
		return false
	end
	local ok, result = pcall(function()
		local heat = heater:GetHeat(observer) -- first: some heat functions set the thermics
		local exo, endo = heater:IsExothermic(), heater:IsEndothermic()
		if heat == nil or not (exo or endo) then
			return nil
		end
		return
		{
			states = { { heat = heat, exo = exo, endo = not exo and endo } },
			falloff = heater:ShouldFalloff(),
			cutoff = heater:GetHeatRadiusCutoff(),
		}
	end)
	if not ok then
		return false
	end
	return result
end

return Heaters
