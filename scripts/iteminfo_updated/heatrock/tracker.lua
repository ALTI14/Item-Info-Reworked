-- Follows the temperature of every Thermal Stone the player can see (inventory, open containers,
-- on the ground nearby), so the tooltip can show it.
--
-- Clients are only told the stone's colour band (the inventory image / ground animation). The
-- tracker keeps, per stone, a range [lo, hi] that always contains the real temperature:
--  * it starts as the whole band,
--  * each game tick both ends follow the game's own formula (model.lua), lo with the coldest
--    and hi with the warmest values the surroundings can have,
--  * the moment the colour changes, the temperature is exactly on that band edge: the range
--    collapses to a single value, which the model then follows precisely,
--  * the band clips the range; if the two disagree (the colour arrives a little late), both stay possible,
--  * a few effects cool stones lying on the ground instantly (coolings.lua): the cold end drops by their
--    amount (they never warm a stone),
--  * stones in a container that gets closed keep being simulated while nobody else can have opened it.
-- Hosts of worlds without caves read the real temperature instead. The countdown: predict.lua, forecast.lua.

local Thermal = require "iteminfo_updated/heatrock/model"
local Predict = require "iteminfo_updated/heatrock/predict"
local Forecast = require "iteminfo_updated/heatrock/forecast"
local Coolings = require "iteminfo_updated/heatrock/coolings"

local Heatrock = {}

local TICK = .1
local MAX_GAP = 1           -- seconds without an update after which a stone starts over from its band
local GROUND_RANGE = 20     -- ground stones tracked around the player
local PRECISE = 2           -- ranges at most this wide are shown as one value
local PREDICT_HORIZON = 960 -- seconds (two days)
local PREDICT_INTERVAL = .5
local STEADY_TOLERANCE = 1  -- seconds: a new prediction this close to the running countdown keeps it running
local AMBIENT_JUMP = .5     -- a local temperature change this big in one update is a jump (e.g. an overrider's area)

local HEATER_MUST_TAGS = { "HASHEATER" }
local HEATER_CANT_TAGS = { "INLIMBO", "heatrock" } -- components/temperature.lua ignoreheatertags + prefabs/heatrock.lua IgnoreTags
local STONE_MUST_TAGS = { "heatrock" }
local STONE_CANT_TAGS = { "INLIMBO" }
local PLAYER_TAGS = { "player" }

local states = setmetatable({}, { __mode = "k" })
local listened = setmetatable({}, { __mode = "k" }) -- held stones whose colour changes we hear instantly

-- Closed containers: a client stops seeing what's inside, but nothing can leave or enter a closed
-- container without someone opening it, which needs a player next to it (Wobot only adds items). While no
-- other player comes near, the stones inside keep being simulated and are picked up again (same slot) when
-- it is reopened.
local SEAL_REACH = 6        -- other players this close may have opened it
local open_last = setmetatable({}, { __mode = "k" }) -- container -> { [slot] = stone } seen open last tick
local sealed = setmetatable({}, { __mode = "k" })    -- container -> { [slot] = state }

-- Entities registered by modmain.lua (prefab post inits), all networked
local lights = setmetatable({}, { __mode = "k" })      -- heatrocklight: a stone's light
local fire_lights = setmetatable({}, { __mode = "k" }) -- firefx_light: a fire's light (components/firefx.lua)

-- Filled once per tick (Heatrock.Update) and dropped after it
local tick_cache = nil

local failed = false

local function LogError(err)
	if not failed then
		failed = true
		print("[Item Info Reworked] Thermal Stone tracker error: "..tostring(err))
	end
end

--------------------------------------------------------------------------
-- What the client can see

-- Inventory image (prefabs/heatrock.lua UpdateImages: "<skin or heat_rock><band>")
local function GetHeldBand(item)
	local inventoryitem = item.replica.inventoryitem
	local image = inventoryitem ~= nil and inventoryitem:GetImage() or nil
	if image == nil then
		return nil
	end
	local skin = item:GetSkinName() or "heat_rock"
	for band = 1, 5 do
		local name = skin..band..".tex"
		if image == name or image == hash(name) then
			return band
		end
	end
end

-- Ground animation: AnimState:PlayAnimation(tostring(range))
local function GetGroundBand(item)
	if item.AnimState == nil then
		return nil
	end
	for band = 1, 5 do
		if item.AnimState:IsCurrentAnimation(tostring(band)) then
			return band
		end
	end
end

local function IsPocket(holder)
	return holder ~= nil and holder:HasTag("pocketdimension_container")
end

--------------------------------------------------------------------------
-- Surroundings

-- Heaters around a point (several stones at one spot, e.g. a whole inventory, share one search per tick)
local function FindHeaters(x, y, z)
	local key = tick_cache ~= nil and string.format("%.2f,%.2f", x, z) or nil
	if key ~= nil and tick_cache.heaters[key] ~= nil then
		return tick_cache.heaters[key]
	end
	local heaters = {}
	for _, ent in ipairs(TheSim:FindEntities(x, y, z, Thermal.HEATER_RANGE, HEATER_MUST_TAGS, HEATER_CANT_TAGS)) do
		if not Thermal.IsHeld(ent) and not ent:IsInLimbo() then
			local ex, _, ez = ent.Transform:GetWorldPosition()
			local dx, dz = ex - x, ez - z
			table.insert(heaters, { ent = ent, dsq = dx * dx + dz * dz })
		end
	end
	if key ~= nil then
		tick_cache.heaters[key] = heaters
	end
	return heaters
end

function Heatrock.RegisterFireLight(inst)
	fire_lights[inst] = true
end

Heatrock.RegisterIceCircle = Coolings.RegisterIceCircle -- sentry ward ice (coolings.lua)

-- The radius of the light a fire owns (parented to the fire, unless it was attached to something else)
local function GetFireLightRadius(fire)
	local by_parent = tick_cache ~= nil and tick_cache.fire_lights or nil
	if by_parent == nil then
		by_parent = {}
		for light in pairs(fire_lights) do
			if light:IsValid() and light.Light ~= nil then
				local ok, parent = pcall(light.entity.GetParent, light.entity)
				if ok and parent ~= nil then
					by_parent[parent] = light
				end
			end
		end
		if tick_cache ~= nil then
			tick_cache.fire_lights = by_parent
		end
	end
	local light = by_parent[fire]
	if light == nil then
		return nil
	end
	local ok, radius = pcall(light.Light.GetRadius, light.Light)
	return ok and type(radius) == "number" and radius or nil
end
local CONTEXT = { GetFireLightRadius = GetFireLightRadius }

-- The surroundings of a stone, as components/temperature.lua sees them
-- wet: given for stones that aren't visible (in a closed container), else read from the stone
local function BuildEnv(item, holder, x, y, z, live, wet)
	local pocket = IsPocket(holder)
	local band_ambient = Thermal.GetLocalTemperature(x, z) -- prefabs/heatrock.lua GetLocalTemperature
	local container = holder ~= nil and holder.replica.container or nil
	if wet == nil then
		wet = item.replica.inventoryitem ~= nil and item.replica.inventoryitem:IsWet()
	end
	local env = Thermal.BuildEnv({
		ambient = pocket and TheWorld.state.temperature or band_ambient,
		-- components/container.lua: read-only containers stop the temperature (preserver rate 0)
		ratemult = container ~= nil and container:IsReadOnlyContainer() and 0 or 1,
		wet = wet == true,
		fridge = holder ~= nil and holder:HasTag("fridge") and not holder:HasTag("nocool"),
		lowcool = holder ~= nil and holder:HasTag("lowcool"),
		summer_insulation_bonus = Thermal.GetSummerInsulationBonus(),
		heaters = not pocket and FindHeaters(x, y, z) or nil,
		-- Hosts read the heaters' real components
		observer = live and item or nil,
		context = CONTEXT,
	})
	return env, band_ambient
end

-- Where a container's contents are: pocket dimension containers (Magician's Chest, Shadow Chester) keep
-- their own fixed spot; carried or worn containers are at the player; others where they stand
local function GetContainerPosition(container, owner)
	if IsPocket(container) or not container:IsInLimbo() then
		return container.Transform:GetWorldPosition()
	end
	return owner.Transform:GetWorldPosition()
end

--------------------------------------------------------------------------
-- The stone's light (prefabs/heatrock.lua AdjustLighting, every frame): in the hottest band its intensity
-- is .5 * (temp - ambient - 30) / 50, up to .5. A second reading for hot stones, used only when the light
-- can be matched to one stone without doubt (and when the engine lets us read it).

function Heatrock.RegisterLight(inst)
	lights[inst] = true
end

local function GetLightIntensity(light)
	local ok, enabled = pcall(light.Light.IsEnabled, light.Light)
	if not ok or not enabled then
		return nil
	end
	local ok2, intensity = pcall(light.Light.GetIntensity, light.Light)
	return ok2 and type(intensity) == "number" and intensity or nil
end

-- Lights by the entity they are attached to (the stone on the ground, else its top holder)
local function GetLightsByParent()
	local by_parent = {}
	for light in pairs(lights) do
		if light:IsValid() and light.Light ~= nil then
			local ok, parent = pcall(light.entity.GetParent, light.entity)
			if ok and parent ~= nil then
				local list = by_parent[parent] or {}
				table.insert(list, light)
				by_parent[parent] = list
			end
		end
	end
	return by_parent
end

-- The light's reading is combined with the range; if they disagree, both stay possible
local function ApplyLight(lo, hi, intensity, band_ambient)
	local base = band_ambient + Thermal.THRESHOLDS[4]
	local light_lo, light_hi
	if intensity >= .499 then
		light_lo, light_hi = base + 49, math.huge
	elseif intensity > .001 then
		local temp = base + intensity * 100
		light_lo, light_hi = temp - 1, temp + 1
	else
		return lo, hi
	end
	local new_lo, new_hi = math.max(lo, light_lo), math.min(hi, light_hi)
	if new_lo > new_hi then
		return math.min(lo, light_lo), math.max(hi, light_hi)
	end
	return new_lo, new_hi
end
--------------------------------------------------------------------------
-- Tracking

-- instant: called the moment the colour arrived (no tick delay to account for)
local function UpdateStone(item, holder, owner, now, x, y, z, band, instant)
	local state = states[item]
	local cooling, pending, cooled_recently = Coolings.Get(item, x, z, now, holder == nil)
	-- Sentry ward ice: sets stones on the ground to DEER_ICE_TEMPERATURE (remembered for the network delay,
	-- in case it was picked up meanwhile)
	if holder == nil and state ~= nil and Coolings.IsInIceCircle(x, z) then
		state.ice_until = now + Thermal.GetLatency() + 2 * TICK
	end
	local iced = state ~= nil and state.ice_until ~= nil and now <= state.ice_until
	if iced then
		cooled_recently = true
	end

	local live = item.components ~= nil and item.components.temperature or nil
	local env, band_ambient = BuildEnv(item, holder, x, y, z, live ~= nil)
	-- What the colour allows (only the stone's absolute limits narrow it; container limits like a fridge's
	-- 0 degrees are the model's business, the colour may still show where it was a moment ago)
	local band_lo, band_hi = Thermal.GetBandRange(band, band_ambient)
	band_lo = math.max(band_lo, TUNING.MIN_ENTITY_TEMP)
	band_hi = math.min(band_hi, TUNING.MAX_ENTITY_TEMP)

	local lo, hi
	if live ~= nil then
		-- Host: the real value
		local ok, current = pcall(live.GetCurrent, live)
		if ok and type(current) == "number" then
			lo, hi = current, current
		end
	end

	if lo == nil then
		if state == nil or now - state.time > MAX_GAP then
			lo, hi = band_lo, band_hi
		else
			local dt = now - state.time
			-- Cooling applied after the ticks: the lower of the two possible orders, so always safe
			lo, hi = Thermal.AdvanceRange(env, state.lo, state.hi, dt)
			lo = lo - cooling
			if iced then
				lo = math.min(lo, TUNING.DEER_ICE_TEMPERATURE or -2)
			end
			-- A colour change puts the temperature exactly on the band edge (when the change wasn't caused
			-- by a jump of the local temperature, e.g. walking into an overrider's area, or by a cooling effect)
			local jump = math.abs(band_ambient - state.band_ambient)
			if not cooled_recently and not state.resumed and math.abs(band - state.band) == 1 and jump < AMBIENT_JUMP then
				local edge = band_ambient + Thermal.THRESHOLDS[math.min(band, state.band)]
				-- Since the crossing tick the stone moved on (that tick, the network delay, and one tick when only
				-- seen on a tick) at most at the fastest possible rate, and the local temperature by its own pace
				local delay = Thermal.GetStep() + Thermal.GetLatency() + (instant and 0 or dt)
				local fastest = math.max(math.abs(Thermal.GetRate(env, edge, "lo")), math.abs(Thermal.GetRate(env, edge, "hi")))
				local slack = .05 + delay * fastest
				local drift = jump / math.max(dt, Thermal.FRAME) * math.max(dt, delay)
				if band > state.band then
					lo, hi = edge - drift, edge + slack + drift
				else
					lo, hi = edge - slack - drift, edge + drift
				end
			end
		end
		-- The colour clips the range. When they disagree, either can be the one that's late (the colour reaches
		-- us with the network delay; a fridge or a splash changes the stone at once): both stay possible.
		local trusted_lo = lo
		if lo > band_hi or hi < band_lo then
			lo, hi = math.min(lo, band_lo), math.max(hi, band_hi)
			trusted_lo = lo
		else
			lo, hi = math.max(lo, band_lo), math.min(hi, band_hi)
		end
		-- A cooling that may still land: the colour only says where the stone is now, so the bound carried
		-- forward keeps room for it (both are valid lower bounds; the tooltip clips to the band)
		if pending > 0 then
			lo = math.max(trusted_lo, lo - pending)
		end
	end

	state = state or {}
	states[item] = state
	state.lo, state.hi = lo, hi
	state.band_lo = band_lo
	state.band = band
	state.band_ambient = band_ambient
	state.env = env
	state.time = now
	state.live = live ~= nil
	state.top = holder == nil and item or ((holder == owner or holder:IsInLimbo()) and owner or holder)
	state.holder = holder
	state.pocket = IsPocket(holder)
	state.resumed = nil
	state.wet = env.wet
	state.owner = owner
	state.x, state.z = x, z
	return state
end

-- Position and colour of a stone, then UpdateStone. Returns its state, or nil when its colour is unknown.
local function TrackStone(item, holder, owner, now, instant)
	local x, y, z
	local band
	if holder == nil then
		x, y, z = item.Transform:GetWorldPosition()
		band = GetGroundBand(item)
	else
		-- Carried stones are at their top holder's position (inventoryitem.lua OnPutInInventory)
		if holder ~= owner then
			x, y, z = GetContainerPosition(holder, owner)
		else
			x, y, z = owner.Transform:GetWorldPosition()
		end
		band = GetHeldBand(item)
	end
	if band == nil then
		return nil
	end
	return UpdateStone(item, holder, owner, now, x, y, z, band, instant)
end

-- inventoryitem_classified.lua pushes imagechange on the stone as soon as a new colour arrives. Only for
-- stones still being followed in our hands or containers.
local function OnImageChange(item)
	local state = states[item]
	local now = GetTime()
	if state ~= nil and state.holder ~= nil and state.sealed_in == nil and now - state.time <= MAX_GAP
		and item:IsValid() and Thermal.IsHeld(item) and state.holder:IsValid() and state.owner:IsValid() then
		local ok, err = pcall(TrackStone, item, state.holder, state.owner, now, true)
		if not ok then
			LogError(err)
		end
	end
end

local function VisitItems(items, holder, visit)
	for slot, item in pairs(items or {}) do
		if item.prefab == "heatrock" and item:IsValid() then
			visit(item, holder, slot)
		end
	end
end

-- Another player close enough to have opened it (carried containers can only be opened by us)
local function MayHaveBeenOpened(container, owner)
	if container:IsInLimbo() then
		return false
	end
	local x, y, z = container.Transform:GetWorldPosition()
	for _, player in ipairs(TheSim:FindEntities(x, y, z, SEAL_REACH, PLAYER_TAGS)) do
		if player ~= owner then
			return true
		end
	end
	return false
end

-- Follows the stones in closed containers; forgets a container when it may have been touched
local function UpdateSealed(owner, now)
	for container, slots in pairs(sealed) do
		if not container:IsValid() or container:HasTag("burnt") or MayHaveBeenOpened(container, owner) then
			sealed[container] = nil
		else
			local x, y, z = GetContainerPosition(container, owner)
			for _, state in pairs(slots) do
				local dt = now - state.time
				if dt > 0 then
					-- components/inventoryitemmoisture.lua: containers keep items dry (only drying racks are
					-- exposed, and they don't take stones), so a dry stone stays dry; a wet one may dry meanwhile
					local dry, band_ambient = BuildEnv(state.item, container, x, y, z, false, false)
					local lo, hi = Thermal.AdvanceRange(dry, state.lo, state.hi, dt)
					if state.wet then
						local wet = BuildEnv(state.item, container, x, y, z, false, true)
						local wet_lo, wet_hi = Thermal.AdvanceRange(wet, state.lo, state.hi, dt)
						lo, hi = math.min(lo, wet_lo), math.max(hi, wet_hi)
					end
					state.lo, state.hi = lo, hi
					state.env = dry
					state.band_ambient = band_ambient
					state.time = now
				end
			end
		end
	end
end

-- Hot stones: narrow the range with their light when it belongs to exactly one of them
local function ApplyLights(updated)
	if next(lights) == nil then
		return
	end
	local hot_by_top = {}
	for item, state in pairs(updated) do
		if state.band == 5 and not state.live then
			hot_by_top[state.top] = hot_by_top[state.top] == nil and item or false
		end
	end
	if next(hot_by_top) == nil then
		return
	end
	local by_parent = GetLightsByParent()
	for top, item in pairs(hot_by_top) do
		local list = item and by_parent[top] or nil
		if list ~= nil and #list == 1 then
			local intensity = GetLightIntensity(list[1])
			if intensity ~= nil then
				local state = updated[item]
				state.lo, state.hi = ApplyLight(state.lo, state.hi, intensity, state.band_ambient)
			end
		end
	end
end

function Heatrock.Update(owner)
	if owner == nil or not owner:IsValid() or TheWorld == nil then
		return
	end
	local now = GetTime()
	local px, py, pz = owner.Transform:GetWorldPosition()
	tick_cache = { heaters = {} }
	Coolings.Update(px, py, pz, now, GROUND_RANGE)
	local updated = {}

	UpdateSealed(owner, now)
	local open_now = {}

	local function Track(item, holder, slot)
		if updated[item] then
			return
		end
		-- Seen again: it is no longer in the closed container it was remembered in
		local previous = states[item]
		if previous ~= nil and previous.sealed_in ~= nil then
			local slots = sealed[previous.sealed_in]
			if slots ~= nil and slots[previous.sealed_slot] == previous then
				slots[previous.sealed_slot] = nil
			end
			previous.sealed_in, previous.sealed_slot = nil, nil
		end
		if holder ~= nil and holder ~= owner and slot ~= nil then
			-- Reopened: continue from what was simulated while it was closed, if it is that same stone (a
			-- different stone would show its old entity still around)
			local slots = sealed[holder]
			local resumed = slots ~= nil and slots[slot] or nil
			if resumed ~= nil then
				slots[slot] = nil
				resumed.sealed_in, resumed.sealed_slot = nil, nil
				if resumed.item == item or resumed.item == nil or not resumed.item:IsValid() then
					resumed.item = item
					resumed.resumed = true -- its colour may have changed unseen: no edge reading on the first update
					states[item] = resumed
				end
			end
			open_now[holder] = open_now[holder] or {}
			open_now[holder][slot] = item
		end
		updated[item] = TrackStone(item, holder, owner, now, false)
		if holder ~= nil and not listened[item] then
			listened[item] = true
			owner:ListenForEvent("imagechange", OnImageChange, item)
		end
	end

	local inventory = owner.replica.inventory
	if inventory ~= nil then
		VisitItems(inventory:GetItems(), owner, Track)
		local active = inventory:GetActiveItem()
		if active ~= nil and active.prefab == "heatrock" then
			Track(active, owner)
		end
		local containers = {}
		local overflow = inventory:GetOverflowContainer()
		if overflow ~= nil then
			containers[overflow.inst] = true
		end
		for container in pairs(inventory:GetOpenContainers() or {}) do
			containers[container] = true
		end
		for container in pairs(containers) do
			if container:IsValid() and container.replica.container ~= nil then
				VisitItems(container.replica.container:GetItems(), container, Track)
			end
		end
	end

	-- Containers closed since the last tick: keep the stones that were still in them (not one just taken out)
	for container, slots in pairs(open_last) do
		if open_now[container] == nil and container:IsValid() and not MayHaveBeenOpened(container, owner) then
			local kept = sealed[container] or {}
			for slot, item in pairs(slots) do
				local state = states[item]
				if state ~= nil and state.holder == container and not updated[item] and now - state.time <= MAX_GAP then
					state.item = item
					state.sealed_in, state.sealed_slot = container, slot
					kept[slot] = state
				end
			end
			if next(kept) ~= nil then
				sealed[container] = kept
			end
		end
	end
	open_last = open_now

	for _, item in ipairs(TheSim:FindEntities(px, py, pz, GROUND_RANGE, STONE_MUST_TAGS, STONE_CANT_TAGS)) do
		if item.prefab == "heatrock" and not Thermal.IsHeld(item) then
			Track(item, nil)
		end
	end

	ApplyLights(updated)
	tick_cache = nil
end

--------------------------------------------------------------------------
-- For the tooltip

-- Returns nil, or { band, temp, lo, hi, precise, ambient, time } (time only when the temperature and all of
-- its surroundings are known exactly): heading back to neutral (a hot stone cooling, a cold one warming), the
-- seconds until it turns grey and stops working; otherwise (charging) the seconds until its next colour.
local NEUTRAL_BAND = 3

local function PredictChange(state, temp, now)
	local ok, forecast = pcall(Forecast.Build, state.x, state.z, state.pocket, state.time - now, PREDICT_HORIZON)
	if not ok then
		forecast = nil
	end
	local seconds = nil
	if state.band ~= NEUTRAL_BAND then
		seconds = Predict.BandChange(state.env, temp, state.band_ambient, PREDICT_HORIZON, NEUTRAL_BAND, forecast)
	end
	if seconds == nil then
		seconds = Predict.BandChange(state.env, temp, state.band_ambient, PREDICT_HORIZON, nil, forecast)
	end
	-- As a moment in game time: the prediction starts from the stone's last reading
	return seconds ~= nil and state.time + seconds or nil
end

function Heatrock.Get(item)
	local state = states[item]
	local now = GetTime()
	if state == nil or now - state.time > MAX_GAP then
		return nil
	end
	-- The carried bound can sit below the band while a cooling may still land; now the band holds
	local lo = math.max(state.lo, math.min(state.band_lo or state.lo, state.hi))
	local precise = state.hi - lo <= PRECISE
	local info =
	{
		band = state.band,
		lo = lo,
		hi = state.hi,
		temp = (lo + state.hi) / 2,
		precise = precise,
		ambient = state.band_ambient,
	}
	if precise and Thermal.IsExact(state.env) then
		-- Recomputed twice per second; a new prediction that barely differs keeps the countdown running, so it
		-- never ticks back up by a second
		if state.predicted == nil or now - state.predicted >= PREDICT_INTERVAL or state.predicted_band ~= state.band then
			local ok, change_at = pcall(PredictChange, state, info.temp, now)
			if not ok then
				LogError(change_at) -- the temperature is still shown, just without a time
				change_at = nil
			end
			if change_at == nil or state.change_at == nil or state.predicted_band ~= state.band
				or math.abs(change_at - state.change_at) >= STEADY_TOLERANCE then
				state.change_at = change_at
			end
			state.predicted = now
			state.predicted_band = state.band
		end
		info.time = state.change_at ~= nil and math.max(0, state.change_at - now) or nil
	end
	return info
end

--------------------------------------------------------------------------

local task = nil
local listening = nil -- { owner, world } of the fx_spawned listener

-- Runs the tracker for this player (called again when a new HUD is created)
function Heatrock.Start(owner)
	if task ~= nil then
		task:Cancel()
		task = nil
	end
	if listening ~= nil then
		if listening.owner:IsValid() then
			if listening.world:IsValid() then
				listening.owner:RemoveEventCallback("fx_spawned", Coolings.OnFxSpawned, listening.world)
			end
			for item in pairs(listened) do
				if item:IsValid() then
					listening.owner:RemoveEventCallback("imagechange", OnImageChange, item)
				end
			end
		end
		listening = nil
	end
	listened = setmetatable({}, { __mode = "k" })
	open_last = setmetatable({}, { __mode = "k" })
	sealed = setmetatable({}, { __mode = "k" })
	Coolings.Reset(TICK)
	tick_cache = nil
	failed = false
	if owner == nil then
		return
	end
	local ok, err = pcall(Thermal.ReadGameValues) -- the world (and its prefabs) is loaded by now
	if not ok then
		LogError(err)
	end
	-- prefabs/fx.lua pushes fx_spawned on the world for every effect it shows on this client
	if TheWorld ~= nil then
		owner:ListenForEvent("fx_spawned", Coolings.OnFxSpawned, TheWorld)
		listening = { owner = owner, world = TheWorld }
	end
	task = owner:DoPeriodicTask(TICK, function()
		local ok, err = pcall(Heatrock.Update, owner)
		tick_cache = nil
		if not ok then
			LogError(err)
		end
	end)
end

return Heatrock
