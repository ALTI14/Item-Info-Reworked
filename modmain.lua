local _G = GLOBAL

-- Pure UI mod: nothing to do on dedicated servers
if _G.TheNet:IsDedicated() then
	return
end

local function Config(name, default)
	local value = GetModConfigData(name)
	if value == nil then
		return default
	end
	return value
end

-- Background opacity: 0 = off. Older versions saved true / false.
local function Opacity(name, default)
	local value = Config(name, default)
	if value == true then
		return default
	elseif type(value) ~= "number" then
		return 0
	end
	return value
end

--------------------------------------------------------------------------
-- Turn off next to Insight / Show Me when the player asked for it

if not Config("ENABLER", true) then
	local CONFLICTING_MODS =
	{
		"workshop-2189004162", -- Insight
		"workshop-666155465",  -- Show Me (Origin)
		"workshop-2287303119", -- Show Me (中文)
	}

	local enabled_mods = {}
	for _, modname in ipairs(_G.KnownModIndex:GetModsToLoad() or {}) do
		enabled_mods[modname] = true
	end
	for _, modname in ipairs(CONFLICTING_MODS) do
		if enabled_mods[modname] or _G.KnownModIndex:IsModEnabled(modname) then
			print("[Item Info Reworked] "..modname.." is enabled, Item Info Reworked is turned off (see the mod's settings).")
			return
		end
	end
end

local function IsChinese()
	local ok, code = _G.pcall(function() return _G.LOC.GetLocaleCode() end)
	return ok and (code == "zh" or code == "zhr" or code == "zht")
end

--------------------------------------------------------------------------
-- Settings, shared with the scripts through a single global table

_G.ITEMINFO_UPDATED =
{
	enabled = true,
	config =
	{
		info_scale = Config("INFO_SCALE", .8),
		tooltip_offset = Config("TOOLTIP_OFFSET", 0),
		tooltip_background = Opacity("TOOLTIP_BACKGROUND", .55),
		container_tooltips = Config("CONTAINER_TOOLTIPS", true),

		show_food = Config("SHOW_FOOD", true),
		perish_display = Config("PERISHABLE", 2),
		show_combat = Config("SHOW_COMBAT", true),
		show_clothing = Config("SHOW_CLOTHING", true),
		show_durability = Config("SHOW_DURABILITY", true),
		show_refused_food = Config("SHOW_REFUSED_FOOD", false),
		time_format = Config("TIME_FORMAT", 0),
		show_prefabname = Config("SHOW_PREFABNAME", false),

		show_hands = Config("SHOW_INFO_HANDS", true),
		show_body = Config("SHOW_INFO_BODY", true),
		show_head = Config("SHOW_INFO_HEAD", true),
		equip_scale = Config("EQUIP_SCALE", .46),
		equip_background = Opacity("SHOW_BACKGROUND", .45),
		margin_h = Config("HORIZONTAL_MARGIN", 100),
		margin_v = Config("VERTICAL_MARGIN", 100),
		avoid_backpack = Config("AVOID_BACKPACK", false),

		-- Simplified Chinese (zh, zhr for WeGame) and Traditional Chinese (zht)
		chinese = IsChinese(),
	},
}

Assets =
{
	Asset("ATLAS", "images/iteminfo_images.xml"),
	Asset("IMAGE", "images/iteminfo_images.tex"),

	Asset("ATLAS", "images/iteminfo_planar.xml"),
	Asset("IMAGE", "images/iteminfo_planar.tex"),
}

local ItemInfoTooltip = _G.require("iteminfo_updated/widgets/tooltip")
local ItemInfoEquipPanel = _G.require("iteminfo_updated/widgets/equippanel")

--------------------------------------------------------------------------
-- HUD

AddClassPostConstruct("widgets/controls", function(controls)
	-- If the widgets can't be created (e.g. another mod changed the HUD), the mod turns itself off
	-- instead of breaking the HUD
	local ok, err = _G.pcall(function()
		controls.iteminfo_equippanel = controls.bottomright_root:AddChild(ItemInfoEquipPanel(controls))
		controls.iteminfo_tooltip = controls:AddChild(ItemInfoTooltip(controls))
	end)
	if not ok then
		print("[Item Info Reworked] Could not create the HUD widgets: "..tostring(err))
	end
end)

--------------------------------------------------------------------------
-- Toggle key

local toggle_key = Config("TOGGLE_KEY", false)
local toggle_keycode = type(toggle_key) == "string" and _G.rawget(_G, toggle_key) or nil
if toggle_keycode ~= nil then
	_G.TheInput:AddKeyDownHandler(toggle_keycode, function()
		local player = _G.ThePlayer
		local screen = _G.TheFrontEnd:GetActiveScreen()
		-- Only while playing, never while typing in chat or a menu is open
		if player == nil or player.HUD == nil or screen ~= player.HUD then
			return
		end
		_G.ITEMINFO_UPDATED.enabled = not _G.ITEMINFO_UPDATED.enabled
	end)
end
