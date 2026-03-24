--!strict
-- Studio Bridge Data Type Serializer
-- Converts Roblox data types to/from JSON-safe tagged format
-- Tagged format: { _type = "Vector3", x = 1, y = 2, z = 3 }

local DataTypeSerializer = {}

-- ── Serialize: Roblox value → JSON-safe table ──

function DataTypeSerializer.serialize(value: any): any
	if value == nil then return nil end

	local t = typeof(value)

	if t == "string" or t == "number" or t == "boolean" then
		return value
	end

	if t == "Vector3" then
		return { _type = "Vector3", x = value.X, y = value.Y, z = value.Z }
	end

	if t == "Vector2" then
		return { _type = "Vector2", x = value.X, y = value.Y }
	end

	if t == "CFrame" then
		local components = { value:GetComponents() }
		return {
			_type = "CFrame",
			x = components[1], y = components[2], z = components[3],
			r00 = components[4], r01 = components[5], r02 = components[6],
			r10 = components[7], r11 = components[8], r12 = components[9],
			r20 = components[10], r21 = components[11], r22 = components[12],
		}
	end

	if t == "Color3" then
		return { _type = "Color3", r = value.R, g = value.G, b = value.B }
	end

	if t == "BrickColor" then
		return { _type = "BrickColor", name = value.Name }
	end

	if t == "UDim" then
		return { _type = "UDim", scale = value.Scale, offset = value.Offset }
	end

	if t == "UDim2" then
		return {
			_type = "UDim2",
			xScale = value.X.Scale, xOffset = value.X.Offset,
			yScale = value.Y.Scale, yOffset = value.Y.Offset,
		}
	end

	if t == "Rect" then
		return {
			_type = "Rect",
			minX = value.Min.X, minY = value.Min.Y,
			maxX = value.Max.X, maxY = value.Max.Y,
		}
	end

	if t == "NumberRange" then
		return { _type = "NumberRange", min = value.Min, max = value.Max }
	end

	if t == "NumberSequence" then
		local keypoints = {}
		for _, kp in value.Keypoints do
			table.insert(keypoints, { time = kp.Time, value = kp.Value, envelope = kp.Envelope })
		end
		return { _type = "NumberSequence", keypoints = keypoints }
	end

	if t == "ColorSequence" then
		local keypoints = {}
		for _, kp in value.Keypoints do
			table.insert(keypoints, { time = kp.Time, r = kp.Value.R, g = kp.Value.G, b = kp.Value.B })
		end
		return { _type = "ColorSequence", keypoints = keypoints }
	end

	if t == "PhysicalProperties" then
		return {
			_type = "PhysicalProperties",
			density = value.Density,
			friction = value.Friction,
			elasticity = value.Elasticity,
			frictionWeight = value.FrictionWeight,
			elasticityWeight = value.ElasticityWeight,
		}
	end

	if t == "Ray" then
		return {
			_type = "Ray",
			originX = value.Origin.X, originY = value.Origin.Y, originZ = value.Origin.Z,
			dirX = value.Direction.X, dirY = value.Direction.Y, dirZ = value.Direction.Z,
		}
	end

	if t == "Region3" then
		-- Region3 doesn't expose min/max directly, approximate from CFrame+Size
		return { _type = "Region3", str = tostring(value) }
	end

	if t == "EnumItem" then
		return { _type = "Enum", enumType = tostring(value.EnumType), name = value.Name }
	end

	if t == "Font" then
		return {
			_type = "Font",
			family = value.Family,
			weight = value.Weight.Name,
			style = value.Style.Name,
		}
	end

	if t == "Instance" then
		return { _type = "Instance", className = value.ClassName, name = value.Name }
	end

	-- Fallback: stringify
	return { _type = "unknown", value = tostring(value) }
end

-- ── Deserialize: JSON-safe table → Roblox value ──

function DataTypeSerializer.deserialize(data: any): any
	if data == nil then return nil end
	if type(data) ~= "table" then return data end
	if not data._type then return data end

	local dt = data._type

	if dt == "Vector3" then
		return Vector3.new(data.x or 0, data.y or 0, data.z or 0)
	end

	if dt == "Vector2" then
		return Vector2.new(data.x or 0, data.y or 0)
	end

	if dt == "CFrame" then
		return CFrame.new(
			data.x or 0, data.y or 0, data.z or 0,
			data.r00 or 1, data.r01 or 0, data.r02 or 0,
			data.r10 or 0, data.r11 or 1, data.r12 or 0,
			data.r20 or 0, data.r21 or 0, data.r22 or 1
		)
	end

	if dt == "Color3" then
		return Color3.new(data.r or 0, data.g or 0, data.b or 0)
	end

	if dt == "Color3FromHex" then
		return Color3.fromHex(data.hex or "#ffffff")
	end

	if dt == "Color3FromRGB" then
		return Color3.fromRGB(data.r or 255, data.g or 255, data.b or 255)
	end

	if dt == "BrickColor" then
		return BrickColor.new(data.name or "Medium stone grey")
	end

	if dt == "UDim" then
		return UDim.new(data.scale or 0, data.offset or 0)
	end

	if dt == "UDim2" then
		return UDim2.new(data.xScale or 0, data.xOffset or 0, data.yScale or 0, data.yOffset or 0)
	end

	if dt == "Rect" then
		return Rect.new(data.minX or 0, data.minY or 0, data.maxX or 0, data.maxY or 0)
	end

	if dt == "NumberRange" then
		return NumberRange.new(data.min or 0, data.max or 1)
	end

	if dt == "NumberSequence" then
		local keypoints = {}
		for _, kp in data.keypoints or {} do
			table.insert(keypoints, NumberSequenceKeypoint.new(kp.time, kp.value, kp.envelope or 0))
		end
		if #keypoints < 2 then
			return NumberSequence.new(0)
		end
		return NumberSequence.new(keypoints)
	end

	if dt == "ColorSequence" then
		local keypoints = {}
		for _, kp in data.keypoints or {} do
			table.insert(keypoints, ColorSequenceKeypoint.new(kp.time, Color3.new(kp.r, kp.g, kp.b)))
		end
		if #keypoints < 2 then
			return ColorSequence.new(Color3.new(1, 1, 1))
		end
		return ColorSequence.new(keypoints)
	end

	if dt == "PhysicalProperties" then
		return PhysicalProperties.new(
			data.density or 1,
			data.friction or 0.3,
			data.elasticity or 0.5,
			data.frictionWeight or 1,
			data.elasticityWeight or 1
		)
	end

	if dt == "Ray" then
		return Ray.new(
			Vector3.new(data.originX or 0, data.originY or 0, data.originZ or 0),
			Vector3.new(data.dirX or 0, data.dirY or 0, data.dirZ or 0)
		)
	end

	if dt == "Enum" then
		local ok, result = pcall(function()
			return (Enum :: any)[data.enumType][data.name]
		end)
		if ok then return result end
		return nil
	end

	if dt == "Font" then
		local weight = Enum.FontWeight.Regular
		local style = Enum.FontStyle.Normal
		pcall(function() weight = (Enum.FontWeight :: any)[data.weight] end)
		pcall(function() style = (Enum.FontStyle :: any)[data.style] end)
		return Font.new(data.family or "rbxasset://fonts/families/SourceSansPro.json", weight, style)
	end

	-- Unknown tagged type, return raw
	return data
end

-- ── Deep deserialize: recursively deserialize all tagged values in a table ──

function DataTypeSerializer.deepDeserialize(data: any): any
	if data == nil then return nil end
	if type(data) ~= "table" then return data end

	-- If it has a _type tag, deserialize it directly
	if data._type then
		return DataTypeSerializer.deserialize(data)
	end

	-- Otherwise recurse into table values
	local result = {}
	for k, v in data do
		result[k] = DataTypeSerializer.deepDeserialize(v)
	end
	return result
end

-- ── Serialize all values in a table ──

function DataTypeSerializer.serializeTable(data: { [string]: any }): { [string]: any }
	local result = {}
	for k, v in data do
		result[k] = DataTypeSerializer.serialize(v)
	end
	return result
end

return DataTypeSerializer
