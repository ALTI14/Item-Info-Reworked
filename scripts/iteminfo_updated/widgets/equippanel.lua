-- Bottom right panel with the stats of the equipped items.
-- Blocks are right aligned and stacked bottom to top (hands, body, head), and only
-- rebuilt / re-laid out when something they display actually changed.

local Widget = require "widgets/widget"
local Image = require "widgets/image"
local StatsView = require "iteminfo_updated/widgets/statsview"
local Stats = require "iteminfo_updated/stats"

local IIU = ITEMINFO_UPDATED
local CFG = IIU.config

local REFRESH_TIME = .2
local ICON_SIZE = 64
local ICON_GAP = 12
local BLOCK_PADDING = 10
local BLOCK_SPACING = 12
local BACKPACK_CLEARANCE = 230 -- width of the side backpack widget, in HUD units

--------------------------------------------------------------------------

local EquipBlock = Class(Widget, function(self, equipslot, owner)
	Widget._ctor(self, "ItemInfoEquipBlock")
	self.equipslot = equipslot
	self.owner = owner
	self:SetClickable(false)

	if CFG.equip_background > 0 then
		self.bg = self:AddChild(Image("images/global.xml", "square.tex"))
		self.bg:SetTint(0, 0, 0, CFG.equip_background)
	end
	self.icon = self:AddChild(Image())
	self.view = self:AddChild(StatsView(0))

	self.item = nil
	self.image = nil
	self.signature = nil
	self.width = 0
	self.height = 0

	self:Hide()
end)

function EquipBlock:GetSize()
	return self.width, self.height
end

function EquipBlock:Layout()
	local view_w, view_h = self.view:GetSize()
	local content_w = ICON_SIZE + (view_w > 0 and ICON_GAP + view_w or 0)
	local content_h = math.max(ICON_SIZE, view_h)

	self.width = content_w + BLOCK_PADDING * 2
	self.height = content_h + BLOCK_PADDING * 2

	local left = -content_w / 2
	self.icon:SetPosition(left + ICON_SIZE / 2, 0)
	self.view:SetPosition(left + ICON_SIZE + ICON_GAP + view_w / 2, 0)
	if self.bg ~= nil then
		self.bg:SetSize(self.width, self.height)
	end
end

-- Returns true when the block's size or visibility changed
function EquipBlock:Refresh()
	local inventory = self.owner.replica.inventory
	local item = inventory ~= nil and inventory:GetEquippedItem(self.equipslot) or nil

	local rows, signature = nil, ""
	if item ~= nil then
		rows, signature = Stats.GetRows(item, self.owner, self.owner)
	end

	-- Nothing to show: hide and forget everything, so re-equipping the same item rebuilds it
	if item == nil or #rows == 0 then
		local was_shown = self.shown
		self.item = nil
		self.image = nil
		self.signature = nil
		self.view:Clear()
		self:Hide()
		return was_shown
	end

	local changed = false

	local inventoryitem = item.replica.inventoryitem
	local atlas, image = inventoryitem:GetAtlas(), inventoryitem:GetImage()
	if item ~= self.item or image ~= self.image then
		self.item = item
		self.image = image
		if atlas ~= nil and image ~= nil then
			self.icon:SetTexture(atlas, image)
			self.icon:SetSize(ICON_SIZE, ICON_SIZE)
		end
	end

	if signature ~= self.signature then
		self.signature = signature
		local old_w, old_h = self.width, self.height
		self.view:SetRows(rows)
		self:Layout()
		changed = old_w ~= self.width or old_h ~= self.height
	end

	if not self.shown then
		self:Show()
		changed = true
	end

	return changed
end

--------------------------------------------------------------------------

local ItemInfoEquipPanel = Class(Widget, function(self, controls)
	Widget._ctor(self, "ItemInfoEquipPanel")
	self.controls = controls
	self.owner = controls.owner
	self:SetClickable(false)
	self:SetScale(CFG.equip_scale)

	self.base_x = -CFG.margin_h
	self.target_x = self.base_x
	self:SetPosition(self.base_x, CFG.margin_v, 0)

	self.blocks = {}
	local slots = {}
	if CFG.show_hands then
		table.insert(slots, EQUIPSLOTS.HANDS)
	end
	if CFG.show_body then
		table.insert(slots, EQUIPSLOTS.BODY)
		-- Extra slots added by mods (backpack, amulet...), shown with the body. Sorted so the
		-- order never changes. The beard slot (Wilson's skill) holds no stats.
		local extra = {}
		local seen = {}
		for _, slot in pairs(EQUIPSLOTS) do
			if type(slot) == "string" and not seen[slot] and slot ~= EQUIPSLOTS.HANDS and slot ~= EQUIPSLOTS.HEAD
				and slot ~= EQUIPSLOTS.BODY and slot ~= EQUIPSLOTS.BEARD then
				seen[slot] = true -- mods sometimes alias several names to one slot
				table.insert(extra, slot)
			end
		end
		table.sort(extra)
		for _, slot in ipairs(extra) do
			table.insert(slots, slot)
		end
	end
	if CFG.show_head then
		table.insert(slots, EQUIPSLOTS.HEAD)
	end
	for _, equipslot in ipairs(slots) do
		table.insert(self.blocks, self:AddChild(EquipBlock(equipslot, self.owner)))
	end

	self.timer = REFRESH_TIME
	if #self.blocks > 0 then
		self:StartUpdating()
	end
end)

function ItemInfoEquipPanel:Layout()
	local y = 0
	for _, block in ipairs(self.blocks) do
		if block.shown then
			local w, h = block:GetSize()
			block:SetPosition(-w / 2, y + h / 2)
			y = y + h + BLOCK_SPACING
		end
	end
end

function ItemInfoEquipPanel:IsSideBackpackOpen()
	local inv = self.controls.inv
	if inv == nil or inv.integrated_backpack then
		return false
	end
	local inventory = self.owner.replica.inventory
	local overflow = inventory ~= nil and inventory:GetOverflowContainer() or nil
	return overflow ~= nil and overflow:IsOpenedBy(self.owner)
end

function ItemInfoEquipPanel:UpdateBackpackOffset()
	local x = self.base_x
	if CFG.avoid_backpack and self:IsSideBackpackOpen() then
		x = math.min(x, -BACKPACK_CLEARANCE)
	end
	if x ~= self.target_x then
		self.target_x = x
		local pos = self:GetPosition()
		self:CancelMoveTo()
		self:MoveTo(pos, Vector3(x, CFG.margin_v, 0), .15)
	end
end

function ItemInfoEquipPanel:DoUpdate(dt)
	if not IIU.enabled then
		if self.shown then
			self:Hide()
		end
		return
	elseif not self.shown then
		self:Show()
		self.timer = REFRESH_TIME
	end

	self.timer = self.timer + dt
	if self.timer < REFRESH_TIME then
		return
	end
	self.timer = 0

	local changed = false
	for _, block in ipairs(self.blocks) do
		if block:Refresh() then
			changed = true
		end
	end
	if changed then
		self:Layout()
	end

	self:UpdateBackpackOffset()
end

-- An error here must never crash the game: log it once, hide, and try again next refresh
function ItemInfoEquipPanel:OnUpdate(dt)
	if self.retry_time ~= nil then
		if GetTime() < self.retry_time then
			return
		end
		self.retry_time = nil
	end
	local ok, err = pcall(self.DoUpdate, self, dt)
	if not ok then
		if not self.failed then
			self.failed = true
			print("[Item Info Reworked] Equipped panel error: "..tostring(err))
		end
		self.timer = 0
		self.retry_time = GetTime() + 5
		pcall(self.Hide, self)
	end
end

return ItemInfoEquipPanel
