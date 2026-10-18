-- Turns an item into rows of {icon, text} cells: the reworked layout and the classic one.
-- The numbers come from stats/ (food, spoilage, combat, clothing: each mirrors the game's components, using
-- only data a client can actually see), sets.lua, cache.lua (base stats) and heatrock/ (Thermal Stones).

local Cache = require "iteminfo_updated/cache"
local Heatrock = require "iteminfo_updated/heatrock/tracker"
local Sets = require "iteminfo_updated/sets"
local Clothing = require "iteminfo_updated/stats/clothing"
local Combat = require "iteminfo_updated/stats/combat"
local Food = require "iteminfo_updated/stats/food"
local ItemState = require "iteminfo_updated/stats/itemstate"
local Spoilage = require "iteminfo_updated/stats/spoilage"

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
} or
{
	days = "d",
	seconds = "s",
	per_minute = "/min",
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

-- Icons for "against lunar / shadow creatures" (bonus damage, resistance), deliberately different
-- from the item's own alignment icons used for its planar damage / defense
local ALIGNMENT_ICONS =
{
	lunar_aligned = ICONS.vs_lunar,
	shadow_aligned = ICONS.vs_shadow,
}

local function GetAlignmentIcon(item, data)
	local alignment = Combat.GetAlignment(item, data)
	return (alignment == "lunar" and ICONS.lunar) or (alignment == "shadow" and ICONS.shadow) or ICONS.planar
end

--------------------------------------------------------------------------
-- Row builders

local function AddFoodRows(rows, item, data, owner)
	local food = Food.Compute(item, data, owner)
	if food == nil then
		return
	end
	local edible = data.edible
	local hunger, sanity, health, favorite, refused = food.hunger, food.sanity, food.health, food.favorite, food.refused
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
	if CFG.perish_display == 3 then
		return
	end
	local percent, stale_time, rot_time = Spoilage.Compute(item, data, holder)
	if percent == nil then
		return
	end

	local row = { Cell(ICONS.freshness, FormatPercent(percent)) }

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

local function AddWeaponRow(rows, item, data, owner, compact)
	if data.weapon == nil or not Clothing.CanEquip(item, owner) then
		return
	end

	-- Everything coming from set bonuses and skills is shown in green
	local bonus = Sets.GetWeaponBonus(owner, item)
	local bonus_mult = bonus ~= nil and bonus.damage_mult ~= nil and TUNING[bonus.damage_mult] or 1
	local planar_bonus = (bonus ~= nil and bonus.planar_bonus ~= nil and TUNING[bonus.planar_bonus] or 0)

	local row = {}
	local min, max, skill_bonus = Combat.GetBaseDamage(item, data, owner)
	if min ~= nil and max > 0 then
		local mult = Combat.GetDamageMultiplier(owner, item) * bonus_mult
		local text = FormatNumber(min * mult)
		if max ~= min then
			text = text.."-"..FormatNumber(max * mult)
		end
		table.insert(row, Cell(ICONS.weapon, text, (bonus_mult ~= 1 or skill_bonus) and COLOUR_BONUS or nil))
	end

	if data.planardamage ~= nil and data.planardamage > 0 then
		planar_bonus = planar_bonus + Combat.GetWolfgangPlanarBonus(owner, item)
		local planar = data.planardamage + planar_bonus
		local text = FormatNumber(planar)
		-- Void Cowl: every hit adds planar damage to shadow weapons, up to 6 hits (prefabs/hats.lua)
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
	for tag, mult in pairs(Combat.GetAllegianceBonus(owner) or {}) do
		vs[tag] = (vs[tag] or 1) * mult
		from_skill[tag] = true
	end
	if #row > 0 then
		table.insert(rows, row)
	end

	-- Bonuses against lunar / shadow creatures on their own row, so the damage row stays short.
	-- Left out of the compact equipped panel.
	if not compact then
		local vs_row = {}
		for _, tag in ipairs({ "lunar_aligned", "shadow_aligned" }) do
			local mult = vs[tag]
			if mult ~= nil and mult > 1.0005 then
				table.insert(vs_row, Cell(ALIGNMENT_ICONS[tag], "+"..FormatPercent(mult - 1), from_skill[tag] and COLOUR_BONUS or nil))
			end
		end
		if #vs_row > 0 then
			table.insert(rows, vs_row)
		end
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
	local percent = ItemState.GetPercentUsed(item)
	if percent ~= nil then
		table.insert(row, Cell(ICONS.health, string.format("%d", math.floor(data.armor.maxcondition * percent + .5)), DurabilityColour(percent)))
	end
	if #row > 0 then
		table.insert(rows, row)
	end

	-- Planar defense and less damage taken from aligned creatures (set bonus / skills in green)
	row = {}
	local skill_defense = Combat.GetSkillPlanarDefense(owner, item)
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
		local dapperness = Clothing.GetDapperness(item, equippable, owner)
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

-- Thermal Stone temperature from the tracker (heatrock/tracker.lua): one value when it is known exactly,
-- otherwise the range it is guaranteed to be in; then the time until it changes colour.
local function GetHeatrockCell(item)
	local info = Heatrock.Get(item)
	if info == nil then
		return nil
	end
	local text
	if info.precise then
		text = string.format("%d°", math.floor(info.temp + .5))
	else
		-- "~" between negative numbers ("-13~-5°" rather than "-13--5°"; the number font has no en dash)
		local lo, hi = math.floor(info.lo), math.ceil(info.hi)
		text = string.format(lo < 0 and "%d~%d°" or "%d-%d°", lo, hi)
	end
	if info.time ~= nil then
		local seconds = math.floor(info.time + .5)
		text = text..string.format(" · %d:%02d", math.floor(seconds / 60), seconds % 60)
	end
	return Cell(info.temp >= info.ambient and ICONS.heat or ICONS.cold, text)
end

local function AddDurabilityRows(rows, item, data)
	local percent = ItemState.GetPercentUsed(item)

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
			local temperature = item.prefab == "heatrock" and GetHeatrockCell(item) or nil
			if temperature ~= nil then
				table.insert(row, temperature)
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

local function AddHealerRow(rows, data)
	if data.healer ~= nil then
		table.insert(rows, { Cell(ICONS.health, FormatSigned(data.healer)) })
	end
end

--------------------------------------------------------------------------

-- A game update can break one kind of row (a renamed value, a changed component): that row is then left out
-- and reported once, the rest of the item still shows
local reported_errors = {}

local function Report(prefab, what, err)
	local key = tostring(prefab).."/"..what
	if not reported_errors[key] then
		reported_errors[key] = true
		print("[Item Info Reworked] Error while reading "..tostring(prefab).." ("..what.."): "..tostring(err))
	end
end

local function AddSafely(rows, item, what, builder, ...)
	local count = #rows
	local ok, err = pcall(builder, rows, ...)
	if not ok then
		for i = #rows, count + 1, -1 do
			rows[i] = nil -- a row it had half built
		end
		Report(item.prefab, what, err)
	end
end

local function BuildRows(item, holder, owner, compact)
	local rows = {}
	local data = Cache.Get(item)

	if data ~= nil then
		if CFG.show_food then
			AddSafely(rows, item, "food", AddFoodRows, item, data, owner)
			AddSafely(rows, item, "healing", AddHealerRow, data)
		end
		AddSafely(rows, item, "spoilage", AddPerishRows, item, data, holder)
		if CFG.show_combat then
			AddSafely(rows, item, "weapon", AddWeaponRow, item, data, owner, compact)
			AddSafely(rows, item, "armor", AddArmorRow, item, data, owner)
		end
		if CFG.show_clothing then
			AddSafely(rows, item, "clothing", AddClothingRows, item, data, owner)
		end
		if CFG.show_durability then
			AddSafely(rows, item, "durability", AddDurabilityRows, item, data)
			AddSafely(rows, item, "placed health", AddPlacedHealthRow, data)
		end
	end

	if CFG.show_prefabname then
		table.insert(rows, { Cell(ICONS.label, item.prefab) })
	end

	return rows
end

--------------------------------------------------------------------------
-- Classic style: the layout of the original Item Info, with the same numbers.
-- Rows are listed bottom to top (the view stacks them upward), cells are plain white.

-- Original time format: "45", "02:05", "1:02:05" or "1.5d"
local function FormatTimeClassic(t)
	if t == nil or t ~= t then
		return "?"
	elseif t == math.huge then
		return "-"
	end
	t = math.max(0, t)
	if CFG.time_format == 1 then
		return t == 0 and "0d" or FormatNumber(t / TUNING.TOTAL_DAY_TIME).."d"
	elseif t == 0 then
		return "0"
	end
	local hours = math.floor(t / 3600)
	local mins = math.floor(t / 60 - hours * 60)
	local secs = math.floor(t - hours * 3600 - mins * 60)
	if hours == 0 and mins == 0 then
		return string.format("%02d", secs)
	elseif hours == 0 then
		return string.format("%02d:%02d", mins, secs)
	end
	return string.format("%d:%02d:%02d", hours, mins, secs)
end

local VS_ICONS = { [ICONS.vs_lunar[2]] = true, [ICONS.vs_shadow[2]] = true }

-- Runs a reworked row builder and returns its cells, without colours
local function Collect(item, what, builder, ...)
	local rows = {}
	AddSafely(rows, item, what, builder, ...)
	local cells = {}
	for _, row in ipairs(rows) do
		for _, cell in ipairs(row) do
			cells[#cells + 1] = { atlas = cell.atlas, tex = cell.tex, text = cell.text, icon_size = cell.icon_size }
		end
	end
	return cells
end

local function Pick(cells, test)
	local picked = {}
	for _, cell in ipairs(cells) do
		if test(cell.tex) then
			picked[#picked + 1] = cell
		end
	end
	return picked
end

local function StripPlus(cell)
	cell.text = cell.text:gsub("^%+", "")
	return cell
end

local function BuildRowsClassic(item, holder, owner)
	local rows = {}
	local data = Cache.Get(item)
	local function Add(row)
		if row ~= nil and #row > 0 then
			rows[#rows + 1] = row
		end
	end

	if data ~= nil then
		local clothing = CFG.show_clothing and Collect(item, "clothing", AddClothingRows, item, data, owner) or {}
		local durability = CFG.show_durability and Collect(item, "durability", AddDurabilityRows, item, data) or {}

		-- 1. Sanity per minute
		for _, cell in ipairs(Pick(clothing, function(tex) return tex == ICONS.sanity[2] end)) do
			Add({ StripPlus(cell) })
		end

		-- 2. Spoilage: freshness with one decimal; stale time on its own row above (show all)
		if CFG.perish_display ~= 3 then
			local ok, percent, stale_time, rot_time = pcall(Spoilage.Compute, item, data, holder)
			if not ok then
				Report(item.prefab, "spoilage", percent)
			elseif percent ~= nil then
				local fresh = Cell(ICONS.freshness, FormatNumber(percent * 100).."%")
				if data.edible == nil or CFG.perish_display == 0 then
					Add({ fresh, Cell(ICONS.spoiled, FormatTimeClassic(rot_time)) })
				elseif CFG.perish_display == 1 then
					Add({ fresh, stale_time ~= nil and Cell(ICONS.stale, FormatTimeClassic(stale_time)) or Cell(ICONS.spoiled, FormatTimeClassic(rot_time)) })
				else
					Add({ fresh, Cell(ICONS.spoiled, FormatTimeClassic(rot_time)) })
					if stale_time ~= nil then
						Add({ Cell(ICONS.stale, FormatTimeClassic(stale_time)) })
					end
				end
			end
		end

		-- 3-4. Insulation, waterproofing, (movement speed)
		for _, test in ipairs({
			function(tex) return tex == ICONS.insulation_winter[2] or tex == ICONS.insulation_summer[2] end,
			function(tex) return tex == ICONS.waterproof[2] end,
			function(tex) return tex == "cane.tex" end,
		}) do
			for _, cell in ipairs(Pick(clothing, test)) do
				Add({ cell })
			end
		end

		-- 5. Uses (with the Thermal Stone's temperature next to it)
		Add(Pick(durability, function(tex) return tex == ICONS.uses[2] or tex == ICONS.heat[2] or tex == ICONS.cold[2] end))

		if CFG.show_combat then
			-- 6. Damage and planar damage (no "vs" cells in the original)
			Add(Pick(Collect(item, "weapon", AddWeaponRow, item, data, owner), function(tex) return not VS_ICONS[tex] end))
		end

		-- 7. Fuel / wear time
		Add(Pick(durability, function(tex) return tex == ICONS.fuel_light[2] or tex == ICONS.fuel_wearable[2] end))

		if CFG.show_combat then
			-- 8. Armor: absorption, durability, planar defense on one row
			Add(Pick(Collect(item, "armor", AddArmorRow, item, data, owner), function(tex) return not VS_ICONS[tex] end))
		end

		if CFG.show_food then
			-- 9. Healing
			for _, cell in ipairs(Collect(item, "healing", AddHealerRow, data)) do
				Add({ StripPlus(cell) })
			end
			-- 10. Food (no favorite star in the original), then warming / cooling
			local food = Collect(item, "food", AddFoodRows, item, data, owner)
			Add(Pick(food, function(tex) return tex == ICONS.hunger[2] or tex == ICONS.sanity[2] or tex == ICONS.health[2] end))
			for _, cell in ipairs(Pick(food, function(tex) return tex == ICONS.heat[2] or tex == ICONS.cold[2] end)) do
				Add({ cell })
			end
		end

		if CFG.show_durability then
			for _, cell in ipairs(Collect(item, "placed health", AddPlacedHealthRow, data)) do
				Add({ cell })
			end
		end
	end

	if CFG.show_prefabname then
		Add({ Cell(ICONS.label, item.prefab) })
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

-- Returns rows, signature. Never throws: a broken item just shows nothing.
-- compact: for the equipped panel (leaves out the "vs lunar / shadow" row)
function Stats.GetRows(item, holder, owner, compact)
	if item == nil or not item:IsValid() or item.replica.inventoryitem == nil or owner == nil then
		return {}, ""
	end

	local ok, rows = pcall(CFG.ui_style == "classic" and BuildRowsClassic or BuildRows, item, holder, owner, compact)
	if not ok then
		Report(item.prefab, "rows", rows)
		return {}, ""
	end
	return rows, Signature(rows)
end

return Stats