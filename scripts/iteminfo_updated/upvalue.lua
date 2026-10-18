-- Reads values the game keeps inside its own functions (Lua upvalues), so the mod follows the game's numbers
-- instead of copies of them. Callers check what comes back and keep their own value when it doesn't fit.

local Upvalue = {}

-- The upvalue called name of fn, or nil
function Upvalue.Get(fn, name)
	local debuglib = rawget(_G, "debug")
	if type(fn) ~= "function" or debuglib == nil or debuglib.getupvalue == nil then
		return nil
	end
	for i = 1, 255 do
		local upname, value = debuglib.getupvalue(fn, i)
		if upname == nil then
			return nil
		elseif upname == name then
			return value
		end
	end
end

-- Searches fn's upvalues, and those of the functions among them, up to depth levels, for one called name
-- (finds the value even when the functions holding it get renamed)
function Upvalue.Find(fn, name, depth)
	local debuglib = rawget(_G, "debug")
	if debuglib == nil or debuglib.getupvalue == nil then
		return nil
	end
	local level, seen = { fn }, {}
	for _ = 1, depth or 3 do
		local nextlevel = {}
		for _, f in ipairs(level) do
			if type(f) == "function" and not seen[f] then
				seen[f] = true
				local value = Upvalue.Get(f, name)
				if value ~= nil then
					return value
				end
				for i = 1, 255 do
					local upname, upvalue = debuglib.getupvalue(f, i)
					if upname == nil then
						break
					elseif type(upvalue) == "function" then
						table.insert(nextlevel, upvalue)
					end
				end
			end
		end
		level = nextlevel
	end
end

-- The same search over every function of a table (a component class)
function Upvalue.FindIn(t, name, depth)
	if type(t) ~= "table" then
		return nil
	end
	for _, fn in pairs(t) do
		local value = type(fn) == "function" and Upvalue.Find(fn, name, depth) or nil
		if value ~= nil then
			return value
		end
	end
end

-- A prefab's constructor (Prefabs[name].fn), or nil
function Upvalue.PrefabFn(name)
	local prefabs = rawget(_G, "Prefabs")
	local prefab = type(prefabs) == "table" and prefabs[name] or nil
	return type(prefab) == "table" and type(prefab.fn) == "function" and prefab.fn or nil
end

-- A list of n numbers (ascending if asked), else nil
function Upvalue.Numbers(value, n, ascending)
	if type(value) ~= "table" or #value ~= n then
		return nil
	end
	for i = 1, n do
		if type(value[i]) ~= "number" or (ascending and i > 1 and value[i] <= value[i - 1]) then
			return nil
		end
	end
	return value
end

return Upvalue
