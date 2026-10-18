-- Equipment set bonuses, decided from what the player has equipped (visible to clients).
--
-- Weapons (prefabs/sword_lunarplant.lua, voidcloth_scythe.lua, ...): buffed as soon as the
-- matching hat is worn, the armor isn't needed.
-- Armor (components/setbonus.lua): head and body piece of the same set.

local Sets = {}

local LUNARPLANT_WEAPON =
{
	hat = "lunarplanthat",
	damage_mult = "WEAPONS_LUNARPLANT_SETBONUS_DAMAGE_MULT",
	planar_bonus = "WEAPONS_LUNARPLANT_SETBONUS_PLANAR_DAMAGE",
}
local VOIDCLOTH_WEAPON =
{
	hat = "voidclothhat",
	damage_mult = "WEAPONS_VOIDCLOTH_SETBONUS_DAMAGE_MULT",
	planar_bonus = "WEAPONS_VOIDCLOTH_SETBONUS_PLANAR_DAMAGE",
}

Sets.WEAPONS =
{
	sword_lunarplant = LUNARPLANT_WEAPON,
	pickaxe_lunarplant = LUNARPLANT_WEAPON,
	shovel_lunarplant = LUNARPLANT_WEAPON,
	voidcloth_scythe = VOIDCLOTH_WEAPON,
	shadow_battleaxe = VOIDCLOTH_WEAPON,
	-- prefabs/voidcloth_boomerang.lua: damage only, planar damage isn't boosted
	voidcloth_boomerang = { hat = "voidclothhat", damage_mult = "WEAPONS_VOIDCLOTH_SETBONUS_DAMAGE_MULT" },
}

Sets.PIECES =
{
	armordreadstone = "dreadstone",
	dreadstonehat = "dreadstone",
	armor_lunarplant = "lunarplant",
	lunarplanthat = "lunarplant",
	armor_voidcloth = "voidcloth",
	voidclothhat = "voidcloth",
}

-- Extra alignment resistance each piece gets while the set is complete
Sets.RESIST =
{
	lunarplant = { tag = "lunar_aligned", mult = "ARMOR_LUNARPLANT_SETBONUS_LUNAR_RESIST" },
	voidcloth = { tag = "shadow_aligned", mult = "ARMOR_VOIDCLOTH_SETBONUS_SHADOW_RESIST" },
}

-- Walter's slingshot with the Void handle (prefabs/slingshotpart_defs.lua slingshot_handle_voidcloth), while
-- its owner wears the Void Cowl: the dreadstone and horror fuel ammo it fires get the voidcloth weapon bonus
-- (slingshot.lua OnProjectileLaunched -> slingshotammo.lua SetVoidBonus)
local VOID_HANDLE_AMMO =
{
	slingshotammo_dreadstone = VOIDCLOTH_WEAPON,
	slingshotammo_horrorfuel = VOIDCLOTH_WEAPON,
}
local VOID_HANDLE = "slingshot_handle_voidcloth"

local function GetEquipped(owner, slot)
	local inventory = owner.replica.inventory
	return inventory ~= nil and slot ~= nil and inventory:GetEquippedItem(slot) or nil
end

-- slingshot.lua sends the handle as its index among the handle parts, in pairs order over the part
-- definitions (the client decodes it the same way for the slingshot's icon)
local part_defs = nil
local function GetSlingshotHandle(slingshot)
	if part_defs == nil then
		local ok, defs = pcall(require, "prefabs/slingshotpart_defs")
		part_defs = ok and type(defs) == "table" and defs or false
	end
	local id = slingshot.handleid ~= nil and slingshot.handleid:value() or 0
	if not part_defs or type(id) ~= "number" or id <= 0 then
		return nil
	end
	local index = 0
	for name, def in pairs(part_defs) do
		if type(def) == "table" and def.slot == "handle" then
			index = index + 1
			if index == id then
				return name
			end
		end
	end
end

local function HasVoidHandleBonus(owner)
	local slingshot = GetEquipped(owner, EQUIPSLOTS.HANDS)
	if slingshot == nil or not slingshot:HasTag("slingshot") then
		return false
	elseif slingshot.components ~= nil and slingshot.components.slingshotmods ~= nil then
		return slingshot.voidbonusenabled == true -- hosts: the slingshot's own flag
	end
	local hat = GetEquipped(owner, EQUIPSLOTS.HEAD)
	return hat ~= nil and hat.prefab == "voidclothhat" and GetSlingshotHandle(slingshot) == VOID_HANDLE
end

-- Returns the weapon's (or slingshot ammo's) bonus definition when it applies
function Sets.GetWeaponBonus(owner, item)
	local ammo = VOID_HANDLE_AMMO[item.prefab]
	if ammo ~= nil then
		return HasVoidHandleBonus(owner) and ammo or nil
	end
	local def = Sets.WEAPONS[item.prefab]
	if def == nil then
		return nil
	end
	local hat = GetEquipped(owner, EQUIPSLOTS.HEAD)
	return hat ~= nil and hat.prefab == def.hat and def or nil
end

-- Returns the set name when this piece, together with the piece in the other slot, completes its set
function Sets.GetActiveArmorSet(owner, item)
	local set = Sets.PIECES[item.prefab]
	if set == nil then
		return nil
	end
	local equippable = item.replica.equippable
	local slot = equippable ~= nil and equippable:EquipSlot() or nil
	local other_slot = (slot == EQUIPSLOTS.HEAD and EQUIPSLOTS.BODY) or (slot == EQUIPSLOTS.BODY and EQUIPSLOTS.HEAD) or nil
	local other = GetEquipped(owner, other_slot)
	return other ~= nil and other ~= item and Sets.PIECES[other.prefab] == set and set or nil
end

-- prefabs/hats.lua voidcloth_onequip -> voidcloth_setbuffowner: wearing the Void Cowl alone (no full set
-- needed) makes each hit add planar damage to an equipped shadow weapon with planar damage, up to
-- ARMOR_VOIDCLOTH_SETBONUS_PLANARDAMAGE_MAX. Returns that maximum.
function Sets.GetVoidclothRamp(owner, item)
	if not item:HasTag("shadow_item") then
		return 0
	end
	local hat = GetEquipped(owner, EQUIPSLOTS.HEAD)
	if hat == nil or hat.prefab ~= "voidclothhat" then
		return 0
	end
	return TUNING.ARMOR_VOIDCLOTH_SETBONUS_PLANARDAMAGE_MAX or 0
end

return Sets
