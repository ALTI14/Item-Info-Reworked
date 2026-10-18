-- Clothing: sanity from equipment (mirrors components/equippable.lua GetDapperness and the characters'
-- sanity.get_equippable_dappernessfn / no_moisture_penalty overrides), and who may equip an item.

local Combat = require "iteminfo_updated/stats/combat"

local Clothing = {}

local NO_MOISTURE_PENALTY = { wurt = true, wormwood = true }

function Clothing.GetDapperness(item, equippable, owner)
	-- Hosts: exactly what components/sanity.lua Recalc uses
	local sanity = owner.components ~= nil and owner.components.sanity or nil
	local live_equippable = item.components ~= nil and item.components.equippable or nil
	if sanity ~= nil and live_equippable ~= nil then
		local ok, value = pcall(function()
			local dapperness = sanity.get_equippable_dappernessfn ~= nil and sanity.get_equippable_dappernessfn(owner, live_equippable)
				or live_equippable:GetDapperness(owner, sanity.no_moisture_penalty)
			return dapperness * (sanity.dapperness_mult or 1)
		end)
		if ok and type(value) == "number" then
			return value
		end
	end

	local dapperness = equippable.dapperness
	if equippable.flipdapperonmerms and owner:HasTag("merm") then
		dapperness = -dapperness
	end
	if not NO_MOISTURE_PENALTY[owner.prefab] and item.replica.inventoryitem ~= nil and item.replica.inventoryitem:IsWet() then
		dapperness = dapperness + TUNING.WET_ITEM_DAPPERNESS
	end

	if owner.prefab == "walter" then
		return equippable.is_magic_dapperness and dapperness or 0
	elseif owner.prefab == "waxwell" and item:HasTag("shadow_item") then
		return dapperness * TUNING.WAXWELL_SHADOW_ITEM_RESISTANCE
	elseif owner.prefab == "wanda" and item:HasTag("shadow_item") then
		local age = Combat.GetWandaAgeState(owner)
		return dapperness * ((age == "old" and TUNING.WANDA_SHADOW_RESISTANCE_OLD)
			or (age == "normal" and TUNING.WANDA_SHADOW_RESISTANCE_NORMAL)
			or TUNING.WANDA_SHADOW_RESISTANCE_YOUNG)
	end
	return dapperness
end

function Clothing.CanEquip(item, owner)
	local inventoryitem = item.replica.inventoryitem
	local tag = inventoryitem ~= nil and inventoryitem:GetEquipRestrictedTag() or nil
	return tag == nil or owner:HasTag(tag)
end

return Clothing
