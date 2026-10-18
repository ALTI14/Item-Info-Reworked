-- Forecast of the local temperature around a Thermal Stone, for the countdown (predict.lua).
--
-- components/worldtemperature.lua CalculateTemperature, which the client runs too:
--   ((noise + season + day / night) - locus) * mult + locus
--  * noise: 2 * mag * perlin(0, 0, noisetime * scale) - mag, the noise time running with the game's time
--  * season: CalculateSeasonTemperature(season, progress), which changes only when a new day starts
--    (components/seasons.lua OnAdvanceSeason: a day less, or the next season)
--  * day / night: CalculatePhaseTemperature(phase, time in phase), on the clock's schedule
--  * mult, locus: the caves' damping (SetTemperatureMod)
-- Values and functions are read from the components themselves (Lua upvalues, and the functions they
-- registered for world events), and the forecast is only used when it gives the current temperature back.
-- The fumarole area (components/fumarolelocaltemperature.lua) blends in its own formula of the same kind;
-- temperature overriders (the sentry ward) are constant. Dusk and night add summer insulation above ground.
-- Not knowable on a client: how the next day's day / dusk / night split changes (seasons.lua
-- PushSeasonClockSegs uses world settings only the server has), so the current split is kept.

local Thermal = require "iteminfo_updated/heatrock/model"
local Upvalue = require "iteminfo_updated/upvalue"

local Forecast = {}

local PHASE_NAMES = { "day", "dusk", "night" }                 -- components/clock.lua
local PHASE_TEMPERATURES = { day = 5, night = -6 }            -- worldtemperature.lua, when its function can't be read
local SEASON_NAMES = { "autumn", "winter", "spring", "summer" } -- components/seasons.lua
local ENDLESS_RAMP_DAYS = 10 -- seasons.lua: an endless season climbs to its peak over 2 x 10 days
local MAX_SEASON_DAYS = 255  -- net_byte: more days left than this is how an endless season is shown
local MATCH = .01            -- a formula has to give the game's current value back this closely

local GetUpvalue = Upvalue.Get

-- A function a component of the world's network entity uses for a world event, found by one of its
-- upvalues and recognised by accept(fn)
local function FindListenerUpvalue(event, name, accept)
	local listening = TheWorld.net.event_listening
	local fns = listening ~= nil and listening[event] ~= nil and listening[event][TheWorld] or nil
	for _, fn in ipairs(fns or {}) do
		local found = GetUpvalue(fn, name)
		if type(found) == "function" then
			local ok, accepted = pcall(accept, found)
			if ok and accepted then
				return found
			end
		end
	end
end

-- A temperature component's CalculateTemperature and the fixed values it uses
local function ReadFormula(component)
	if component == nil then
		return nil
	end
	local calc = Upvalue.Find(component.OnUpdate, "CalculateTemperature", 2) -- (worldtemperature: via PushTemperature)
	local noisetime = GetUpvalue(calc, "_noisetime")
	local scale, mag = GetUpvalue(calc, "TEMPERATURE_NOISE_SCALE"), GetUpvalue(calc, "TEMPERATURE_NOISE_MAG")
	if calc == nil or noisetime == nil or type(scale) ~= "number" or type(mag) ~= "number" then
		return nil
	end
	return { calc = calc, noisetime = noisetime, scale = scale, mag = mag }
end

-- The values it uses that change: the season part, mult, locus
local function ReadFormulaState(formula)
	local season = GetUpvalue(formula.calc, "_seasontemperature")
	local mult = GetUpvalue(formula.calc, "_globaltemperaturemult")
	local locus = GetUpvalue(formula.calc, "_globaltemperaturelocus")
	if type(season) == "number" and type(mult) == "number" and type(locus) == "number" then
		return season, mult, locus
	end
end

local formulas = nil -- { net, world, fumarole }: what could be read, for the current world

local function GetFormulas()
	local net = TheWorld.net
	if net == nil then
		return nil
	end
	if formulas == nil or formulas.net ~= net then
		local ok, result = pcall(function()
			return
			{
				net = net,
				world = ReadFormula(net.components.worldtemperature),
				fumarole = ReadFormula(net.components.fumarolelocaltemperature),
			}
		end)
		formulas = ok and result or { net = net }
	end
	return formulas
end

-- The component's CalculateSeasonTemperature (what its seasontick listener uses), recognised by giving its
-- current season part back; nil until it can be
local function GetSeasonFunction(formula, season_now)
	local state = TheWorld.state
	local function Matches(fn)
		return math.abs(fn(state.season, state.seasonprogress) - season_now) < MATCH
	end
	if formula.season_fn == nil then
		formula.season_fn = FindListenerUpvalue("seasontick", "CalculateSeasonTemperature", Matches)
	end
	local fn = formula.season_fn
	return fn ~= nil and Matches(fn) and fn or nil
end

local function DefaultPhaseTemperature(phase, timeinphase)
	local swing = PHASE_TEMPERATURES[phase]
	return swing ~= nil and swing * math.sin(timeinphase * PI) or 0
end

-- worldtemperature.lua CalculatePhaseTemperature (what its clocktick listener uses)
local function GetPhaseFunction(formula, phase, timeinphase, phase_now)
	if formula.phase_fn == nil then
		formula.phase_fn = FindListenerUpvalue("clocktick", "CalculatePhaseTemperature", function(fn)
			return math.abs(fn(phase, timeinphase) - phase_now) < MATCH
		end) or false
	end
	return formula.phase_fn or DefaultPhaseTemperature
end

-- Today, as components/seasons.lua tells clients: the season, its progress and days left
local function GetToday()
	local state = TheWorld.state
	local season, progress, remaining = state.season, state.seasonprogress, state.remainingdaysinseason
	if type(season) ~= "string" or type(progress) ~= "number" or type(remaining) ~= "number" then
		return nil
	elseif remaining > MAX_SEASON_DAYS then
		return { season = season, progress = progress, endless = true }
	end
	local total = progress < 1 and math.floor(remaining / (1 - progress) + .5) or remaining
	return { season = season, progress = progress, remaining = remaining, total = total }
end

-- The day after: seasons.lua OnAdvanceSeason (one day less, or GetNextSeason), UpdateSeasonMode (a single
-- season with days becomes endless once reached; an endless one climbs to its peak and stays there)
local function GetNextDay(day)
	local state = TheWorld.state
	if day.endless then
		local total = 2 * ENDLESS_RAMP_DAYS
		local remaining = math.floor((1 - day.progress) * total + .5)
		if remaining > ENDLESS_RAMP_DAYS then
			remaining = remaining - 1
		end
		return { season = day.season, progress = 1 - remaining / total, endless = true }
	elseif day.remaining > 1 then
		local remaining = day.remaining - 1
		return { season = day.season, remaining = remaining, total = day.total, progress = 1 - remaining / day.total }
	end
	local function Length(name)
		local length = state[name.."length"]
		return type(length) == "number" and length or 0
	end
	local current, active = nil, 0
	for i, name in ipairs(SEASON_NAMES) do
		if name == day.season then
			current = i
		end
		if Length(name) > 0 then
			active = active + 1
		end
	end
	if current == nil then
		return nil -- a season added by a mod
	end
	local season = day.season
	for k = 1, #SEASON_NAMES do
		local name = SEASON_NAMES[(current + k - 1) % #SEASON_NAMES + 1]
		if Length(name) > 0 or name == day.season then
			season = name
			break
		end
	end
	if active == 1 and season ~= day.season then
		return { season = season, progress = 0, endless = true }
	end
	local total = Length(season)
	return { season = season, remaining = total, total = total, progress = total > 0 and 0 or 1 }
end

-- Seconds of each phase (PHASE_NAMES order), from the clock's segments (clock.lua _segs); nil if unreadable
local function ReadPhaseLengths(clock)
	local segs = GetUpvalue(clock.GetTimeUntilPhase, "_segs")
	if type(segs) ~= "table" then
		return nil
	end
	local lengths, total = {}, 0
	for i = 1, #PHASE_NAMES do
		local ok, value = pcall(function() return segs[i]:value() end)
		if not ok or type(value) ~= "number" or value < 0 then
			return nil
		end
		lengths[i] = value * TUNING.SEG_TIME
		total = total + lengths[i]
	end
	return total > 0 and lengths or nil
end

-- The clock's day from now on: the current phase and the next two, { name, start, length } with start in
-- seconds from now (the current phase's is in the past), and the day's length; every day repeats it
local function ReadSchedule()
	local clock = TheWorld.net.components.clock
	local state = TheWorld.state
	-- worldstate.lua: in the caves "phase" stays "night", the clock's phase is "cavephase"
	local phase = TheWorld:HasTag("cave") and state.cavephase or state.phase
	local timeinphase = state.timeinphase
	if clock == nil or clock.GetTimeUntilPhase == nil or type(timeinphase) ~= "number" or timeinphase < 0 or timeinphase >= 1 then
		return nil
	end
	local current = nil
	for i, name in ipairs(PHASE_NAMES) do
		if name == phase then
			current = i
		end
	end
	if current == nil then
		return nil
	end
	local function Index(k) return (current + k - 1) % #PHASE_NAMES + 1 end
	-- GetTimeUntilPhase: the time left in this phase for the next one, plus the phases in between after that
	local remaining = clock:GetTimeUntilPhase(PHASE_NAMES[Index(1)])
	if type(remaining) ~= "number" or remaining < 0 then
		return nil
	end
	local lengths = ReadPhaseLengths(clock)
	if lengths == nil then
		-- From the time in phase (less precise right at a phase's end)
		local after = clock:GetTimeUntilPhase(PHASE_NAMES[Index(2)])
		if type(after) ~= "number" or after < remaining then
			return nil
		end
		lengths = {}
		lengths[current] = remaining / (1 - timeinphase)
		lengths[Index(1)] = after - remaining
		lengths[Index(2)] = math.max(0, TUNING.TOTAL_DAY_TIME - lengths[current] - lengths[Index(1)])
	end
	local schedule = { day = 0 }
	local start = remaining - lengths[current]
	for k = 0, #PHASE_NAMES - 1 do
		local index = Index(k)
		schedule[k + 1] = { name = PHASE_NAMES[index], start = start, length = lengths[index] }
		start = start + lengths[index]
		schedule.day = schedule.day + lengths[index]
	end
	return schedule
end

-- Phase and time in it (0-1) t seconds from now (left: just before t)
local function PhaseAt(schedule, t, left)
	if left then
		t = t - 1e-6
	end
	local day = schedule.day
	local origin = schedule[1].start
	local at = t - math.floor((t - origin) / day) * day
	local last = schedule[1]
	for _, p in ipairs(schedule) do
		if p.length > 0 then
			if at < p.start + p.length then
				return p.name, math.clamp((at - p.start) / p.length, 0, 1)
			end
			last = p
		end
	end
	return last.name, 1
end

-- Phase starts in (0, horizon] (sorted), and which of them start a new day
local function GetPhaseStarts(schedule, horizon)
	local day = schedule.day
	local starts, day_starts = {}, {}
	for d = 0, math.ceil(horizon / day) + 1 do
		for _, p in ipairs(schedule) do
			local start = p.start + d * day
			if start > 0 and start <= horizon then
				table.insert(starts, start)
				if p.name == PHASE_NAMES[1] then
					table.insert(day_starts, start) -- clock.lua: a cycle completes when the phase wraps to day
				end
			end
		end
	end
	table.sort(starts)
	table.sort(day_starts)
	return starts, day_starts
end

-- How the temperatures around a stone at (x, z) will move, for predict.lua; nil when it can't
-- be followed (then they count as constant). pocket: the stone heads to the world temperature (pocket
-- dimension containers). offset: the forecast's time 0 in seconds from now (when the stone was last read).
function Forecast.Build(x, z, pocket, offset, horizon)
	local found = GetFormulas()
	local world = found ~= nil and found.world or nil
	if world == nil then
		return nil
	end
	local state = TheWorld.state
	local season_now, mult, locus = ReadFormulaState(world)
	local phase_now = GetUpvalue(world.calc, "_phasetemperature")
	local schedule = ReadSchedule()
	if season_now == nil or type(phase_now) ~= "number" or schedule == nil then
		return nil
	end
	local PhaseTemperature = GetPhaseFunction(world, schedule[1].name, state.timeinphase, phase_now)
	if math.abs(PhaseTemperature(schedule[1].name, state.timeinphase) - phase_now) >= MATCH then
		return nil
	end

	-- Season parts per day from now (1 = today), as far as the days can be followed
	local span = horizon + offset
	local phase_starts, day_starts = GetPhaseStarts(schedule, span)
	local days = { GetToday() }
	local known = days[1] ~= nil and #day_starts or 0
	for d = 1, known do
		days[d + 1] = GetNextDay(days[d])
		if days[d + 1] == nil then
			known = d - 1
			break
		end
	end
	local function SeasonParts(formula, now)
		local fn = GetSeasonFunction(formula, now)
		local parts = { now }
		if fn == nil then
			return parts, 0
		end
		for d = 1, known do
			parts[d + 1] = fn(days[d + 1].season, days[d + 1].progress)
		end
		return parts, known
	end
	local world_seasons, followed = SeasonParts(world, season_now)

	local function DayIndex(t, left)
		local index = 1
		for _, start in ipairs(day_starts) do
			if start < t or (not left and start == t) then
				index = index + 1
			end
		end
		return index
	end
	local function Noise(formula, noise_now, t)
		return 2 * formula.mag * perlin(0, 0, (noise_now + t) * formula.scale) - formula.mag
	end
	local world_noise = world.noisetime:value()
	local function World(t, left)
		local name, timeinphase = PhaseAt(schedule, t, left)
		local season = world_seasons[math.min(DayIndex(t, left), followed + 1)]
		return ((Noise(world, world_noise, t) + season + PhaseTemperature(name, timeinphase)) - locus) * mult + locus
	end
	if math.abs(World(0) - state.temperature) >= MATCH then
		return nil
	end

	-- Where the stone is: the world's temperature, the fumarole area's blend, or an overrider's
	local Local = World
	local here = Thermal.GetLocalTemperature(x, z)
	if math.abs(here - state.temperature) >= .001 then
		local component = TheWorld.net.components.fumarolelocaltemperature
		local in_fumarole = component ~= nil and component:GetTemperatureAtXZ(x, z) or nil
		if in_fumarole ~= nil and math.abs(in_fumarole - here) < .001 then
			-- Lerp(world, fumarole, share of fumarole tiles around)
			local fumarole = found.fumarole
			local fumarole_now = component:GetTemperature()
			local f_season, f_mult, f_locus
			if fumarole ~= nil then
				f_season, f_mult, f_locus = ReadFormulaState(fumarole)
			end
			if f_season == nil or type(fumarole_now) ~= "number" or math.abs(fumarole_now - state.temperature) < MATCH then
				return nil
			end
			local f_seasons, f_followed = SeasonParts(fumarole, f_season)
			followed = math.min(followed, f_followed)
			local f_noise = fumarole.noisetime:value()
			local function Fumarole(t, left)
				local season = f_seasons[math.min(DayIndex(t, left), followed + 1)]
				return ((Noise(fumarole, f_noise, t) + season) - f_locus) * f_mult + f_locus
			end
			local share = (here - state.temperature) / (fumarole_now - state.temperature)
			if share <= 0 or share > 1 or math.abs(Fumarole(0) - fumarole_now) >= MATCH then
				return nil
			end
			Local = function(t, left)
				local w = World(t, left)
				return w + (Fumarole(t, left) - w) * share
			end
		else
			Local = function() return here end
		end
	end

	local cave = TheWorld:HasTag("cave")
	local function SummerBonus(t, left)
		if cave then
			return 0
		end
		local name = PhaseAt(schedule, t, left)
		return (name == "dusk" and TUNING.DUSK_INSULATION_BONUS) or (name == "night" and TUNING.NIGHT_INSULATION_BONUS) or 0
	end

	local band_start = Local(offset)
	local ambient_start = pocket and World(offset) or band_start
	local breaks = {}
	for _, start in ipairs(phase_starts) do
		if start > offset then
			table.insert(breaks, start - offset)
		end
	end
	-- Past the first day whose season part isn't known, the stone can't be followed
	local limit = day_starts[followed + 1]
	return
	{
		At = function(t, left)
			local at = t + offset
			local band = Local(at, left)
			local ambient = pocket and World(at, left) or band
			return ambient - ambient_start, band - band_start, SummerBonus(at, left)
		end,
		breaks = breaks,
		horizon = limit ~= nil and limit - offset or nil,
	}
end

return Forecast
