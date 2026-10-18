-- Instant cooling of Thermal Stones lying on the ground (they skip anything in an inventory). Each one cools
-- by a known amount at most, so the tracker drops the cold end of the range by that amount (they never warm
-- a stone):
--  * components/wateryprotection.lua temperaturereduction, applied once where a splash lands (the
--    Flingomatic's and the sprinkler fish's delayed spreads only happen when no player is near):
--    Ice Flingomatic / thrown snowball (5 / 2), water balloon (5), sprinkler fish (5), whirlpool (5)
--  * watering cans (5): the pouring player plays "water_pre" / "water"; a pour takes 26 frames, and
--    reaches 2.25 + 1.5 (arrive distance) from the player
--  * prefabs/deerclopseyeball_sentryward.lua: its ice circle (radius growing to 3.5, done once it plays "pst")
--    sets stones to DEER_ICE_TEMPERATURE
-- The stones a cooling can reach are remembered when it happens, so picking one up right after still counts.

local Thermal = require "iteminfo_updated/heatrock/model"

local Coolings = {}

local SPLASHES =
{
	splash_snow_fx = { radius = 4, reduction = { "FIRESUPPRESSOR_TEMP_REDUCTION", "SNOWBALL_TEMP_REDUCTION" } },
	waterballoon_splash = { radius = 4, reduction = { "WATERBALLOON_TEMP_REDUCTION" } },
	waterstreak_burst = { radius = 3, reduction = { "FIRESUPPRESSOR_TEMP_REDUCTION" } },
	oceanwhirlportal_splash = { radius = 8, reduction = { "OCEANWHIRLPORTAL_TEMP_REDUCTION" } },
}
local SPLASH_MARGIN = .5
local COOLING_WINDOW = 1    -- seconds a cooling effect is remembered (to reach every stone it covers)
local POUR_REACH = 6
local POUR_INTERVAL = .8    -- shorter than a pour (26 frames): never misses one, may count one twice
local POUR_DELAY = 24 * Thermal.FRAME -- SGwilson "pour": the water lands 24 frames into the pour
local ICE_CIRCLE_REACH = 4.5

local STONE_MUST_TAGS = { "heatrock" }
local STONE_CANT_TAGS = { "INLIMBO" }
local PLAYER_TAGS = { "player" }

local coolings = {} -- { x, z, radius, amount, expires, pending_until, targets = { [stone] }, applied = { [stone] } }
local pours = setmetatable({}, { __mode = "k" })       -- player -> time a pour was last counted
local ice_circles = setmetatable({}, { __mode = "k" }) -- deerclopseyeball_sentryward_fx (registered by modmain.lua)
local update_period = .1                               -- the tracker's (Reset)

-- Forgets every cooling; period: seconds between the tracker's updates
function Coolings.Reset(period)
	coolings = {}
	pours = setmetatable({}, { __mode = "k" })
	update_period = period
end

-- The biggest of these TUNING values (the effect could come from any of them)
local function GetReduction(names)
	local amount = 0
	for _, name in ipairs(names) do
		local value = TUNING[name]
		if type(value) == "number" then
			amount = math.max(amount, value)
		end
	end
	return amount > 0 and amount or 5
end

local function FindGroundStones(x, z, radius)
	local found = setmetatable({}, { __mode = "k" })
	for _, stone in ipairs(TheSim:FindEntities(x, 0, z, radius, STONE_MUST_TAGS, STONE_CANT_TAGS)) do
		if stone.prefab == "heatrock" and not Thermal.IsHeld(stone) then
			found[stone] = true
		end
	end
	return found
end

-- pending: seconds during which the cooling may still be about to land (or reach us), else it already did
local function AddCooling(x, z, radius, amount, pending)
	local now = GetTime()
	table.insert(coolings,
	{
		x = x, z = z, radius = radius, amount = amount,
		expires = now + math.max(COOLING_WINDOW, pending),
		pending_until = now + pending,
		targets = FindGroundStones(x, z, radius),
		applied = setmetatable({}, { __mode = "k" }),
	})
end

-- prefabs/fx.lua pushes fx_spawned on the world for every effect it shows on this client
function Coolings.OnFxSpawned(_, fx)
	local splash = fx ~= nil and (SPLASHES[fx.name] or SPLASHES[fx.prefab]) or nil
	if splash ~= nil and fx.Transform ~= nil then
		local x, _, z = fx.Transform:GetWorldPosition()
		-- The stone's new colour may reach us a little after the splash: keep room for it until then
		AddCooling(x, z, splash.radius + SPLASH_MARGIN, GetReduction(splash.reduction), Thermal.GetLatency() + 2 * update_period)
	end
end

-- Once per tracker update: drops the old coolings, and counts watering cans being poured within range
function Coolings.Update(px, py, pz, now, range)
	for i = #coolings, 1, -1 do
		if coolings[i].expires < now then
			table.remove(coolings, i)
		end
	end
	for _, player in ipairs(TheSim:FindEntities(px, py, pz, range + POUR_REACH, PLAYER_TAGS)) do
		if player.AnimState ~= nil and (player.AnimState:IsCurrentAnimation("water_pre") or player.AnimState:IsCurrentAnimation("water"))
			and (pours[player] == nil or now - pours[player] >= POUR_INTERVAL) then
			pours[player] = now
			local x, _, z = player.Transform:GetWorldPosition()
			-- Seen at any point of the pour: the water may still land up to 24 frames (+ network delay) later
			AddCooling(x, z, POUR_REACH, GetReduction({ "WATERINGCAN_TEMP_REDUCTION" }), POUR_DELAY + Thermal.GetLatency())
		end
	end
end

-- For a stone: how much it may have been cooled since its last update, how much more it may still be
-- cooled by effects that haven't landed (or reached us) yet, and whether a cooling covers it right now (then
-- a colour change may come from it, not from the model)
function Coolings.Get(item, x, z, now, on_ground)
	local cooling, pending, recent = 0, 0, false
	for _, c in ipairs(coolings) do
		if c.targets[item] or (on_ground and (c.x - x) * (c.x - x) + (c.z - z) * (c.z - z) <= c.radius * c.radius) then
			recent = true
			if not c.applied[item] then
				c.applied[item] = true
				cooling = cooling + c.amount
			end
			if c.pending_until > now then
				pending = pending + c.amount
			end
		end
	end
	return cooling, pending, recent
end

function Coolings.RegisterIceCircle(inst)
	ice_circles[inst] = true
end

-- A sentry ward's ice circle that may still be freezing what lies at (x, z)
function Coolings.IsInIceCircle(x, z)
	for circle in pairs(ice_circles) do
		if circle:IsValid() and not (circle.AnimState ~= nil and circle.AnimState:IsCurrentAnimation("pst")) then
			local cx, _, cz = circle.Transform:GetWorldPosition()
			if (cx - x) * (cx - x) + (cz - z) * (cz - z) <= ICE_CIRCLE_REACH * ICE_CIRCLE_REACH then
				return true
			end
		end
	end
	return false
end

return Coolings
