-- Combat: damage dealt with a weapon (mirrors components/combat.lua CalcDamage; character multipliers never
-- apply to planar damage), skills and allegiances, and the alignment of gear.

local ItemState = require "iteminfo_updated/stats/itemstate"
local Upvalue = require "iteminfo_updated/upvalue"

local Combat = {}

-- components/mightiness.lua STATE_DATA externaldamagemultiplier (none = 1), read from the component when it can be
local MIGHTINESS_DAMAGE = { wimpy = .75, normal = 1, mighty = 2 }
local mightiness_read = false

local function GetMightinessDamage(state)
	if not mightiness_read then
		mightiness_read = true
		local ok, Mightiness = pcall(require, "components/mightiness")
		local data = ok and Upvalue.FindIn(Mightiness, "STATE_DATA", 1) or nil
		if type(data) == "table" then
			for name in pairs(MIGHTINESS_DAMAGE) do
				local mult = type(data[name]) == "table" and data[name].externaldamagemultiplier or nil
				if type(data[name]) == "table" and (mult == nil or type(mult) == "number") then
					MIGHTINESS_DAMAGE[name] = mult or 1
				end
			end
		end
	end
	return MIGHTINESS_DAMAGE[state]
end

function Combat.GetWandaAgeState(owner)
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

-- TUNING.SKILLS value, nil when the game (or a mod) doesn't define it
local function SkillTuning(name)
	return TUNING.SKILLS ~= nil and TUNING.SKILLS[name] or nil
end

local function GetMightiness(owner)
	local classified = owner.player_classified
	return classified ~= nil and classified.currentmightiness ~= nil and classified.currentmightiness:value() or nil
end

-- prefabs/skilltree_*.lua allegiance skills: the player deals more damage to the opposite alignment.
-- Every character uses 1.1, Wolfgang's three tiers go up to 1.3.
function Combat.GetAllegianceBonus(owner)
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
		local mult = SkillTuning("WILSON_ALLEGIANCE_VS_"..vs.."_BONUS") or 1.1
		if owner.prefab == "wolfgang" then
			mult = SkillTuning("WOLFGANG_ALLEGIANCE_VS_"..vs.."_BONUS_1") or mult
			for tier = 2, 3 do
				if IsSkillActivated(owner, "wolfgang_allegiance_"..side.."_"..tier) then
					mult = mult * (SkillTuning("WOLFGANG_ALLEGIANCE_VS_"..vs.."_BONUS_"..tier) or 1)
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
function Combat.GetWolfgangPlanarBonus(owner, item)
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
			bonus = bonus + (SkillTuning("WOLFGANG_PLANARDAMAGE_"..i) or 0)
		end
	end
	return bonus
end

-- prefabs/hats.lua wathgrithr_refreshattunedskills: Wigfrid's improved helm gains planar defense
function Combat.GetSkillPlanarDefense(owner, item)
	if owner.prefab == "wathgrithr" and item.prefab == "wathgrithr_improvedhat" and IsSkillActivated(owner, "wathgrithr_arsenal_helmet_4") then
		local wathgrithr = SkillTuning("WATHGRITHR")
		return wathgrithr ~= nil and wathgrithr.HELM_PLANAR_DEF or 0
	end
	return 0
end

function Combat.GetDamageMultiplier(owner, item)
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
		local value = GetMightiness(owner)
		if value == nil then
			return 1
		elseif value >= TUNING.MIGHTY_THRESHOLD then
			return GetMightinessDamage("mighty")
		elseif value >= TUNING.WIMPY_THRESHOLD then
			return GetMightinessDamage("normal")
		end
		return GetMightinessDamage("wimpy")
	elseif prefab == "wanda" then
		local age = Combat.GetWandaAgeState(owner)
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
	local wortox = SkillTuning("WORTOX")
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
			local percent = ItemState.GetPercentUsed(other)
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
function Combat.GetBaseDamage(item, data, owner)
	if item.prefab == "wortox_nabbag" then
		local damage, soul_bonus = GetNabbagDamage(owner)
		if damage ~= nil then
			return damage, damage, soul_bonus
		end
	elseif item.prefab == "hambat" then
		local percent = ItemState.GetPerishPercent(item) or 1
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

-- Gear has no lunar_aligned / shadow_aligned tags (only creatures do), so the alignment comes from
-- what the gear does: lunar gear hits shadow creatures harder and resists lunar damage, and the
-- other way around. Then the game's tags, then the prefab name for gear with neither (staffs, bombs).
function Combat.GetAlignment(item, data)
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

return Combat
