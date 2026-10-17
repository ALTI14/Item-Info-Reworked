-- Renders rows of {icon, text} cells, centred on the widget origin.
--
-- Widgets are only created when the layout (which icons, in which rows) changes. When only
-- values change (timers ticking, durability going down) the existing texts are updated in
-- place and re-positioned, which is much cheaper than rebuilding everything.

local Widget = require "widgets/widget"
local Image = require "widgets/image"
local Text = require "widgets/text"
local NineSlice = require "widgets/nineslice"

-- Dark rounded panel with a thin warm border (images/iteminfo_panel, made by icon_tools/make_panel.js).
-- NineSlice puts the 15px corners outside its centre, so the centre is sized smaller by 2 * PANEL_CORNER.
local PANEL_ATLAS = "images/iteminfo_panel.xml"
local PANEL_CORNER = 15
local PANEL_DEFAULT_ALPHA = .55 -- the setting's default maps to the panel at full strength

-- "reworked": left aligned rows, larger icons and spacing.
-- "classic": the layout of the original Item Info (centered rows, 32px icons, 48px rows, font 42).
local STYLES =
{
	reworked = { icon = 38, icon_gap = 6, cell_gap = 22, row = 46, font = 40, center_rows = false, bottom_up = false, pad_x = 20, pad_y = 12 },
	-- classic: first row at the bottom, rows stacked upward, no padding (widgets/iteminfo_desc.lua AddChild1/2/3)
	classic = { icon = 32, icon_gap = 5, cell_gap = 10, row = 48, font = 42, center_rows = true, bottom_up = true, pad_x = 0, pad_y = 0 },
}
local DEFAULT_ICON = STYLES.reworked.icon -- cell.icon_size values are given for this size

local WHITE = { 1, 1, 1, 1 }

-- background_alpha: opacity of the dark background, 0 or nil for none
-- style: "reworked" (default) or "classic"
local StatsView = Class(Widget, function(self, background_alpha, style)
	Widget._ctor(self, "ItemInfoStatsView")
	self:SetClickable(false)
	self.style = STYLES[style] or STYLES.reworked

	if background_alpha ~= nil and background_alpha > 0 then
		self.bg = self:AddChild(NineSlice(PANEL_ATLAS))
		self.bg:SetTint(1, 1, 1, math.min(1, background_alpha / PANEL_DEFAULT_ALPHA))
		self.bg:Hide()
	end
	self.content = self:AddChild(Widget("content"))

	self.built = nil
	self.layout_key = nil
	self.width = 0
	self.height = 0
end)

function StatsView:Clear()
	if self.built == nil then
		return
	end
	self.content:KillAllChildren()
	self.built = nil
	self.layout_key = nil
	self.width = 0
	self.height = 0
	if self.bg ~= nil then
		self.bg:Hide()
	end
end

function StatsView:IsEmpty()
	return self.height <= 0
end

-- Size of the content including the background padding, in local units
function StatsView:GetSize()
	if self.height <= 0 then
		return 0, 0
	end
	return self.width + self.style.pad_x * 2, self.height + self.style.pad_y * 2
end

local function HasText(cell)
	return cell.text ~= nil and cell.text ~= ""
end

local function GetLayoutKey(rows)
	local parts = {}
	for _, row in ipairs(rows) do
		for _, cell in ipairs(row) do
			parts[#parts + 1] = tostring(cell.atlas)
			parts[#parts + 1] = tostring(cell.tex)
			parts[#parts + 1] = HasText(cell) and "t" or "-"
		end
		parts[#parts + 1] = "\n"
	end
	return table.concat(parts, "|")
end

function StatsView:Build(rows)
	self.content:KillAllChildren()
	self.built = {}
	for _, row in ipairs(rows) do
		local cells = {}
		for _, cell in ipairs(row) do
			local icon_size = cell.icon_size ~= nil and cell.icon_size * self.style.icon / DEFAULT_ICON or self.style.icon
			local icon = self.content:AddChild(Image(cell.atlas, cell.tex))
			icon:SetSize(icon_size, icon_size)
			-- Icon only cells (e.g. the favorite food star) have no text
			local text = HasText(cell) and self.content:AddChild(Text(NUMBERFONT, self.style.font)) or nil
			table.insert(cells, { icon = icon, text = text, icon_size = icon_size })
		end
		table.insert(self.built, cells)
	end
end

function StatsView:SetRows(rows)
	if rows == nil or #rows == 0 then
		self:Clear()
		return
	end

	local layout_key = GetLayoutKey(rows)
	if layout_key ~= self.layout_key then
		self.layout_key = layout_key
		self:Build(rows)
	end

	-- Update texts and measure
	local style = self.style
	local width = 0
	local row_widths = {}
	for r, row in ipairs(rows) do
		local cells = self.built[r]
		local x = 0
		for i, cell in ipairs(row) do
			local built = cells[i]
			if i > 1 then
				x = x + (cell.gap or style.cell_gap)
			end
			built.x = x
			built.text_w = 0
			if built.text ~= nil then
				if built.string ~= cell.text then
					built.string = cell.text
					built.text:SetString(cell.text)
				end
				local colour = cell.colour or WHITE
				if built.colour ~= colour then
					built.colour = colour
					built.text:SetColour(colour[1], colour[2], colour[3], colour[4])
				end
				built.text_w = built.text:GetRegionSize()
			end
			x = x + built.icon_size + (built.text ~= nil and style.icon_gap + built.text_w or 0)
		end
		row_widths[r] = x
		width = math.max(width, x)
	end

	self.width = width
	self.height = #rows * style.row

	-- Position: rows left aligned in the block (reworked) or each row centered (classic)
	local top = self.height / 2
	for r, cells in ipairs(self.built) do
		local y = style.bottom_up and (-top + (r - .5) * style.row) or (top - (r - .5) * style.row)
		local left = style.center_rows and -row_widths[r] / 2 or -width / 2
		for _, built in ipairs(cells) do
			built.icon:SetPosition(left + built.x + built.icon_size / 2, y)
			if built.text ~= nil then
				built.text:SetPosition(left + built.x + built.icon_size + style.icon_gap + built.text_w / 2, y)
			end
		end
	end

	if self.bg ~= nil then
		local w, h = self:GetSize()
		self.bg:SetSize(math.max(1, w - PANEL_CORNER * 2), math.max(1, h - PANEL_CORNER * 2))
		self.bg:Show()
	end
end

return StatsView
