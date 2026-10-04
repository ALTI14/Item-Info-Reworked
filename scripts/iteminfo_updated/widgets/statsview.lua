-- Renders rows of {icon, text} cells, left aligned, centred on the widget origin.
--
-- Widgets are only created when the layout (which icons, in which rows) changes. When only
-- values change (timers ticking, durability going down) the existing texts are updated in
-- place and re-positioned, which is much cheaper than rebuilding everything.

local Widget = require "widgets/widget"
local Image = require "widgets/image"
local Text = require "widgets/text"

local ICON_SIZE = 38
local ICON_GAP = 6
local CELL_GAP = 22
local ROW_HEIGHT = 46
local FONT_SIZE = 40
local PADDING_X = 16
local PADDING_Y = 8

local WHITE = { 1, 1, 1, 1 }

-- background_alpha: opacity of the dark background, 0 or nil for none
local StatsView = Class(Widget, function(self, background_alpha)
	Widget._ctor(self, "ItemInfoStatsView")
	self:SetClickable(false)

	if background_alpha ~= nil and background_alpha > 0 then
		self.bg = self:AddChild(Image("images/global.xml", "square.tex"))
		self.bg:SetTint(0, 0, 0, background_alpha)
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
	return self.width + PADDING_X * 2, self.height + PADDING_Y * 2
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
			local icon_size = cell.icon_size or ICON_SIZE
			local icon = self.content:AddChild(Image(cell.atlas, cell.tex))
			icon:SetSize(icon_size, icon_size)
			-- Icon only cells (e.g. the favorite food star) have no text
			local text = HasText(cell) and self.content:AddChild(Text(NUMBERFONT, FONT_SIZE)) or nil
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
	local width = 0
	for r, row in ipairs(rows) do
		local cells = self.built[r]
		local x = 0
		for i, cell in ipairs(row) do
			local built = cells[i]
			if i > 1 then
				x = x + (cell.gap or CELL_GAP)
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
			x = x + built.icon_size + (built.text ~= nil and ICON_GAP + built.text_w or 0)
		end
		width = math.max(width, x)
	end

	self.width = width
	self.height = #rows * ROW_HEIGHT

	-- Position
	local left = -width / 2
	local top = self.height / 2
	for r, cells in ipairs(self.built) do
		local y = top - (r - .5) * ROW_HEIGHT
		for _, built in ipairs(cells) do
			built.icon:SetPosition(left + built.x + built.icon_size / 2, y)
			if built.text ~= nil then
				built.text:SetPosition(left + built.x + built.icon_size + ICON_GAP + built.text_w / 2, y)
			end
		end
	end

	if self.bg ~= nil then
		local w, h = self:GetSize()
		self.bg:SetSize(w, h)
		self.bg:Show()
	end
end

return StatsView
