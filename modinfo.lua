-- NOTE: modinfo.lua runs in an empty environment (no string, math, ipairs...), only plain Lua.
-- The game provides "locale" (LOC.GetLocaleCode()): zh = Simplified, zhr = WeGame, zht = Traditional.

local CHINESE = locale == "zh" or locale == "zhr" or locale == "zht"

local function T(en, zh)
	return CHINESE and zh or en
end

name = T("Item Info Reworked", "物品信息 重制版 (Item Info Reworked)")
description = T([[Version 2.0.0

Shows item stats when hovering over inventory, equipment and container slots, plus a panel with your equipped items' stats.

Food: hunger, sanity, health for YOUR character (stale/spoiled food, spices, favorite foods with a star, character diets), warming/cooling food.
Spoilage: freshness, time until stale and until rotten, including fridges, Polar Bearger Bin, salt box, fish box, seed pouch, mushroom lights, frozen items and season effects.
Combat: damage with character multipliers, planar damage/defense with lunar/shadow icons, bonus damage vs an alignment, set bonuses and skill tree perks, slingshot ammo, Wortox's knapsack.
Clothing: sanity/min, movement speed, insulation, waterproofing.
Durability: uses left, fuel time, armor durability, thermal stone uses and temperature, health of bumpers, walls and boats once placed.

Client only, works on any server. A hotkey can toggle the mod in game.]], [[版本 2.0.0

鼠标悬停在物品栏、装备栏和容器格子上时显示物品属性，并在屏幕右下角显示已装备物品的属性。

食物：按你的角色计算的饥饿、理智、生命（新鲜度、调味料、带星标的最爱食物、角色饮食规则），以及升温/降温食物。
腐烂：新鲜度、变质时间与腐烂时间，支持冰箱、极地熊獾桶、盐盒、鱼箱、种子袋、蘑菇灯、冷冻物品和季节影响。
战斗：含角色倍率的伤害、带月亮/暗影图标的位面伤害/位面防御、对阵营的额外伤害、套装加成和技能树加成、弹弓弹药、沃拓克斯的掠夺袋。
衣物：每分钟理智、移动速度、保暖/隔热、防水。
耐久：剩余次数、燃料时间、护甲耐久、暖石次数与温度，以及保险杠、墙和船放置后的生命值。

纯客户端模组，可在任何服务器使用。游戏中可用快捷键开关。]])
author = "Alti"
version = "2.0.0"
icon_atlas = "item_info.xml"
icon = "item_info.tex"
forumthread = ""
api_version_dst = 10
priority = 100

dont_starve_compatible = false
reign_of_giants_compatible = false
shipwrecked_compatible = false
dst_compatible = true

all_clients_require_mod = false
client_only_mod = true

server_filter_tags = {}

local header_count = 0
local function Header(en, zh)
	header_count = header_count + 1
	return { name = "HEADER_"..header_count, label = T(en, zh), hover = "", options = { { description = "", data = 0 } }, default = 0 }
end

local YES = T("Yes", "是")
local NO = T("No", "否")

local function YesNo(name, label, hover, default)
	return
	{
		name = name,
		label = label,
		hover = hover,
		options =
		{
			{ description = YES, data = true },
			{ description = NO, data = false },
		},
		default = default,
	}
end

-- Values are built from whole hundredths so 0.8 is exactly the same number as the default .8
local function Range(from, to, step)
	local options = {}
	local value = from * 100
	local last = to * 100 + step * 50
	local hundredth_step = step * 100
	while value <= last do
		local rounded = value - value % 1
		if value % 1 >= .5 then
			rounded = rounded + 1
		end
		local data = rounded / 100
		options[#options + 1] = { description = ""..data, data = data }
		value = value + hundredth_step
	end
	return options
end

local BACKGROUND_OPACITY =
{
	{ description = T("Off", "关闭"), data = 0 },
	{ description = "25%", data = .25 },
	{ description = "35%", data = .35 },
	{ description = "45%", data = .45 },
	{ description = "55%", data = .55 },
	{ description = "65%", data = .65 },
	{ description = "75%", data = .75 },
	{ description = "85%", data = .85 },
}

local KEY_NAMES =
{
	"F1", "F2", "F3", "F4", "F5", "F6", "F7", "F8", "F9", "F10", "F11", "F12",
	"A", "B", "C", "D", "E", "F", "G", "H", "I", "J", "K", "L", "M",
	"N", "O", "P", "Q", "R", "S", "T", "U", "V", "W", "X", "Y", "Z",
	"INSERT", "HOME", "PAGEUP", "PAGEDOWN", "END", "DELETE",
}
local keys = { { description = T("None", "无"), data = false } }
for i = 1, #KEY_NAMES do
	keys[#keys + 1] = { description = KEY_NAMES[i], data = "KEY_"..KEY_NAMES[i] }
end

configuration_options =
{
	Header("Tooltip", "悬停信息"),
	{
		name = "INFO_SCALE",
		label = T("Tooltip scale", "信息大小"),
		hover = T("Size of the info shown above hovered items.", "悬停物品时显示的信息大小。"),
		options = Range(.4, 1.5, .05),
		default = .8,
	},
	{
		name = "TOOLTIP_OFFSET",
		label = T("Tooltip height", "信息高度"),
		hover = T("Moves the tooltip up or down, e.g. to make room for Insight's tooltips.", "上下移动信息位置，例如给 Insight 的提示留出空间。"),
		options = Range(-60, 300, 20),
		default = 0,
	},
	{
		name = "TOOLTIP_BACKGROUND",
		label = T("Tooltip background", "信息背景"),
		hover = T("Opacity of the dark background behind the tooltip. Off removes it.", "信息后方深色背景的不透明度。选择关闭则不显示背景。"),
		options = BACKGROUND_OPACITY,
		default = .55,
	},
	YesNo("CONTAINER_TOOLTIPS", T("Chest tooltips", "容器内物品信息"),
		T("Show the tooltip for items in chests, iceboxes and other containers.", "显示箱子、冰箱等容器中物品的信息。"), true),

	Header("Shown info", "显示内容"),
	YesNo("SHOW_FOOD", T("Food", "食物"),
		T("Hunger, sanity and health gained from eating, healing items and warming/cooling food.", "食用获得的饥饿、理智、生命，治疗物品，以及升温/降温食物。"), true),
	{
		name = "PERISHABLE",
		label = T("Spoilage", "腐烂"),
		hover = T("Freshness percentage, time until stale and time until rotten.", "新鲜度百分比、变质时间和腐烂时间。"),
		options =
		{
			{ description = T("Rot time only", "仅腐烂时间"), data = 0, hover = T("Freshness and time until rotten.", "新鲜度和腐烂时间。") },
			{ description = T("Stale > rot", "变质 > 腐烂"), data = 1, hover = T("Time until stale while fresh, then time until rotten.", "新鲜时显示变质时间，之后显示腐烂时间。") },
			{ description = T("Show all", "全部显示"), data = 2, hover = T("Freshness, time until stale and time until rotten.", "新鲜度、变质时间和腐烂时间。") },
			{ description = T("Hide", "隐藏"), data = 3 },
		},
		default = 2,
	},
	YesNo("SHOW_COMBAT", T("Combat", "战斗"),
		T("Damage, planar damage, armor, planar defense and armor durability.", "伤害、位面伤害、护甲、位面防御和护甲耐久。"), true),
	YesNo("SHOW_CLOTHING", T("Clothing", "衣物"),
		T("Sanity per minute, movement speed, insulation and waterproofing.", "每分钟理智、移动速度、保暖/隔热和防水。"), true),
	YesNo("SHOW_DURABILITY", T("Durability", "耐久"),
		T("Uses left and fuel / wear time.", "剩余使用次数和燃料/穿戴时间。"), true),
	YesNo("SHOW_REFUSED_FOOD", T("Food you refuse", "拒绝的食物"),
		T("Also show (greyed out) stats of food your character refuses, like meat for Wurt or veggies for Wigfrid.", "同时以灰色显示角色拒绝食用的食物属性，例如沃特的肉类或薇格弗德的蔬菜。"), false),
	{
		name = "TIME_FORMAT",
		label = T("Time format", "时间格式"),
		hover = T("How spoil and fuel times are shown.", "腐烂和燃料时间的显示方式。"),
		options =
		{
			{ description = "h:mm:ss", data = 0 },
			{ description = T("Days", "天"), data = 1 },
		},
		default = 0,
	},
	YesNo("SHOW_PREFABNAME", T("Prefab name", "预设名"),
		T("Show the item's prefab (spawn) name.", "显示物品的预设名（生成代码名）。"), false),

	Header("Equipped items panel", "已装备物品面板"),
	YesNo("SHOW_INFO_HANDS", T("Show hands", "显示手部"),
		T("Show your hand item's info in the bottom right corner.", "在右下角显示手部装备的信息。"), true),
	YesNo("SHOW_INFO_BODY", T("Show body", "显示身体"),
		T("Show your body item's info in the bottom right corner.", "在右下角显示身体装备的信息。"), true),
	YesNo("SHOW_INFO_HEAD", T("Show head", "显示头部"),
		T("Show your head item's info in the bottom right corner.", "在右下角显示头部装备的信息。"), true),
	{
		name = "EQUIP_SCALE",
		label = T("Panel scale", "面板大小"),
		hover = T("Size of the equipped items panel.", "已装备物品面板的大小。"),
		options = Range(.3, 1, .02),
		default = .46,
	},
	{
		name = "SHOW_BACKGROUND",
		label = T("Panel background", "面板背景"),
		hover = T("Opacity of the dark background behind each equipped item. Off removes it.", "每个已装备物品后方深色背景的不透明度。选择关闭则不显示背景。"),
		options = BACKGROUND_OPACITY,
		default = .45,
	},
	{
		name = "HORIZONTAL_MARGIN",
		label = T("Panel right margin", "面板右边距"),
		hover = T("Distance between the panel and the right edge of the screen.", "面板与屏幕右边缘的距离。"),
		options = Range(0, 800, 10),
		default = 100,
	},
	{
		name = "VERTICAL_MARGIN",
		label = T("Panel bottom margin", "面板下边距"),
		hover = T("Distance between the panel and the bottom edge of the screen.", "面板与屏幕下边缘的距离。"),
		options = Range(0, 800, 10),
		default = 100,
	},
	YesNo("AVOID_BACKPACK", T("Move for backpack", "为背包让位"),
		T("Move the panel left while a backpack is open on the side of the screen (not used with the integrated backpack layout).",
			"背包在屏幕侧边打开时将面板左移（使用整合背包布局时无效）。"), false),

	Header("Other", "其他"),
	{
		name = "TOGGLE_KEY",
		label = T("Toggle key", "开关快捷键"),
		hover = T("Key that turns the tooltips and the panel on and off in game.", "在游戏中开启/关闭悬停信息和面板的按键。"),
		options = keys,
		default = false,
	},
	YesNo("ENABLER", T("Use with Insight / Show Me", "与 Insight / Show Me 同时使用"),
		T("No: the mod turns itself off on servers running Insight, Show Me or Show Me (中文), to avoid duplicated info.",
			"选择否：在启用了 Insight、Show Me 或 Show Me (中文) 的服务器上自动关闭本模组，避免信息重复。"), true),
}
