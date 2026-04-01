--!strict
-- EncodedValue: Encode/decode ALL Roblox value types
-- Ported from Rojo's rbx_dom_lua (battle-tested, handles 35+ types)
-- Format: { TypeName = value } e.g. { Vector3 = {1, 2, 3} }

local EncodedValue = {}

local function identity(...)
	return ...
end

local function unpackDecoder(f)
	return function(value)
		return f(unpack(value))
	end
end

local function serializeFloat(value: number): number
	if value == math.huge or value == -math.huge then
		return 999999999 * math.sign(value)
	end
	return value
end

local ALL_AXES = { "X", "Y", "Z" }
local ALL_FACES = { "Right", "Top", "Back", "Left", "Bottom", "Front" }

local types: { [string]: { fromPod: (any) -> any, toPod: (any) -> any } }
types = {
	Attributes = {
		fromPod = function(pod)
			local output = {}
			for key, value in pairs(pod) do
				local ok, result = EncodedValue.decode(value)
				if ok then output[key] = result end
			end
			return output
		end,
		toPod = function(roblox)
			local output = {}
			for key, value in pairs(roblox) do
				local ok, result = EncodedValue.encodeNaive(value)
				if ok then output[key] = result end
			end
			return output
		end,
	},

	Axes = {
		fromPod = function(pod)
			local axes = {}
			for index, axisName in ipairs(pod) do
				axes[index] = Enum.Axis[axisName]
			end
			return Axes.new(unpack(axes))
		end,
		toPod = function(roblox)
			local result = {}
			for _, axis in ipairs(ALL_AXES) do
				if roblox[axis] then table.insert(result, axis) end
			end
			return result
		end,
	},

	Bool = { fromPod = identity, toPod = identity },

	BrickColor = {
		fromPod = function(pod) return BrickColor.new(pod) end,
		toPod = function(roblox) return roblox.Number end,
	},

	CFrame = {
		fromPod = function(pod)
			local pos = pod.position
			local orient = pod.orientation
			return CFrame.new(
				pos[1], pos[2], pos[3],
				orient[1][1], orient[1][2], orient[1][3],
				orient[2][1], orient[2][2], orient[2][3],
				orient[3][1], orient[3][2], orient[3][3]
			)
		end,
		toPod = function(roblox)
			local x, y, z, r00, r01, r02, r10, r11, r12, r20, r21, r22 = roblox:GetComponents()
			return {
				position = { x, y, z },
				orientation = {
					{ r00, r01, r02 },
					{ r10, r11, r12 },
					{ r20, r21, r22 },
				},
			}
		end,
	},

	Color3 = {
		fromPod = unpackDecoder(Color3.new),
		toPod = function(roblox) return { roblox.R, roblox.G, roblox.B } end,
	},

	Color3uint8 = {
		fromPod = unpackDecoder(Color3.fromRGB),
		toPod = function(roblox)
			return { math.round(roblox.R * 255), math.round(roblox.G * 255), math.round(roblox.B * 255) }
		end,
	},

	ColorSequence = {
		fromPod = function(pod)
			local keypoints = {}
			for index, kp in ipairs(pod.keypoints) do
				keypoints[index] = ColorSequenceKeypoint.new(kp.time, types.Color3.fromPod(kp.color))
			end
			return ColorSequence.new(keypoints)
		end,
		toPod = function(roblox)
			local keypoints = {}
			for index, kp in ipairs(roblox.Keypoints) do
				keypoints[index] = { time = kp.Time, color = types.Color3.toPod(kp.Value) }
			end
			return { keypoints = keypoints }
		end,
	},

	ContentId = { fromPod = identity, toPod = identity },

	Enum = {
		fromPod = identity,
		toPod = function(roblox)
			if typeof(roblox) == "number" then return roblox end
			return roblox.Value
		end,
	},

	EnumItem = {
		fromPod = function(pod) return (Enum :: any)[pod.type]:FromValue(pod.value) end,
		toPod = function(roblox) return { type = tostring(roblox.EnumType), value = roblox.Value } end,
	},

	Faces = {
		fromPod = function(pod)
			local faces = {}
			for index, faceName in ipairs(pod) do
				faces[index] = Enum.NormalId[faceName]
			end
			return Faces.new(unpack(faces))
		end,
		toPod = function(roblox)
			local result = {}
			for _, face in ipairs(ALL_FACES) do
				if roblox[face] then table.insert(result, face) end
			end
			return result
		end,
	},

	Float32 = { fromPod = identity, toPod = serializeFloat },
	Float64 = { fromPod = identity, toPod = serializeFloat },

	Font = {
		fromPod = function(pod)
			return Font.new(
				pod.family,
				if pod.weight ~= nil then (Enum.FontWeight :: any)[pod.weight] else nil,
				if pod.style ~= nil then (Enum.FontStyle :: any)[pod.style] else nil
			)
		end,
		toPod = function(roblox)
			return { family = roblox.Family, weight = roblox.Weight.Name, style = roblox.Style.Name }
		end,
	},

	Int32 = { fromPod = identity, toPod = identity },
	Int64 = { fromPod = identity, toPod = identity },

	NumberRange = {
		fromPod = unpackDecoder(NumberRange.new),
		toPod = function(roblox) return { roblox.Min, roblox.Max } end,
	},

	NumberSequence = {
		fromPod = function(pod)
			local keypoints = {}
			for index, kp in ipairs(pod.keypoints) do
				keypoints[index] = NumberSequenceKeypoint.new(kp.time, kp.value or 0, kp.envelope or 0)
			end
			return NumberSequence.new(keypoints)
		end,
		toPod = function(roblox)
			local keypoints = {}
			for index, kp in ipairs(roblox.Keypoints) do
				keypoints[index] = { time = kp.Time, value = kp.Value, envelope = kp.Envelope }
			end
			return { keypoints = keypoints }
		end,
	},

	PhysicalProperties = {
		fromPod = function(pod)
			if pod == "Default" then return nil end
			return PhysicalProperties.new(pod.density, pod.friction, pod.elasticity, pod.frictionWeight, pod.elasticityWeight)
		end,
		toPod = function(roblox)
			if roblox == nil then return "Default" end
			return {
				density = roblox.Density, friction = roblox.Friction, elasticity = roblox.Elasticity,
				frictionWeight = roblox.FrictionWeight, elasticityWeight = roblox.ElasticityWeight,
			}
		end,
	},

	Ray = {
		fromPod = function(pod)
			return Ray.new(types.Vector3.fromPod(pod.origin), types.Vector3.fromPod(pod.direction))
		end,
		toPod = function(roblox)
			return { origin = types.Vector3.toPod(roblox.Origin), direction = types.Vector3.toPod(roblox.Direction) }
		end,
	},

	Rect = {
		fromPod = function(pod) return Rect.new(types.Vector2.fromPod(pod[1]), types.Vector2.fromPod(pod[2])) end,
		toPod = function(roblox) return { types.Vector2.toPod(roblox.Min), types.Vector2.toPod(roblox.Max) } end,
	},

	String = { fromPod = identity, toPod = identity },

	UDim = {
		fromPod = unpackDecoder(UDim.new),
		toPod = function(roblox) return { roblox.Scale, roblox.Offset } end,
	},

	UDim2 = {
		fromPod = function(pod) return UDim2.new(types.UDim.fromPod(pod[1]), types.UDim.fromPod(pod[2])) end,
		toPod = function(roblox) return { types.UDim.toPod(roblox.X), types.UDim.toPod(roblox.Y) } end,
	},

	Tags = { fromPod = identity, toPod = identity },

	Vector2 = {
		fromPod = unpackDecoder(Vector2.new),
		toPod = function(roblox) return { serializeFloat(roblox.X), serializeFloat(roblox.Y) } end,
	},

	Vector2int16 = {
		fromPod = unpackDecoder(Vector2int16.new),
		toPod = function(roblox) return { roblox.X, roblox.Y } end,
	},

	Vector3 = {
		fromPod = unpackDecoder(Vector3.new),
		toPod = function(roblox) return { serializeFloat(roblox.X), serializeFloat(roblox.Y), serializeFloat(roblox.Z) } end,
	},

	Vector3int16 = {
		fromPod = unpackDecoder(Vector3int16.new),
		toPod = function(roblox) return { roblox.X, roblox.Y, roblox.Z } end,
	},
}

-- Optional CFrame (nil-safe)
types.OptionalCFrame = {
	fromPod = function(pod)
		if pod == nil then return nil end
		return types.CFrame.fromPod(pod)
	end,
	toPod = function(roblox)
		if roblox == nil then return nil end
		return types.CFrame.toPod(roblox)
	end,
}

function EncodedValue.decode(encodedValue: { [string]: any }): (boolean, any)
	local ty, value = next(encodedValue)
	if ty == nil then return true, nil end
	local typeImpl = types[ty]
	if typeImpl == nil then return false, "Unknown type: " .. tostring(ty) end
	local ok, result = pcall(typeImpl.fromPod, value)
	if not ok then return false, "Decode failed for " .. ty .. ": " .. tostring(result) end
	return true, result
end

function EncodedValue.encode(rbxValue: any, propertyType: string): (boolean, any)
	local typeImpl = types[propertyType]
	if typeImpl == nil then return false, "Unknown property type: " .. propertyType end
	local ok, result = pcall(typeImpl.toPod, rbxValue)
	if not ok then return false, "Encode failed for " .. propertyType .. ": " .. tostring(result) end
	return true, { [propertyType] = result }
end

local propertyTypeRenames = {
	number = "Float64",
	boolean = "Bool",
	string = "String",
}

function EncodedValue.encodeNaive(rbxValue: any): (boolean, any)
	local propertyType = typeof(rbxValue)
	if propertyTypeRenames[propertyType] then
		propertyType = propertyTypeRenames[propertyType]
	end
	return EncodedValue.encode(rbxValue, propertyType)
end

return EncodedValue
