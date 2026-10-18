-- What a client can read of an item's state: the networked durability and freshness steps
-- (inventoryitem_classified.lua percentused / perish).

local ItemState = {}

local function GetClassified(item)
	return item.replica.inventoryitem ~= nil and item.replica.inventoryitem.classified or nil
end

-- percentused: 0-100, 255 = not used by this item
function ItemState.GetPercentUsed(item)
	local classified = GetClassified(item)
	local value = classified ~= nil and classified.percentused ~= nil and classified.percentused:value() or 255
	return value ~= 255 and value / 100 or nil
end

-- perish: 0-62, 63 = not perishable. The server sends floor(percent * 62 + .5), so a step
-- change happens exactly when the real percent crosses (v +/- .5) / 62. When we see one we
-- anchor to that boundary and count down from it; otherwise we use the step centre.
-- The estimate is always clamped to the range the networked step allows.
local perish_tracking = setmetatable({}, { __mode = "k" })

function ItemState.GetPerishPercent(item, rate)
	-- Hosts: the real component (components/perishable.lua GetPercent), no 1/62 steps to estimate between
	local perishable = item.components ~= nil and item.components.perishable or nil
	if perishable ~= nil and type(perishable.perishremainingtime) == "number" and type(perishable.perishtime) == "number"
		and perishable.perishtime > 0 then
		return math.clamp(perishable.perishremainingtime / perishable.perishtime, 0, 1)
	end

	local classified = GetClassified(item)
	local value = classified ~= nil and classified.perish ~= nil and classified.perish:value() or 63
	if value == 63 then
		return nil
	end

	local now = GetTime()
	local track = perish_tracking[item]
	if track == nil or track.value ~= value then
		local anchor = nil
		if track ~= nil and now - track.seen < 1 then
			if value == track.value - 1 then
				anchor = (value + .5) / 62
			elseif value == track.value + 1 then
				anchor = (value - .5) / 62
			end
		end
		track = { value = value, anchor = anchor, anchor_time = now }
		perish_tracking[item] = track
	end
	track.seen = now

	local percent = value / 62
	if track.anchor ~= nil and rate ~= nil then
		percent = track.anchor - (now - track.anchor_time) * rate
	end
	return math.clamp(percent, math.max(0, (value - .5) / 62), math.min(1, (value + .5) / 62))
end

return ItemState
