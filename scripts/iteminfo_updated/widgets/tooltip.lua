-- One shared tooltip for every item slot.
--
-- Instead of attaching a widget to each slot (which leaked and left stuck tooltips behind
-- whenever the inventory bar was rebuilt, e.g. when swapping a backpack for armor), the
-- tooltip looks up the hovered / controller-selected slot every frame. If the slot is gone,
-- hidden or empty, the tooltip simply hides.
--
-- Placement:
--  * inventory bar / equipment: above the game's own hover text (item name + actions)
--  * containers (chests, side backpack...): beside the container, so no slot is covered

local Widget = require "widgets/widget"
local ItemSlot = require "widgets/itemslot"
local ContainerWidget = require "widgets/containerwidget"
local StatsView = require "iteminfo_updated/widgets/statsview"
local Stats = require "iteminfo_updated/stats"

local IIU = ITEMINFO_UPDATED
local CFG = IIU.config

local REFRESH_TIME = .2
local SLOT_HALF_SIZE = 32  -- item slots are 64x64
local ABOVE_GAP = 8        -- between the hover text and the tooltip, screen pixels
local ABOVE_GAP_CONTROLLER = 120 -- slot units, when the action text isn't known
local SIDE_GAP = 40        -- slot units: clears the container frame around the slots, plus a margin
local SCREEN_MARGIN = 8

local function FindAncestor(widget, class, max_depth)
	local depth = 0
	while widget ~= nil and depth < max_depth do
		if widget.is_a ~= nil and widget:is_a(class) then
			return widget
		end
		widget = widget.parent
		depth = depth + 1
	end
end

-- Top of a Text widget, in screen pixels, given the screen y of its parent's origin
local function GetTextTop(text, parent_y, parent_scale_y)
	if text == nil or not text.shown then
		return nil
	end
	local pos = text:GetPosition()
	local _, h = text:GetRegionSize()
	return parent_y + (pos.y + h / 2) * parent_scale_y
end

local ItemInfoTooltip = Class(Widget, function(self, controls)
	Widget._ctor(self, "ItemInfoTooltip")
	self.controls = controls
	self.owner = controls.owner

	-- Same setup as the game's hover text: positioned in screen pixels, scaled with the screen
	self:SetScaleMode(SCALEMODE_PROPORTIONAL)
	self:SetMaxPropUpscale(MAX_HUD_SCALE)
	self:SetClickable(false)

	self.scaler = self:AddChild(Widget("scaler"))
	self.view = self.scaler:AddChild(StatsView(CFG.tooltip_background))

	self.slot = nil
	self.item = nil
	self.signature = nil
	self.timer = 0
	self.failed = false

	self:Hide()
	self:StartUpdating()
end)

function ItemInfoTooltip:GetScaleFactor()
	return CFG.info_scale * TheFrontEnd:GetHUDScale()
end

function ItemInfoTooltip:GetTargetSlot()
	if TheInput:ControllerAttached() then
		local inv = self.controls.inv
		return inv ~= nil and inv.open and inv.active_slot or nil
	end
	local entity = TheInput:GetHUDEntityUnderMouse()
	return entity ~= nil and entity.widget ~= nil and FindAncestor(entity.widget, ItemSlot, 6) or nil
end

function ItemInfoTooltip:GetHolder(slot)
	local container = slot.container
	if type(container) == "table" and container.inst ~= nil and container.inst:IsValid() then
		return container.inst
	end
	return self.owner
end

-- Chests, iceboxes etc. (anything that is neither the player nor their open backpack)
function ItemInfoTooltip:IsExternalContainer(holder)
	if holder == self.owner then
		return false
	end
	local inventory = self.owner.replica.inventory
	local overflow = inventory ~= nil and inventory:GetOverflowContainer() or nil
	return overflow == nil or overflow.inst ~= holder
end

function ItemInfoTooltip:Clear()
	if self.item == nil and self.signature == nil and not self.shown then
		return
	end
	self.slot = nil
	self.item = nil
	self.signature = nil
	self.view:Clear()
	if self.shown then
		self:Hide()
	end
end

-- Lowest y the tooltip's bottom may have above an inventory bar slot
function ItemInfoTooltip:GetBottomAboveSlot(slot_top, slot_scale)
	local bottom = slot_top + ABOVE_GAP

	if TheInput:ControllerAttached() then
		-- The inventory bar shows the selected item's name and actions above the slot
		local inv = self.controls.inv
		local actionstring = inv ~= nil and inv.actionstring or nil
		if actionstring ~= nil and actionstring:IsVisible() then
			local pos = actionstring:GetWorldPosition()
			local scale = actionstring:GetScale()
			local top = GetTextTop(inv.actionstringtitle, pos.y, scale.y)
			if top ~= nil then
				return math.max(bottom, top + ABOVE_GAP)
			end
		end
		return slot_top + ABOVE_GAP_CONTROLLER * slot_scale.y
	end

	-- Mouse: the hover text sits above the cursor. Measure it as if the cursor was on the top
	-- edge of the slot (the highest it can be), so the tooltip doesn't move with the mouse.
	local hover = self.controls.hover
	if hover ~= nil and hover.shown and hover.text ~= nil and hover.str ~= nil then
		local top = GetTextTop(hover.text, slot_top, hover:GetScale().y)
		if top ~= nil then
			bottom = math.max(bottom, top + ABOVE_GAP)
		end
	end
	return bottom
end

function ItemInfoTooltip:UpdatePosition(slot)
	local view_w, view_h = self.view:GetSize()
	-- Use the final scale, not the one mid pop-in animation, so the position doesn't jump
	local scale = self:GetScale()
	local factor = self:GetScaleFactor()
	local half_w = view_w * scale.x * factor / 2
	local half_h = view_h * scale.y * factor / 2

	local slot_pos = slot:GetWorldPosition()
	local slot_scale = slot:GetScale()
	local screen_w, screen_h = TheSim:GetScreenSize()
	local offset = CFG.tooltip_offset * slot_scale.y

	local x, y
	local container_widget = FindAncestor(slot, ContainerWidget, 8)
	if container_widget ~= nil and type(container_widget.inv) == "table" then
		-- Beside the whole container: right side, or left when there's no room
		local left, right = slot_pos.x, slot_pos.x
		for _, other in pairs(container_widget.inv) do
			if type(other) == "table" and other.GetWorldPosition ~= nil and other.inst ~= nil and other.inst:IsValid() then
				local pos = other:GetWorldPosition()
				left = math.min(left, pos.x)
				right = math.max(right, pos.x)
			end
		end
		local slot_half_w = SLOT_HALF_SIZE * slot_scale.x
		local side_gap = SIDE_GAP * slot_scale.x
		x = right + slot_half_w + side_gap + half_w
		if x + half_w > screen_w - SCREEN_MARGIN then
			x = left - slot_half_w - side_gap - half_w
		end
		y = slot_pos.y + offset
	else
		local slot_top = slot_pos.y + SLOT_HALF_SIZE * slot_scale.y
		y = self:GetBottomAboveSlot(slot_top, slot_scale) + offset + half_h
		x = slot_pos.x
	end

	-- Keep it on screen
	x = math.clamp(x, half_w + SCREEN_MARGIN, math.max(half_w + SCREEN_MARGIN, screen_w - half_w - SCREEN_MARGIN))
	y = math.clamp(y, half_h + SCREEN_MARGIN, math.max(half_h + SCREEN_MARGIN, screen_h - half_h - SCREEN_MARGIN))

	-- Only touch the transform when the tooltip actually moves
	if x ~= self.pos_x or y ~= self.pos_y then
		self.pos_x, self.pos_y = x, y
		self:SetPosition(x, y, 0)
	end
end

function ItemInfoTooltip:DoUpdate(dt)
	if not IIU.enabled then
		self:Clear()
		return
	end

	local slot = self:GetTargetSlot()
	local tile = slot ~= nil and slot.tile or nil
	local item = tile ~= nil and tile.item or nil
	if item ~= nil and (not item:IsValid() or not slot:IsVisible()) then
		item = nil
	end

	local holder = item ~= nil and self:GetHolder(slot) or nil
	if item ~= nil and not CFG.container_tooltips and self:IsExternalContainer(holder) then
		item = nil
	end

	if item == nil then
		self:Clear()
		return
	end

	local is_new = item ~= self.item
	if is_new or slot ~= self.slot then
		self.slot = slot
		self.item = item
		self.timer = REFRESH_TIME
	end

	self.timer = self.timer + dt
	if self.timer >= REFRESH_TIME then
		self.timer = 0
		local rows, signature = Stats.GetRows(item, holder, self.owner)
		if signature ~= self.signature then
			self.signature = signature
			self.view:SetRows(rows)
		end
	end

	if self.view:IsEmpty() then
		if self.shown then
			self:Hide()
		end
		return
	end

	if not self.shown or is_new then
		local scale = self:GetScaleFactor()
		self.scaler:CancelScaleTo()
		self.scaler:ScaleTo(scale * .9, scale, .1)
		self:Show()
	end

	self:UpdatePosition(slot)
end

-- An error here must never crash the game: log it once, hide, and try again on the next frame
function ItemInfoTooltip:OnUpdate(dt)
	local ok, err = pcall(self.DoUpdate, self, dt)
	if not ok then
		if not self.failed then
			self.failed = true
			print("[Item Info Reworked] Tooltip error: "..tostring(err))
		end
		pcall(self.Clear, self)
	end
end

return ItemInfoTooltip
