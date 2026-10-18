-- When a Thermal Stone will change colour, as the game would compute it tick by tick (model.lua), with the
-- local temperature following the forecast (forecast.lua).
--
-- Every input known, the game's tick (current = clamp(current + rate * dt)) has one of four forms as long as
-- the same heaters count and the same cap applies:
--  * FIXED: a capped (or fridge) rate,
--  * FREE: rate = (ambient + sum - (1 + count) * current) * ratemult, an affine recurrence with an exact
--    closed form, also while the local temperature moves along a line,
--  * FLOOR / CEILING: held at the stone's minimum (a fridge's 0, if it isn't freezing outside) or maximum.
-- So whole stretches of ticks are done at once, exactly as the game would do them one by one; a stretch ends
-- where the form changes. The forecast is followed along short lines; where a line isn't precise enough
-- (around a colour change, or near 35 / a fridge's 0 where the formula switches) it is read at every tick.

local Thermal = require "iteminfo_updated/heatrock/model"

local Predict = {}

local HeatFactor, RateFromDelta = Thermal.HeatFactor, Thermal.RateFromDelta

local FIXED, FREE, FLOOR, CEILING = 1, 2, 3, 4

local MAX_SEGMENT = 8          -- seconds of local temperature taken as one line at most
local LINEAR_TOLERANCE = .05   -- degrees the forecast may stray from that line (the tick of a colour change is
                               -- then found with the forecast itself)
local MAX_SUBSTEPS = 4000      -- work limit per prediction (beyond it: no time rather than a guess)
local MAX_REFINED = 2400       -- ticks read one by one per prediction at most (a stone hovering at an edge)

-- The exact env as the numbers the formula uses (heat already scaled by distance and wetness)
local function Compile(env)
	local model =
	{
		warm = {},  -- exothermic: warming temperatures (they count while above the stone)
		cool = {},  -- endothermic: cooling temperatures (they count while below the stone)
		ratemult = env.ratemult,
		fridge_rate = env.fridge_rate,
		winter_insulation = env.winter_insulation,
		maxtemp = env.maxtemp,
	}
	for _, heater in ipairs(env.heaters) do
		if heater.unknown or #heater.states ~= 1 then
			return nil
		end
		local state = heater.states[1]
		if not state.off then
			local factor = HeatFactor(heater, heater.dsq, env.wet, state.heat)
			if factor > 0 then
				if state.exo then
					table.insert(model.warm, state.heat * factor)
				else
					local overheat = TUNING.OVERHEAT_TEMP
					table.insert(model.cool, (state.heat - overheat) * factor + overheat)
				end
			end
		end
	end
	return model
end

-- components/temperature.lua: in a fridge not below freezing, unless it's freezing outside
local function MinTemp(model, ambient)
	if model.fridge_rate ~= nil then
		return math.max(TUNING.MIN_ENTITY_TEMP, math.min(0, ambient))
	end
	return TUNING.MIN_ENTITY_TEMP
end

-- The form of the tick that starts at temperature c with local temperature a:
-- kind, then for FIXED the change per tick, for FREE the count and sum of the heaters that count
-- The game's rate (before the rate multiplier), with the heaters that count
local function GetModelRate(model, c, a, summer_insulation)
	if model.fridge_rate ~= nil then
		return model.fridge_rate
	end
	local count, sum = 0, 0
	for i = 1, #model.warm do
		local w = model.warm[i]
		if w > c then
			count, sum = count + 1, sum + w
		end
	end
	for i = 1, #model.cool do
		local w = model.cool[i]
		if w < c then
			count, sum = count + 1, sum + w
		end
	end
	local delta = a + sum - (1 + count) * c
	return RateFromDelta(a, delta, c, model.winter_insulation, summer_insulation), delta, count, sum
end

local function Classify(model, c, a, summer_insulation, tick)
	local rate, delta, count, sum = GetModelRate(model, c, a, summer_insulation)
	if delta ~= nil then
		if rate == delta and model.ratemult ~= 0 then
			local nxt = c + rate * model.ratemult * tick
			if nxt <= MinTemp(model, a) and rate < 0 then
				return FLOOR
			elseif nxt >= model.maxtemp and rate > 0 then
				return CEILING
			end
			return FREE, nil, count, sum
		end
	end
	local change = rate * model.ratemult * tick
	if change < 0 and c + change <= MinTemp(model, a) then
		return FLOOR
	elseif change > 0 and c + change >= model.maxtemp then
		return CEILING
	end
	return FIXED, change
end

-- A stretch of ticks of one form, starting at temperature c (tick 0), local temperature a + s * j and band
-- ambient b + sb * j at tick j
local Stretch = {}
Stretch.__index = Stretch

function Stretch:Set(model, kind, change, count, sum, c, a, s, b, sb, tick)
	self.model, self.kind, self.change, self.c, self.a, self.s, self.b, self.sb = model, kind, change, c, a, s, b, sb
	if kind == FREE then
		-- c(j+1) = c(j) + p * (a + s * j + sum) - q * c(j): c(j) = alpha + beta * j + (c - alpha) * rho^j
		local p = tick * model.ratemult
		local q = p * (1 + count)
		self.beta = p * s / q
		self.alpha = (p * (a + sum) - self.beta) / q
		self.rho = 1 - q
	end
end

-- Temperature after j ticks, without the stone's limits
function Stretch:Raw(j)
	local kind = self.kind
	if j == 0 then
		return self.c
	elseif kind == FIXED then
		return self.c + self.change * j
	elseif kind == FREE then
		return self.alpha + self.beta * j + (self.c - self.alpha) * self.rho ^ j
	elseif kind == FLOOR then
		return MinTemp(self.model, self.a + self.s * (j - 1))
	end
	return self.model.maxtemp
end

-- The limits the game clamps to on tick j (set from the local temperature of the tick before)
function Stretch:Floor(j)
	return MinTemp(self.model, self.a + self.s * (j - 1))
end

function Stretch:Value(j)
	if j == 0 then
		return self.c
	end
	return math.clamp(self:Raw(j), self:Floor(j), self.model.maxtemp)
end

-- The colour is checked right after each tick's update, against that tick's local temperature
function Stretch:Relative(j)
	return self:Value(j) - (self.b + self.sb * (j - 1))
end

-- Lowest and highest temperature relative to the band ambient over ticks j1..j2 (Value at j2 may be clamped)
function Stretch:RelativeBounds(j1, j2)
	local r1, r2 = self:Relative(j1), self:Relative(j2)
	local lo, hi = math.min(r1, r2), math.max(r1, r2)
	if self.kind == FREE and j2 - j1 > 1 then
		-- From j1: c - c(j1) = (alpha' - c(j1)) * (1 - rho^i) + beta * i, both parts monotone
		local c1 = self:Raw(j1)
		local L = j2 - j1
		local A = (self.alpha + self.beta * j1 - c1) * (1 - self.rho ^ L)
		local B = (self.beta - self.sb) * L
		lo = math.min(lo, r1 + math.min(0, A) + math.min(0, B))
		hi = math.max(hi, r1 + math.max(0, A) + math.max(0, B))
	elseif self.kind == FLOOR and j2 - j1 > 1 then
		-- The floor and the band ambient are each monotone over the stretch
		local f1, f2 = self:Raw(math.max(1, j1)), self:Raw(j2)
		local b1, b2 = self.b + self.sb * (j1 - 1), self.b + self.sb * (j2 - 1)
		lo = math.min(lo, math.min(f1, f2) - math.max(b1, b2))
		hi = math.max(hi, math.max(f1, f2) - math.min(b1, b2))
	end
	return lo, hi
end

-- First tick in j1+1..j2 where the stone is out of [lo_rel, hi_rel] (the colour changed), or nil
function Stretch:FirstCrossing(j1, j2, lo_rel, hi_rel)
	local lo, hi = self:RelativeBounds(j1, j2)
	if hi <= hi_rel and lo > lo_rel then
		return nil
	elseif j2 - j1 == 1 then
		local r = self:Relative(j2)
		return (r > hi_rel or r <= lo_rel) and j2 or nil
	end
	local mid = math.floor((j1 + j2) / 2)
	return self:FirstCrossing(j1, mid, lo_rel, hi_rel) or self:FirstCrossing(mid, j2, lo_rel, hi_rel)
end

-- Whether a line from a0 to a1 passes within the forecast's error of x
local function Near(a0, a1, x)
	local margin = 2 * LINEAR_TOLERANCE
	return x >= math.min(a0, a1) - margin and x <= math.max(a0, a1) + margin
end

-- First j in 1..m where test(j) is true, given test(m) is (the change happens once in a stretch)
local function FirstTrue(m, test)
	local lo, hi = 0, m
	while hi - lo > 1 do
		local mid = math.floor((lo + hi) / 2)
		if test(mid) then
			hi = mid
		else
			lo = mid
		end
	end
	return hi
end

-- Seconds until the stone changes colour, as the game would compute it tick by tick; nil when it won't
-- within the horizon. Only for exact envs (model.lua IsExact).
--   target_band: wait for that colour instead of the next one (only when the stone is heading toward it)
--   forecast: how the surroundings will change (forecast.lua), or nil when they stay as they are:
--     At(t, left) -> ambient shift, band ambient shift, summer insulation bonus (left: just before t)
--     breaks: sorted times where these jump; horizon: how far it can be followed
function Predict.BandChange(env, current, band_ambient, horizon, target_band, forecast)
	local model = Compile(env)
	if model == nil then
		return nil
	end
	local band = Thermal.GetBand(current, band_ambient)
	local lo_rel, hi_rel
	if target_band ~= nil and target_band < band then
		lo_rel, hi_rel = Thermal.THRESHOLDS[target_band], math.huge
	elseif target_band ~= nil and target_band > band then
		lo_rel, hi_rel = -math.huge, Thermal.THRESHOLDS[target_band - 1]
	else
		lo_rel, hi_rel = Thermal.GetBandRange(band, 0)
	end
	if lo_rel == -math.huge and hi_rel == math.huge then
		return nil
	end

	local function Inputs(t, left)
		if forecast == nil then
			return env.ambient, band_ambient, env.summer_insulation
		end
		local shift, band_shift, bonus = forecast.At(t, left)
		local summer = bonus ~= nil and env.summer_insulation_base + bonus or env.summer_insulation
		return env.ambient + shift, band_ambient + (band_shift or shift), summer
	end

	local tick = Thermal.GetStep()
	if forecast ~= nil and forecast.horizon ~= nil then
		horizon = math.min(horizon, forecast.horizon)
	end
	local total = math.floor(horizon / tick + 1e-6)
	local breaks = forecast ~= nil and forecast.breaks or {}
	local next_break = 1
	local segment_ticks = forecast ~= nil and math.max(1, math.floor(MAX_SEGMENT / tick)) or math.max(1, total)
	local stretch = setmetatable({}, Stretch)
	local substeps = 0
	local refined = 0 -- ticks done with the forecast read at each one

	-- The tick that first sees a jump: the first at or after it (break times carry float noise, so the values
	-- on either side of a jump are read at the break itself, not at the tick's time)
	local function FirstTick(break_time)
		return math.ceil(break_time / tick - 1e-6)
	end

	local c = current
	local i = 0
	local a0, b0, summer = Inputs(0)
	while i < total do
		while breaks[next_break] ~= nil and FirstTick(breaks[next_break]) <= i do
			a0, b0, summer = Inputs(math.max(i * tick, breaks[next_break] + 1e-6))
			next_break = next_break + 1
		end
		-- The segment: up to the next break, the work's limit, and where the forecast stops being a line
		local n = math.min(total - i, segment_ticks)
		local break_time = breaks[next_break]
		if break_time ~= nil and FirstTick(break_time) - i <= n then
			n = FirstTick(break_time) - i
		else
			break_time = nil
		end
		local a1, b1 = Inputs(break_time or (i + n) * tick, break_time ~= nil)
		while n > 1 and forecast ~= nil do
			local am, bm = Inputs((i + n / 2) * tick)
			if math.abs(am - (a0 + a1) / 2) <= LINEAR_TOLERANCE and math.abs(bm - (b0 + b1) / 2) <= LINEAR_TOLERANCE then
				break
			end
			n, break_time = math.floor(n / 2), nil
			a1, b1 = Inputs((i + n) * tick)
		end
		local s, sb = (a1 - a0) / n, (b1 - b0) / n

		-- The forecast itself read at every tick of the segment, for where the line isn't precise enough
		local function Exact(from)
			refined = refined + n
			local temp = from
			for j = 1, n do
				local a, b = Inputs((i + j - 1) * tick)
				local rate = GetModelRate(model, temp, a, summer)
				temp = math.clamp(temp + rate * model.ratemult * tick, MinTemp(model, a), model.maxtemp)
				if temp - b > hi_rel or temp - b <= lo_rel then
					return (i + j) * tick
				end
			end
			return nil, temp
		end
		-- Near a temperature where the game's formula switches (heat from 35, a fridge's floor from 0) the line
		-- would put the switch at the wrong tick
		local exact = forecast ~= nil and refined < MAX_REFINED
			and (Near(a0, a1, TUNING.STARTING_TEMP) or (model.fridge_rate ~= nil and Near(a0, a1, 0)))
		if exact then
			local crossing
			crossing, c = Exact(c)
			if crossing ~= nil then
				return crossing
			end
		end

		-- Stretches of one form within the segment
		local segment_start = c
		local k = exact and n or 0
		while k < n do
			substeps = substeps + 1
			if substeps > MAX_SUBSTEPS then
				return nil
			end
			local ak = a0 + s * k
			local kind, change, count, sum = Classify(model, c, ak, summer, tick)
			local m = n - k
			if kind == FREE and tick * model.ratemult * (1 + count) >= 1 then
				m = 1 -- (not with the game's numbers) the closed form's bounds need 0 < rho < 1
			end
			stretch:Set(model, kind, change, count, sum, c, ak, s, b0 + sb * k, sb, tick)
			-- It ends where the stone reaches one of its limits...
			if kind == FIXED or kind == FREE then
				local function Outside(j)
					local raw = stretch:Raw(j)
					return raw < stretch:Floor(j) or raw > model.maxtemp
				end
				if Outside(1) then
					m = 1 -- starting outside them (e.g. put in a fridge below 0): clamped on the first tick
				elseif Outside(m) then
					m = FirstTrue(m, Outside)
				end
			end
			-- ...or where its form changes
			local function Changed(j)
				local kind2, change2, count2, sum2 = Classify(model, stretch:Value(j), ak + s * j, summer, tick)
				return kind2 ~= kind or change2 ~= change or count2 ~= count or sum2 ~= sum
			end
			if Changed(m) then
				m = FirstTrue(m, Changed)
			end
			-- Along the forecast's line the colour changes here, or comes within the line's error of it: then the
			-- forecast itself is read at every tick of the segment (the stone and an edge can run almost side by
			-- side, where a hundredth of a degree moves the crossing by several ticks)
			local margin = (forecast ~= nil and refined < MAX_REFINED) and 2 * LINEAR_TOLERANCE or 0
			local crossing = stretch:FirstCrossing(0, m, lo_rel + margin, hi_rel - margin)
			if crossing ~= nil and forecast == nil then
				return (i + k + crossing) * tick
			elseif crossing ~= nil then
				crossing, c = Exact(segment_start)
				if crossing ~= nil then
					return crossing
				end
				k = n -- the line was off: no change in this segment after all, carry on from the exact end
			else
				c = stretch:Value(m)
				k = k + m
			end
		end

		i = i + n
		a0, b0 = a1, b1 -- after a break: replaced at the top of the loop
	end
	return nil
end

return Predict
