<p align="center"><img src="docs/icon.png" width="160" alt="Item Info Reworked"></p>

# Item Info Reworked by Alti

**Item Info Reworked** (v2.0.0) is a **client-only** Don't Starve Together mod that shows item stats when you hover over inventory, equipment and container slots, plus a panel in the bottom right corner with your equipped items' stats. Because it's client-side, it works on any server.

Version 2.0.0 is a complete rework: every script was rewritten, all values follow the current game code, and the old bugs and crashes are fixed.

## What it shows

- **Food:** hunger, sanity and health for **your** character: stale and spoiled food, spices, favorite foods (gold value with a star), character diets (Wurt, Wigfrid, Warly, Wortox, Wormwood, Webber, WX-78, Wickerbottom), and warming/cooling food.
- **Spoilage:** freshness, time until stale and time until rotten. Takes containers into account (Ice Box, Insulated Pack, Polar Bearger Bin, Salt Box, Fish Box, Seed Pouch, mushroom lights...), plus frozen items, wetness and seasons. The timer counts down smoothly.
- **Combat:** damage with character multipliers (Wolfgang's mightiness, Wigfrid, Wendy, Wes, Wanda's age), planar damage and planar defense with lunar/shadow icons, bonus damage against an alignment, set bonuses (shown in green), skill tree perks (allegiance, Wolfgang's planar skills, Wigfrid's helm), slingshot ammo, and Wortox's Knapsack (live damage based on your inventory and souls).
- **Armor:** damage absorption, durability, planar defense and reduced damage from lunar/shadow creatures (including set bonuses).
- **Clothing:** sanity per minute (including wetness and character rules), movement speed, insulation and waterproofing.
- **Durability:** uses left, fuel and wear time, thermal stone uses and temperature, and the health of bumpers, walls and boats once placed.

Low durability (20% or less) is shown in red.

## Highlights of 2.0.0

- Fixed the info getting stuck on screen when swapping a backpack for armor, and the memory leak behind it.
- Fixed crashes (merm tools, gloomerang, Brightshade at 0%, spitter spiders, modded items with missing values). Errors can no longer crash the game.
- When you host a world, values come straight from the game itself, so new characters, skills and balance changes are covered automatically.
- Tooltips sit above the game's own item text, and beside chests instead of covering them.
- Better performance: one shared tooltip, and the info is only rebuilt when a value changes.
- Settings in English and Simplified Chinese, a toggle hotkey, background opacity, per-category on/off, and support for extra equip-slot mods.

## Installation & usage

1. Subscribe to the mod on the [Steam Workshop](https://steamcommunity.com/sharedfiles/filedetails/?id=3118627881).
2. Enable it in the Don't Starve Together **Mods** menu.
3. Configure the settings to your liking.

The mod turns itself off on servers running Insight or Show Me if you set **Use with Insight / Show Me** to *No*.

## Reporting bugs

If something looks wrong, check `Documents\Klei\DoNotStarveTogether\client_log.txt` for lines starting with `[Item Info Reworked]` and include them in your report, together with what you were doing.
