-- Thermal Stone temperature model: components/temperature.lua OnUpdate and prefabs/heatrock.lua,
-- fed only with what a client can see.
--
-- Nothing here is guessed: when a heat source's strength can't be known on a client (hot springs,
-- cave vents, WX-78's modules, modded heaters...), its possible values are used as bounds instead,
-- so the tracker (tracker.lua) keeps a range that always contains the real temperature.
--
-- Things that do NOT change the stone's temperature (checked in the game code): the holder's own
-- temperature, clothing and food (only the eater's temperature), other Thermal Stones and fumarole
-- tools (the stone ignores the "heatrock" tag), and anything that is itself inside an inventory.

local Heaters = require "iteminfo_updated/heatrock/heaters"
local Upvalue = require "iteminfo_updated/upvalue"

local Thermal = {}

-- The game's own values replace these once the world is loaded (ReadGameValues)
Thermal.HEATER_RANGE = 10 -- components/temperature.lua ZERO_DISTANCE
local HEATER_RANGE_SQ = Thermal.HEATER_RANGE * Thermal.HEATER_RANGE

-- prefabs/heatrock.lua relative_temperature_thresholds: the colour bands, relative to the local temperature
Thermal.THRESHOLDS = { -30, -10, 10, 30 }

-- Takes the values above from the game itself where it keeps them (prefabs/heatrock.lua, components/temperature.lua),
-- so a change there is followed; anything unreadable or of another shape keeps the value above
function Thermal.ReadGameValues()
	local thresholds = Upvalue.Find(Upvalue.PrefabFn("heatrock"), "relative_temperature_thresholds", 3)
	thresholds = Upvalue.Numbers(thresholds, #Thermal.THRESHOLDS, true)
	if thresholds ~= nil then
		for i, threshold in ipairs(thresholds) do
			Thermal.THRESHOLDS[i] = threshold
		end
	end
	local ok, Temperature = pcall(require, "components/temperature")
	local range = ok and Upvalue.FindIn(Temperature, "ZERO_DISTANCE", 1) or nil
	if type(range) == "number" and range > 0 then
		Thermal.HEATER_RANGE, HEATER_RANGE_SQ = range, range * range
	end
end

-- Stategraph frames (FRAMES)
Thermal.FRAME = 1 / 30

-- update.lua Update(dt): components (the stone's temperature) are updated once per simulation tick
function Thermal.GetStep()
	local GetTickTime = rawget(_G, "GetTickTime")
	if GetTickTime ~= nil then
		local ok, tick = pcall(GetTickTime)
		if ok and type(tick) == "number" and tick > 0 then
			return math.clamp(tick, 1 / 120, .25)
		end
	end
	return Thermal.FRAME
end

--------------------------------------------------------------------------
-- Bands

function Thermal.GetBand(temp, ambient)
	local band = 1
	for _, threshold in ipairs(Thermal.THRESHOLDS) do
		if temp > ambient + threshold then
			band = band + 1
		end
	end
	return band
end

-- Temperatures a band allows: above the lower threshold, up to and including the upper one
function Thermal.GetBandRange(band, ambient)
	local lo = band > 1 and ambient + Thermal.THRESHOLDS[band - 1] or -math.huge
	local hi = band < 5 and ambient + Thermal.THRESHOLDS[band] or math.huge
	return lo, hi
end

--------------------------------------------------------------------------
-- The game's formula (components/temperature.lua OnUpdate)

-- How strongly a heater at distance² dsq acts on the stone (0: not at all)
local function HeatFactor(heater, dsq, wet, heat)
	if heater.cutoff ~= nil and dsq > heater.cutoff * heater.cutoff then
		return 0
	end
	local factor = heater.falloff and 1 - dsq / HEATER_RANGE_SQ or 1
	if factor <= 0 then
		return 0
	end
	if wet then
		local penalty = TUNING.WET_HEAT_FACTOR_PENALTY
		if heat > 0 then
			factor = factor * penalty
		elseif penalty ~= 0 then
			factor = factor / penalty
		end
	end
	return factor
end

-- What one heater state adds to the temperature the stone is heading to
local function Contribution(state, heater, wet, current)
	if state.off then
		return 0
	end
	local factor = HeatFactor(heater, heater.dsq, wet, state.heat)
	if factor <= 0 then
		return 0
	end
	if state.exo then
		local warming = state.heat * factor -- relative to 0 (freezing)
		return warming > current and warming - current or 0
	end
	local overheat = TUNING.OVERHEAT_TEMP
	local cooling = (state.heat - overheat) * factor + overheat -- relative to the overheat temperature
	return cooling < current and cooling - current or 0
end

-- The insulation decides how fast the stone follows where it is heading: in the cold only cooling is
-- slowed, in the heat only warming (the stone's own INSULATION_MED; dusk and night add summer insulation
-- above ground). Degrees per second, before the container's rate multiplier.
local function RateFromDelta(ambient, delta, current, winter_insulation, summer_insulation)
	local seg = TUNING.SEG_TIME
	if ambient >= TUNING.STARTING_TEMP then
		if delta > 0 then
			return math.min(delta, seg / (seg + summer_insulation))
		end
		return math.max(delta, current >= TUNING.OVERHEAT_TEMP and -TUNING.THAW_DEGREES_PER_SEC or -TUNING.WARM_DEGREES_PER_SEC)
	elseif delta < 0 then
		return math.max(delta, -seg / (seg + winter_insulation))
	end
	return math.min(delta, current <= 0 and TUNING.THAW_DEGREES_PER_SEC or TUNING.WARM_DEGREES_PER_SEC)
end

Thermal.HeatFactor, Thermal.RateFromDelta = HeatFactor, RateFromDelta -- for predict.lua

-- Degrees per second at the given temperature. bound = "lo" or "hi": the slowest / fastest the
-- stone can change with the sources whose state is unknown (for an exact env both are the same).
function Thermal.GetRate(env, current, bound)
	if env.fridge_rate ~= nil then
		return env.fridge_rate * env.ratemult
	end
	local hi = bound == "hi"
	local delta = env.ambient - current
	for _, heater in ipairs(env.heaters) do
		if heater.unknown then
			delta = hi and math.huge or -math.huge
			break
		end
		local best = nil
		for _, state in ipairs(heater.states) do
			local value = Contribution(state, heater, env.wet, current)
			if best == nil or (hi and value > best) or (not hi and value < best) then
				best = value
			end
		end
		delta = delta + (best or 0)
	end
	return RateFromDelta(env.ambient, delta, current, env.winter_insulation, env.summer_insulation) * env.ratemult
end

local function Step(env, current, dt, bound)
	return math.clamp(current + Thermal.GetRate(env, current, bound) * dt, env.mintemp, env.maxtemp)
end

-- Advances a temperature by dt seconds, tick by tick like the game
function Thermal.Advance(env, current, dt, bound)
	local tick = Thermal.GetStep()
	while dt > 1e-6 do
		local step = math.min(tick, dt)
		current = Step(env, current, step, bound)
		dt = dt - step
	end
	return current
end

-- The game's tick isn't monotone at two temperatures: warming in the cold is faster at or below 0, cooling
-- in the heat faster at or above OVERHEAT_TEMP, so a stone just above 0 can end a tick colder than one at
-- 0. Both sides of those points are followed too while they are inside the range.
local KINK = 1e-6
local function GetKinks()
	local overheat = TUNING.OVERHEAT_TEMP
	return { 0, KINK, overheat - KINK, overheat }
end

-- Advances a range [lo, hi] by dt seconds so it keeps containing every temperature it contained
function Thermal.AdvanceRange(env, lo, hi, dt)
	local tick = Thermal.GetStep()
	local kinks = GetKinks()
	while dt > 1e-6 do
		local step = math.min(tick, dt)
		local new_lo, new_hi = Step(env, lo, step, "lo"), Step(env, hi, step, "hi")
		for _, kink in ipairs(kinks) do
			if kink > lo and kink < hi then
				new_lo = math.min(new_lo, Step(env, kink, step, "lo"))
				new_hi = math.max(new_hi, Step(env, kink, step, "hi"))
			end
		end
		lo, hi = new_lo, new_hi
		dt = dt - step
	end
	return lo, hi
end

-- True when every input is known exactly, so predictions can be made
function Thermal.IsExact(env)
	for _, heater in ipairs(env.heaters) do
		if heater.unknown or #heater.states ~= 1 then
			return false
		end
	end
	return true
end

--------------------------------------------------------------------------
-- What the client sees of the stone's surroundings

local DEFAULT_LATENCY = .3 -- seconds a colour change may take to reach the client, when the ping is unknown

-- components/temperatureoverrider.lua GetTemperatureAtXZ (overriders, fumarole area), defined only once that
-- file is loaded (strict mode: rawget); prefabs/heatrock.lua GetLocalTemperature
function Thermal.GetLocalTemperature(x, z)
	local GetTemperatureAtXZ = rawget(_G, "GetTemperatureAtXZ")
	if GetTemperatureAtXZ ~= nil then
		local ok, temp = pcall(GetTemperatureAtXZ, x, z)
		if ok and type(temp) == "number" then
			return temp
		end
	end
	return TheWorld.state.temperature
end

-- temperature.lua GetInsulation: dusk and night add summer insulation above ground
function Thermal.GetSummerInsulationBonus()
	if TheWorld:HasTag("cave") then
		return 0
	elseif TheWorld.state.isdusk then
		return TUNING.DUSK_INSULATION_BONUS
	elseif TheWorld.state.isnight then
		return TUNING.NIGHT_INSULATION_BONUS
	end
	return 0
end

function Thermal.IsHeld(ent)
	return ent.replica ~= nil and ent.replica.inventoryitem ~= nil and ent.replica.inventoryitem:IsHeld()
end

-- How long ago, at most, the server changed what we just received: half the round trip, the server's next
-- network update (tick_rate 15: up to 2 frames) and a client frame
function Thermal.GetLatency()
	if TheWorld.ismastersim then
		return 0
	end
	local ok, ping = pcall(TheNet.GetAveragePing, TheNet)
	if ok and type(ping) == "number" and ping >= 0 then
		return math.min(1, ping / 2000 + 3 * Thermal.FRAME)
	end
	return DEFAULT_LATENCY
end

--------------------------------------------------------------------------
-- Inputs

-- Builds the inputs for a stone at (x, z).
--   heaters: heaters around, as { ent, dsq } (found by the tracker, so this stays testable)
--   observer: the stone itself on hosts, to read the heaters' real components
--   context: { GetFireLightRadius(fire) } for what only the tracker can find (a fire's light)
function Thermal.BuildEnv(params)
	local env =
	{
		ambient = params.ambient,
		mintemp = TUNING.MIN_ENTITY_TEMP,
		maxtemp = TUNING.MAX_ENTITY_TEMP,
		ratemult = params.ratemult or 1,
		wet = params.wet == true,
		heaters = {},
		-- prefabs/heatrock.lua: INSULATION_MED both ways; temperature.lua GetInsulation adds the
		-- dusk / night bonus to summer insulation above ground
		winter_insulation = TUNING.INSULATION_MED,
		summer_insulation_base = TUNING.INSULATION_MED,
		summer_insulation = TUNING.INSULATION_MED + (params.summer_insulation_bonus or 0),
	}
	if params.fridge then
		-- Inside a fridge: a fixed cooling rate, not below freezing unless it's freezing outside
		env.mintemp = math.max(env.mintemp, math.min(0, params.ambient))
		env.fridge_rate = params.lowcool and -.5 * TUNING.WARM_DEGREES_PER_SEC or -TUNING.WARM_DEGREES_PER_SEC
		return env
	end
	for _, found in ipairs(params.heaters or {}) do
		local heater = false
		if params.observer ~= nil then
			heater = Heaters.DescribeLive(found.ent, params.observer)
		end
		if heater == false then
			heater = Heaters.Describe(found.ent, found.dsq, params.context)
		end
		if heater ~= nil then
			heater.dsq = found.dsq
			table.insert(env.heaters, heater)
		end
	end
	return env
end


return Thermal
