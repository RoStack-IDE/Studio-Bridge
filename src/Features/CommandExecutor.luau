--!strict
-- Studio Bridge Command Executor
-- Executes ALL commands received from the server in Roblox Studio
-- Supports: instances, scripts, selection, history, attributes, tags,
--           terrain, lighting, CSG, constraints, animation, audio, assets, studio info

local ChangeHistoryService = game:GetService("ChangeHistoryService")
local CollectionService = game:GetService("CollectionService")
local InsertService = game:GetService("InsertService")
local Lighting = game:GetService("Lighting")
local Selection = game:GetService("Selection")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")

local Logger = require(script.Parent.Parent.Logger)
local Config = require(script.Parent.Parent.Config)
local DataTypeSerializer = require(script.Parent.DataTypeSerializer)
local RbxDom = require(script.Parent.Parent.RbxDom)

local CommandExecutor = {}

-- ── Helpers ──

local function resolveInstance(path: string): Instance?
	-- Support both "." and "/" separators
	local normalized = string.gsub(path, "/", ".")
	local parts = string.split(normalized, ".")
	local current: Instance = game
	for _, part in parts do
		-- Handle disambiguated names like "Script[2]" for duplicate siblings
		local name, indexStr = string.match(part, "^(.+)%[(%d+)%]$")
		if name and indexStr then
			local targetIndex = tonumber(indexStr) or 1
			local count = 0
			local found: Instance? = nil
			for _, child in ipairs(current:GetChildren()) do
				if child.Name == name then
					count += 1
					if count == targetIndex then
						found = child
						break
					end
				end
			end
			if not found then return nil end
			current = found
		else
			local child = current:FindFirstChild(part)
			if not child then return nil end
			current = child
		end
	end
	return current
end

local function getPath(instance: Instance): string
	local parts = {}
	local current: Instance? = instance
	while current and current ~= game do
		table.insert(parts, 1, (current :: Instance).Name)
		current = (current :: Instance).Parent
	end
	return table.concat(parts, ".")
end

local function deserializeProps(properties: { [string]: any }?): { [string]: any }?
	if not properties then return nil end
	return DataTypeSerializer.deepDeserialize(properties) :: any
end

local function withRecording(label: string, fn: () -> any): any
	local recordingId = ChangeHistoryService:TryBeginRecording(Config.PLUGIN_NAME .. ": " .. label)
	local ok, result = pcall(fn)
	if recordingId then
		if ok then
			ChangeHistoryService:FinishRecording(recordingId, Enum.FinishRecordingOperation.Commit)
		else
			ChangeHistoryService:FinishRecording(recordingId, Enum.FinishRecordingOperation.Cancel)
		end
	end
	if not ok then error(result) end
	return result
end

-- ── Command dispatch ──

local handlers: { [string]: (params: { [string]: any }) -> any } = {}

function CommandExecutor.execute(commandType: string, params: { [string]: any }): (boolean, any?)
	local handler = handlers[commandType]
	if not handler then
		Logger.warn("CommandExecutor", "Unknown command: " .. tostring(commandType))
		return false, "Unknown command type: " .. tostring(commandType)
	end

	local ok, result = pcall(handler, params)
	if ok then
		return true, result
	else
		Logger.warn("CommandExecutor", "Command '" .. commandType .. "' failed: " .. tostring(result))
		return false, tostring(result)
	end
end


-- ═══════════════════════════════════════════════════════════
-- INSTANCE MANAGEMENT
-- ═══════════════════════════════════════════════════════════

handlers["createInstance"] = function(params)
	return withRecording("Create " .. tostring(params.className), function()
		local parent = resolveInstance(params.parentPath :: string)
		if not parent then error("Parent not found: " .. params.parentPath) end

		local instance = Instance.new(params.className :: string)
		instance.Name = params.name :: string

		local props = deserializeProps(params.properties :: any)
		if props then
			for prop, value in props do
				pcall(function() (instance :: any)[prop] = value end)
			end
		end

		instance.Parent = parent
		return { created = true, path = getPath(instance), className = params.className }
	end)
end

handlers["deleteInstance"] = function(params)
	return withRecording("Delete " .. tostring(params.path), function()
		local instance = resolveInstance(params.path :: string)
		if not instance then error("Instance not found: " .. params.path) end
		local name = instance.Name
		instance:Destroy()
		return { deleted = true, path = params.path, name = name }
	end)
end

handlers["setProperty"] = function(params)
	return withRecording("Set property", function()
		local instance = resolveInstance(params.path :: string)
		if not instance then error("Instance not found: " .. params.path) end
		local value = DataTypeSerializer.deepDeserialize(params.value)
		;(instance :: any)[params.property :: string] = value
		return { set = true, path = params.path, property = params.property }
	end)
end

handlers["setProperties"] = function(params)
	return withRecording("Set properties", function()
		local instance = resolveInstance(params.path :: string)
		if not instance then error("Instance not found: " .. params.path) end
		local props = deserializeProps(params.properties :: any) or {}
		local applied = {}
		for prop, value in props do
			local ok = pcall(function() (instance :: any)[prop] = value end)
			table.insert(applied, { property = prop, success = ok })
		end
		return { path = params.path, applied = applied }
	end)
end

handlers["moveInstance"] = function(params)
	return withRecording("Move instance", function()
		local instance = resolveInstance(params.path :: string)
		if not instance then error("Instance not found: " .. params.path) end
		local newParent = resolveInstance(params.newParentPath :: string)
		if not newParent then error("New parent not found: " .. params.newParentPath) end
		instance.Parent = newParent
		return { moved = true, from = params.path, to = getPath(instance) }
	end)
end

handlers["cloneInstance"] = function(params)
	return withRecording("Clone instance", function()
		local instance = resolveInstance(params.path :: string)
		if not instance then error("Instance not found: " .. params.path) end
		local clone = instance:Clone()
		if params.newName then clone.Name = params.newName :: string end
		clone.Parent = instance.Parent
		return { cloned = true, path = getPath(clone), name = clone.Name }
	end)
end

handlers["renameInstance"] = function(params)
	return withRecording("Rename instance", function()
		local instance = resolveInstance(params.path :: string)
		if not instance then error("Instance not found: " .. params.path) end
		local oldName = instance.Name
		instance.Name = params.newName :: string
		return { renamed = true, oldName = oldName, newName = params.newName, path = getPath(instance) }
	end)
end

handlers["getChildren"] = function(params)
	local instance = resolveInstance(params.path :: string)
	if not instance then error("Instance not found: " .. params.path) end
	local children = {}
	for _, child in instance:GetChildren() do
		table.insert(children, { name = child.Name, className = child.ClassName, path = getPath(child) })
	end
	return { children = children, count = #children }
end

handlers["getDescendants"] = function(params)
	local instance = resolveInstance(params.path :: string)
	if not instance then error("Instance not found: " .. params.path) end
	local maxDepth = (params.maxDepth :: number?) or 10
	local results = {}

	local function walk(inst: Instance, depth: number)
		if depth > maxDepth then return end
		for _, child in inst:GetChildren() do
			table.insert(results, { name = child.Name, className = child.ClassName, path = getPath(child), depth = depth })
			walk(child, depth + 1)
		end
	end
	walk(instance, 1)
	return { descendants = results, count = #results }
end

handlers["findInstances"] = function(params)
	local root = resolveInstance(params.rootPath :: string)
	if not root then error("Root not found: " .. params.rootPath) end
	local className = params.className :: string?
	local namePattern = params.namePattern :: string?
	local maxResults = (params.maxResults :: number?) or 100
	local results = {}

	for _, desc in root:GetDescendants() do
		if #results >= maxResults then break end
		local classMatch = not className or desc.ClassName == className
		local nameMatch = not namePattern or string.find(desc.Name, namePattern)
		if classMatch and nameMatch then
			table.insert(results, { name = desc.Name, className = desc.ClassName, path = getPath(desc) })
		end
	end
	return { results = results, count = #results }
end

handlers["getProperties"] = function(params)
	local instance = resolveInstance(params.path :: string)
	if not instance then error("Instance not found: " .. params.path) end

	local props: { [string]: any } = {
		Name = instance.Name,
		ClassName = instance.ClassName,
	}

	-- Common properties to try reading
	local tryProps = {
		"Position", "Size", "CFrame", "Color", "BrickColor", "Transparency", "Anchored",
		"CanCollide", "CanQuery", "CanTouch", "Material", "Reflectance", "Shape",
		"Massless", "RootPriority", "CollisionGroup",
		-- BasePart appearance
		"Color", "Material", "MaterialVariant", "Reflectance", "Transparency",
		-- Mesh
		"MeshId", "TextureID", "Scale", "Offset",
		-- GUI
		"BackgroundColor3", "BackgroundTransparency", "BorderColor3", "BorderSizePixel",
		"AnchorPoint", "AutomaticSize", "ClipsDescendants", "LayoutOrder",
		"Visible", "ZIndex", "Text", "TextColor3", "TextSize", "Font", "FontFace",
		"TextWrapped", "TextScaled", "RichText", "Image", "ImageColor3",
		"ImageTransparency", "ScaleType", "SliceCenter",
		-- Sound
		"SoundId", "Volume", "PlaybackSpeed", "Looped", "Playing", "TimePosition", "TimeLength",
		-- Light
		"Brightness", "Range", "Shadows", "Angle", "Face",
		-- Script
		"Enabled", "RunContext",
		-- Value objects
		"Value",
		-- Humanoid
		"Health", "MaxHealth", "WalkSpeed", "JumpPower", "JumpHeight", "HipHeight",
		-- Constraint
		"Attachment0", "Attachment1", "Length", "Stiffness", "Damping",
		-- Particle
		"Rate", "Lifetime", "Speed", "RotSpeed", "SpreadAngle", "EmissionDirection",
	}

	for _, propName in tryProps do
		if props[propName] == nil then
			pcall(function()
				props[propName] = DataTypeSerializer.serialize((instance :: any)[propName])
			end)
		end
	end

	if instance:IsA("LuaSourceContainer") then
		pcall(function() props.Source = string.sub((instance :: any).Source, 1, 2000) end)
	end

	return { properties = props, path = params.path, className = instance.ClassName }
end


-- ═══════════════════════════════════════════════════════════
-- SCRIPTING
-- ═══════════════════════════════════════════════════════════

handlers["insertScript"] = function(params)
	return withRecording("Insert script " .. tostring(params.name), function()
		local parent = resolveInstance(params.parentPath :: string)
		if not parent then error("Parent not found: " .. params.parentPath) end
		local scriptInst = Instance.new(params.className :: string)
		scriptInst.Name = params.name :: string
		;(scriptInst :: any).Source = params.source :: string
		scriptInst.Parent = parent
		return { created = true, path = getPath(scriptInst), className = params.className, lineCount = #string.split(params.source :: string, "\n") }
	end)
end

handlers["updateScript"] = function(params)
	return withRecording("Update script", function()
		local instance = resolveInstance(params.path :: string)
		if not instance then error("Script not found: " .. params.path) end
		if not instance:IsA("LuaSourceContainer") then error("Not a script: " .. params.path) end
		;(instance :: any).Source = params.source :: string
		return { updated = true, path = params.path, lineCount = #string.split(params.source :: string, "\n") }
	end)
end

handlers["openScript"] = function(params)
	local instance = resolveInstance(params.path :: string)
	if not instance then error("Script not found: " .. params.path) end
	if not instance:IsA("LuaSourceContainer") then error("Not a script: " .. params.path) end

	local ScriptEditorService = game:GetService("ScriptEditorService")
	local ok, err = pcall(function()
		(ScriptEditorService :: any):OpenScriptDocumentAsync(instance)
	end)
	if not ok then
		return { opened = false, error = "ScriptEditorService unavailable: " .. tostring(err) }
	end

	-- If a line number was provided, scroll to it
	local line = params.line
	if line then
		pcall(function()
			local doc = (ScriptEditorService :: any):FindScriptDocument(instance)
			if doc then
				-- Move cursor to the target line (1-indexed line, 0-indexed char)
				local targetLine = math.max(0, (line :: number) - 1)
				doc:EditTextAsync(
					{ ["start"] = { ["line"] = targetLine, ["character"] = 0 }, ["end"] = { ["line"] = targetLine, ["character"] = 0 } },
					""
				)
				-- Request cursor position by selecting the line start
				doc:RequestSetSelectionAsync(targetLine, 0, targetLine, 0)
			end
		end)
	end

	return { opened = true, path = params.path, line = line }
end

handlers["getEditorSource"] = function(params)
	local instance = resolveInstance(params.path :: string)
	if not instance then error("Script not found: " .. params.path) end
	if not instance:IsA("LuaSourceContainer") then error("Not a script: " .. params.path) end

	local ScriptEditorService = game:GetService("ScriptEditorService")
	local ok, source = pcall(function()
		return (ScriptEditorService :: any):GetEditorSource(instance)
	end)
	if ok and source then
		return { source = source, path = params.path, lineCount = #string.split(source, "\n") }
	end
	-- Fallback to .Source property
	local src = (instance :: any).Source
	return { source = src, path = params.path, lineCount = #string.split(src, "\n"), fallback = true }
end

handlers["editScriptRange"] = function(params)
	return withRecording("Edit script range", function()
		local instance = resolveInstance(params.path :: string)
		if not instance then error("Script not found: " .. params.path) end
		if not instance:IsA("LuaSourceContainer") then error("Not a script: " .. params.path) end

		local ScriptEditorService = game:GetService("ScriptEditorService")
		local ok, err = pcall(function()
			local doc = (ScriptEditorService :: any):FindScriptDocument(instance)
			if not doc then error("Script not open in editor — open it first with openScript") end
			local startLine = (params.startLine :: number) - 1 -- 0-indexed
			local startChar = (params.startChar :: number) - 1
			local endLine = (params.endLine :: number) - 1
			local endChar = (params.endChar :: number) - 1
			local success = doc:EditTextAsync(params.newText :: string, startLine, startChar, endLine, endChar)
			if not success then error("EditTextAsync returned false") end
		end)
		if not ok then
			return { edited = false, error = "ScriptEditorService range edit failed: " .. tostring(err) }
		end
		return { edited = true, path = params.path }
	end)
end

handlers["getOpenScripts"] = function(_params)
	local ScriptEditorService = game:GetService("ScriptEditorService")
	local results = {}
	local ok, docs = pcall(function()
		return (ScriptEditorService :: any):GetScriptDocuments()
	end)
	if ok and docs then
		for _, doc in docs do
			pcall(function()
				local script = doc:GetScript()
				if script then
					table.insert(results, { name = script.Name, path = getPath(script), className = script.ClassName })
				end
			end)
		end
	end
	return { scripts = results, count = #results }
end

-- ═══════════════════════════════════════════════════════════
-- SELECTION
-- ═══════════════════════════════════════════════════════════

handlers["getSelection"] = function(_params)
	local selected = Selection:Get()
	local results = {}
	for _, inst in selected do
		table.insert(results, { name = inst.Name, className = inst.ClassName, path = getPath(inst) })
	end
	return { selection = results, count = #results }
end

handlers["setSelection"] = function(params)
	local paths = params.paths :: { string }
	local instances = {}
	local warnings = {}
	for _, path in paths do
		local inst = resolveInstance(path)
		if inst then
			table.insert(instances, inst)
		else
			table.insert(warnings, "Not found: " .. path)
		end
	end
	Selection:Set(instances)
	return { selected = #instances, warnings = #warnings > 0 and warnings or nil }
end

-- ═══════════════════════════════════════════════════════════
-- CHANGE HISTORY
-- ═══════════════════════════════════════════════════════════

handlers["undoHistory"] = function(_params)
	ChangeHistoryService:Undo()
	return { undone = true }
end

handlers["redoHistory"] = function(_params)
	ChangeHistoryService:Redo()
	return { redone = true }
end

handlers["getHistoryWaypoints"] = function(_params)
	local canUndo = false
	local canRedo = false
	pcall(function()
		canUndo = ChangeHistoryService:GetCanUndo()
		canRedo = ChangeHistoryService:GetCanRedo()
	end)
	return { canUndo = canUndo, canRedo = canRedo }
end

-- ═══════════════════════════════════════════════════════════
-- ATTRIBUTES
-- ═══════════════════════════════════════════════════════════

handlers["setAttribute"] = function(params)
	return withRecording("Set attribute", function()
		local instance = resolveInstance(params.path :: string)
		if not instance then error("Instance not found: " .. params.path) end
		local value = DataTypeSerializer.deepDeserialize(params.value)
		instance:SetAttribute(params.key :: string, value)
		return { set = true, path = params.path, key = params.key }
	end)
end

handlers["getAttribute"] = function(params)
	local instance = resolveInstance(params.path :: string)
	if not instance then error("Instance not found: " .. params.path) end
	local value = instance:GetAttribute(params.key :: string)
	return { path = params.path, key = params.key, value = DataTypeSerializer.serialize(value) }
end

handlers["getAttributes"] = function(params)
	local instance = resolveInstance(params.path :: string)
	if not instance then error("Instance not found: " .. params.path) end
	local attrs = instance:GetAttributes()
	local serialized = DataTypeSerializer.serializeTable(attrs)
	return { path = params.path, attributes = serialized }
end

handlers["deleteAttribute"] = function(params)
	return withRecording("Delete attribute", function()
		local instance = resolveInstance(params.path :: string)
		if not instance then error("Instance not found: " .. params.path) end
		instance:SetAttribute(params.key :: string, nil)
		return { deleted = true, path = params.path, key = params.key }
	end)
end


-- ═══════════════════════════════════════════════════════════
-- COLLECTION SERVICE (TAGS)
-- ═══════════════════════════════════════════════════════════

handlers["addTag"] = function(params)
	return withRecording("Add tag", function()
		local instance = resolveInstance(params.path :: string)
		if not instance then error("Instance not found: " .. params.path) end
		CollectionService:AddTag(instance, params.tag :: string)
		return { added = true, path = params.path, tag = params.tag }
	end)
end

handlers["removeTag"] = function(params)
	return withRecording("Remove tag", function()
		local instance = resolveInstance(params.path :: string)
		if not instance then error("Instance not found: " .. params.path) end
		CollectionService:RemoveTag(instance, params.tag :: string)
		return { removed = true, path = params.path, tag = params.tag }
	end)
end

handlers["getTags"] = function(params)
	local instance = resolveInstance(params.path :: string)
	if not instance then error("Instance not found: " .. params.path) end
	local tags = CollectionService:GetTags(instance)
	return { path = params.path, tags = tags }
end

handlers["getTagged"] = function(params)
	local tagged = CollectionService:GetTagged(params.tag :: string)
	local results = {}
	for _, inst in tagged do
		table.insert(results, { name = inst.Name, className = inst.ClassName, path = getPath(inst) })
	end
	return { tag = params.tag, instances = results, count = #results }
end

-- ═══════════════════════════════════════════════════════════
-- TERRAIN
-- ═══════════════════════════════════════════════════════════

local function getTerrainMaterial(materialName: string): Enum.Material
	local ok, mat = pcall(function()
		return (Enum.Material :: any)[materialName]
	end)
	if ok and mat then return mat end
	return Enum.Material.Grass
end

handlers["terrainFillBlock"] = function(params)
	return withRecording("Terrain fill block", function()
		local terrain = game.Workspace.Terrain
		local cframe = DataTypeSerializer.deserialize(params.cframe)
		local size = DataTypeSerializer.deserialize(params.size)
		local material = getTerrainMaterial(params.material :: string)
		terrain:FillBlock(cframe, size, material)
		return { filled = true, shape = "block", material = params.material }
	end)
end

handlers["terrainFillBall"] = function(params)
	return withRecording("Terrain fill ball", function()
		local terrain = game.Workspace.Terrain
		local center = DataTypeSerializer.deserialize(params.center)
		local radius = params.radius :: number
		local material = getTerrainMaterial(params.material :: string)
		terrain:FillBall(center, radius, material)
		return { filled = true, shape = "ball", material = params.material }
	end)
end

handlers["terrainFillCylinder"] = function(params)
	return withRecording("Terrain fill cylinder", function()
		local terrain = game.Workspace.Terrain
		local cframe = DataTypeSerializer.deserialize(params.cframe)
		local height = params.height :: number
		local radius = params.radius :: number
		local material = getTerrainMaterial(params.material :: string)
		terrain:FillCylinder(cframe, height, radius, material)
		return { filled = true, shape = "cylinder", material = params.material }
	end)
end

handlers["terrainFillWedge"] = function(params)
	return withRecording("Terrain fill wedge", function()
		local terrain = game.Workspace.Terrain
		local cframe = DataTypeSerializer.deserialize(params.cframe)
		local size = DataTypeSerializer.deserialize(params.size)
		local material = getTerrainMaterial(params.material :: string)
		terrain:FillWedge(cframe, size, material)
		return { filled = true, shape = "wedge", material = params.material }
	end)
end

handlers["terrainClear"] = function(_params)
	return withRecording("Terrain clear", function()
		game.Workspace.Terrain:Clear()
		return { cleared = true }
	end)
end

-- ═══════════════════════════════════════════════════════════
-- LIGHTING & ATMOSPHERE
-- ═══════════════════════════════════════════════════════════

handlers["setLighting"] = function(params)
	return withRecording("Set lighting", function()
		local props = deserializeProps(params.properties :: any) or {}
		for prop, value in props do
			pcall(function() (Lighting :: any)[prop] = value end)
		end
		return { set = true, properties = params.properties }
	end)
end

handlers["getLighting"] = function(_params)
	local props: { [string]: any } = {}
	local tryProps = {
		"Ambient", "Brightness", "ClockTime", "ColorShift_Bottom", "ColorShift_Top",
		"EnvironmentDiffuseScale", "EnvironmentSpecularScale", "ExposureCompensation",
		"FogColor", "FogEnd", "FogStart", "GeographicLatitude", "GlobalShadows",
		"OutdoorAmbient", "ShadowSoftness", "Technology", "TimeOfDay",
	}
	for _, prop in tryProps do
		pcall(function() props[prop] = DataTypeSerializer.serialize((Lighting :: any)[prop]) end)
	end
	return { properties = props }
end

handlers["setAtmosphere"] = function(params)
	return withRecording("Set atmosphere", function()
		local atmo = Lighting:FindFirstChildOfClass("Atmosphere")
		if not atmo then
			atmo = Instance.new("Atmosphere")
			atmo.Parent = Lighting
		end
		local props = deserializeProps(params.properties :: any) or {}
		for prop, value in props do
			pcall(function() (atmo :: any)[prop] = value end)
		end
		return { set = true }
	end)
end

handlers["setSky"] = function(params)
	return withRecording("Set sky", function()
		local sky = Lighting:FindFirstChildOfClass("Sky")
		if not sky then
			sky = Instance.new("Sky")
			sky.Parent = Lighting
		end
		local props = deserializeProps(params.properties :: any) or {}
		for prop, value in props do
			pcall(function() (sky :: any)[prop] = value end)
		end
		return { set = true }
	end)
end

handlers["setPostEffect"] = function(params)
	return withRecording("Set post effect", function()
		local effectClass = params.effectClass :: string
		local effect = Lighting:FindFirstChildOfClass(effectClass)
		if not effect then
			effect = Instance.new(effectClass)
			effect.Parent = Lighting
		end
		local props = deserializeProps(params.properties :: any) or {}
		for prop, value in props do
			pcall(function() (effect :: any)[prop] = value end)
		end
		return { set = true, effectClass = effectClass }
	end)
end


-- ═══════════════════════════════════════════════════════════
-- CSG OPERATIONS
-- ═══════════════════════════════════════════════════════════

handlers["csgUnion"] = function(params)
	return withRecording("CSG Union", function()
		local paths = params.paths :: { string }
		local parts: { BasePart } = {}
		for _, path in paths do
			local inst = resolveInstance(path)
			if not inst then error("Not found: " .. path) end
			if not inst:IsA("BasePart") then error("Not a BasePart: " .. path) end
			table.insert(parts, inst :: BasePart)
		end
		if #parts < 2 then error("Need at least 2 parts for union") end
		local primary = parts[1]
		local others = { table.unpack(parts, 2) }
		local union = primary:UnionAsync(others)
		union.Parent = primary.Parent
		for _, p in parts do p:Destroy() end
		return { created = true, path = getPath(union), className = union.ClassName }
	end)
end

handlers["csgIntersect"] = function(params)
	return withRecording("CSG Intersect", function()
		local paths = params.paths :: { string }
		local parts: { BasePart } = {}
		for _, path in paths do
			local inst = resolveInstance(path)
			if not inst then error("Not found: " .. path) end
			if not inst:IsA("BasePart") then error("Not a BasePart: " .. path) end
			table.insert(parts, inst :: BasePart)
		end
		if #parts < 2 then error("Need at least 2 parts for intersect") end
		local primary = parts[1]
		local others = { table.unpack(parts, 2) }
		local result = primary:IntersectAsync(others)
		result.Parent = primary.Parent
		for _, p in parts do p:Destroy() end
		return { created = true, path = getPath(result), className = result.ClassName }
	end)
end

handlers["csgNegate"] = function(params)
	return withRecording("CSG Negate", function()
		local inst = resolveInstance(params.path :: string)
		if not inst then error("Not found: " .. params.path) end
		if not inst:IsA("BasePart") then error("Not a BasePart: " .. params.path) end
		local negated = inst:Clone()
		negated.Name = inst.Name .. "_Negated"
		-- NegateOperation is created by making a NegateOperation and parenting the part
		local negate = Instance.new("NegateOperation")
		negate.Name = inst.Name
		negate.CFrame = (inst :: any).CFrame
		negate.Size = (inst :: any).Size
		negate.Parent = inst.Parent
		inst:Destroy()
		return { negated = true, path = getPath(negate) }
	end)
end

handlers["csgSeparate"] = function(params)
	return withRecording("CSG Separate", function()
		local inst = resolveInstance(params.path :: string)
		if not inst then error("Not found: " .. params.path) end
		if not inst:IsA("UnionOperation") then error("Not a UnionOperation: " .. params.path) end
		local separated = (inst :: UnionOperation):SeparateAsync()
		local results = {}
		for _, part in separated do
			part.Parent = inst.Parent
			table.insert(results, { name = part.Name, path = getPath(part) })
		end
		inst:Destroy()
		return { separated = true, parts = results, count = #results }
	end)
end

-- ═══════════════════════════════════════════════════════════
-- PHYSICS CONSTRAINTS
-- ═══════════════════════════════════════════════════════════

handlers["createConstraint"] = function(params)
	return withRecording("Create constraint", function()
		local constraintClass = params.constraintClass :: string
		local parentPath = params.parentPath :: string
		local parent = resolveInstance(parentPath)
		if not parent then error("Parent not found: " .. parentPath) end

		local constraint = Instance.new(constraintClass)
		constraint.Name = params.name or constraintClass

		-- Set attachment references
		if params.attachment0Path then
			local a0 = resolveInstance(params.attachment0Path :: string)
			if a0 then (constraint :: any).Attachment0 = a0 end
		end
		if params.attachment1Path then
			local a1 = resolveInstance(params.attachment1Path :: string)
			if a1 then (constraint :: any).Attachment1 = a1 end
		end

		local props = deserializeProps(params.properties :: any)
		if props then
			for prop, value in props do
				pcall(function() (constraint :: any)[prop] = value end)
			end
		end

		constraint.Parent = parent
		return { created = true, path = getPath(constraint), className = constraintClass }
	end)
end

handlers["createAttachment"] = function(params)
	return withRecording("Create attachment", function()
		local parentPath = params.parentPath :: string
		local parent = resolveInstance(parentPath)
		if not parent then error("Parent not found: " .. parentPath) end

		local attachment = Instance.new("Attachment")
		attachment.Name = params.name or "Attachment"

		if params.cframe then
			attachment.CFrame = DataTypeSerializer.deserialize(params.cframe)
		end
		if params.position then
			attachment.Position = DataTypeSerializer.deserialize(params.position)
		end

		attachment.Parent = parent
		return { created = true, path = getPath(attachment) }
	end)
end

-- ═══════════════════════════════════════════════════════════
-- ANIMATION / TWEENS
-- ═══════════════════════════════════════════════════════════

handlers["createTween"] = function(params)
	local instance = resolveInstance(params.path :: string)
	if not instance then error("Instance not found: " .. params.path) end

	local info = params.tweenInfo :: { [string]: any }
	local tweenInfo = TweenInfo.new(
		info.time or 1,
		(Enum.EasingStyle :: any)[info.easingStyle or "Quad"] or Enum.EasingStyle.Quad,
		(Enum.EasingDirection :: any)[info.easingDirection or "Out"] or Enum.EasingDirection.Out,
		info.repeatCount or 0,
		info.reverses or false,
		info.delayTime or 0
	)

	local goals = deserializeProps(params.goals :: any) or {}
	local tween = TweenService:Create(instance, tweenInfo, goals)
	tween:Play()
	return { playing = true, path = params.path }
end

handlers["createAnimation"] = function(params)
	return withRecording("Create animation", function()
		local parentPath = params.parentPath :: string
		local parent = resolveInstance(parentPath)
		if not parent then error("Parent not found: " .. parentPath) end

		local anim = Instance.new("Animation")
		anim.Name = params.name or "Animation"
		anim.AnimationId = params.animationId :: string
		anim.Parent = parent
		return { created = true, path = getPath(anim), animationId = params.animationId }
	end)
end

-- ═══════════════════════════════════════════════════════════
-- AUDIO
-- ═══════════════════════════════════════════════════════════

handlers["playSound"] = function(params)
	local instance = resolveInstance(params.path :: string)
	if not instance then error("Sound not found: " .. params.path) end
	if not instance:IsA("Sound") then error("Not a Sound: " .. params.path) end
	;(instance :: Sound):Play()
	return { playing = true, path = params.path }
end

handlers["stopSound"] = function(params)
	local instance = resolveInstance(params.path :: string)
	if not instance then error("Sound not found: " .. params.path) end
	if not instance:IsA("Sound") then error("Not a Sound: " .. params.path) end
	;(instance :: Sound):Stop()
	return { stopped = true, path = params.path }
end

-- ═══════════════════════════════════════════════════════════
-- ASSETS
-- ═══════════════════════════════════════════════════════════

handlers["insertAsset"] = function(params)
	return withRecording("Insert asset", function()
		local parentPath = params.parentPath :: string
		local parent = resolveInstance(parentPath)
		if not parent then error("Parent not found: " .. parentPath) end

		local assetId = params.assetId :: number
		local ok, model = pcall(function()
			return InsertService:LoadAsset(assetId)
		end)
		if not ok or not model then
			error("Failed to load asset " .. tostring(assetId) .. ": " .. tostring(model))
		end

		-- LoadAsset returns a Model containing the asset
		local children = model:GetChildren()
		local inserted = {}
		for _, child in children do
			child.Parent = parent
			table.insert(inserted, { name = child.Name, className = child.ClassName, path = getPath(child) })
		end
		model:Destroy()
		return { inserted = inserted, count = #inserted, assetId = assetId }
	end)
end

-- ═══════════════════════════════════════════════════════════
-- STUDIO SERVICE
-- ═══════════════════════════════════════════════════════════

handlers["getStudioInfo"] = function(_params)
	local StudioService = game:GetService("StudioService")
	local info: { [string]: any } = {}
	pcall(function() info.gridSize = (StudioService :: any).GridSize end)
	pcall(function() info.rotateIncrement = (StudioService :: any).RotateIncrement end)
	pcall(function() info.useLocalSpace = (StudioService :: any).UseLocalSpace end)
	pcall(function()
		local active = (StudioService :: any).ActiveScript
		if active then
			info.activeScript = { name = active.Name, path = getPath(active), className = active.ClassName }
		end
	end)
	return info
end

handlers["setStudioSetting"] = function(params)
	local StudioService = game:GetService("StudioService")
	local props = deserializeProps(params.properties :: any) or {}
	for prop, value in props do
		pcall(function() (StudioService :: any)[prop] = value end)
	end
	return { set = true }
end

-- ═══════════════════════════════════════════════════════════
-- GUI HELPERS
-- ═══════════════════════════════════════════════════════════

handlers["setGuiOrder"] = function(params)
	return withRecording("Set GUI order", function()
		local instance = resolveInstance(params.path :: string)
		if not instance then error("Instance not found: " .. params.path) end
		if params.displayOrder ~= nil then
			pcall(function() (instance :: any).DisplayOrder = params.displayOrder end)
		end
		if params.zIndex ~= nil then
			pcall(function() (instance :: any).ZIndex = params.zIndex end)
		end
		return { set = true, path = params.path }
	end)
end

-- ═══════════════════════════════════════════════════════════
-- BATCH OPERATIONS
-- ═══════════════════════════════════════════════════════════

handlers["batch"] = function(params)
	local commands = params.commands :: { any }
	if not commands or #commands == 0 then error("No commands in batch") end

	local recordingId = ChangeHistoryService:TryBeginRecording(Config.PLUGIN_NAME .. ": Batch (" .. #commands .. " commands)")
	local results = {}

	for _, cmd in commands do
		local handler = handlers[cmd.type]
		if handler then
			local ok, result = pcall(handler, cmd.params or {})
			table.insert(results, {
				type = cmd.type,
				success = ok,
				result = if ok then result else nil,
				error = if not ok then tostring(result) else nil,
			})
		else
			table.insert(results, {
				type = cmd.type,
				success = false,
				error = "Unknown command: " .. tostring(cmd.type),
			})
		end
	end

	if recordingId then
		ChangeHistoryService:FinishRecording(recordingId, Enum.FinishRecordingOperation.Commit)
	end

	return { results = results, count = #results }
end

-- ═══════════════════════════════════════════════════════════
-- SESSION HIGHLIGHT
-- ═══════════════════════════════════════════════════════════

handlers["showSessionHighlight"] = function(_params)
	local CoreGui = game:GetService("CoreGui")

	-- Remove any existing highlight
	local existing = CoreGui:FindFirstChild("RoStackSessionHighlight")
	if existing then existing:Destroy() end

	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "RoStackSessionHighlight"
	screenGui.DisplayOrder = 999999
	screenGui.IgnoreGuiInset = true
	screenGui.ResetOnSpawn = false

	-- Border frame (full screen, acts as colored border)
	local border = Instance.new("Frame")
	border.Name = "Border"
	border.Size = UDim2.new(1, 0, 1, 0)
	border.Position = UDim2.new(0, 0, 0, 0)
	border.BackgroundTransparency = 1
	border.BorderSizePixel = 0
	border.Parent = screenGui

	local thickness = 4

	-- Top edge
	local top = Instance.new("Frame")
	top.Size = UDim2.new(1, 0, 0, thickness)
	top.Position = UDim2.new(0, 0, 0, 0)
	top.BackgroundColor3 = Color3.fromRGB(11, 132, 255)
	top.BorderSizePixel = 0
	top.Parent = border

	-- Bottom edge
	local bottom = Instance.new("Frame")
	bottom.Size = UDim2.new(1, 0, 0, thickness)
	bottom.Position = UDim2.new(0, 0, 1, -thickness)
	bottom.BackgroundColor3 = Color3.fromRGB(11, 132, 255)
	bottom.BorderSizePixel = 0
	bottom.Parent = border

	-- Left edge
	local left = Instance.new("Frame")
	left.Size = UDim2.new(0, thickness, 1, 0)
	left.Position = UDim2.new(0, 0, 0, 0)
	left.BackgroundColor3 = Color3.fromRGB(11, 132, 255)
	left.BorderSizePixel = 0
	left.Parent = border

	-- Right edge
	local right = Instance.new("Frame")
	right.Size = UDim2.new(0, thickness, 1, 0)
	right.Position = UDim2.new(1, -thickness, 0, 0)
	right.BackgroundColor3 = Color3.fromRGB(11, 132, 255)
	right.BorderSizePixel = 0
	right.Parent = border

	-- Center label
	local label = Instance.new("TextLabel")
	label.Name = "Label"
	label.Size = UDim2.new(0, 260, 0, 44)
	label.Position = UDim2.new(0.5, 0, 0.5, 0)
	label.AnchorPoint = Vector2.new(0.5, 0.5)
	label.BackgroundColor3 = Color3.fromRGB(11, 132, 255)
	label.BackgroundTransparency = 0.15
	label.BorderSizePixel = 0
	label.Text = "Current Session"
	label.TextColor3 = Color3.fromRGB(255, 255, 255)
	label.TextSize = 18
	label.Font = Enum.Font.GothamBold
	label.Parent = screenGui

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 8)
	corner.Parent = label

	screenGui.Parent = CoreGui

	-- Auto-dismiss after 3 seconds
	task.delay(3, function()
		if screenGui and screenGui.Parent then
			screenGui:Destroy()
		end
	end)

	return { shown = true }
end

-- ═══════════════════════════════════════════════════════════
-- GLOB: Find instances matching a glob-like pattern
-- ═══════════════════════════════════════════════════════════

handlers["glob"] = function(params)
	local pattern = params.pattern :: string
	if not pattern or pattern == "" then error("No pattern provided") end
	local classFilter = params.classFilter :: string?
	local maxResults = math.min((params.maxResults :: number?) or Config.MAX_SEARCH_RESULTS, Config.MAX_SEARCH_RESULTS)

	-- Convert glob pattern to Lua pattern:
	-- "*" → "[^/]*" (match within one level)
	-- "**" → ".*" (match across levels)
	-- "?" → "." (single char)
	local luaPattern = pattern
	luaPattern = string.gsub(luaPattern, "%*%*", "\1") -- placeholder for **
	luaPattern = string.gsub(luaPattern, "%*", "[^%.]*")
	luaPattern = string.gsub(luaPattern, "\1", ".*")
	luaPattern = string.gsub(luaPattern, "%?", ".")

	local matches = {}
	local ROOTS = {
		game:GetService("ServerScriptService"),
		game:GetService("ReplicatedStorage"),
		game:GetService("ReplicatedFirst"),
		game:GetService("StarterPlayer"),
		game:GetService("StarterGui"),
		game:GetService("StarterPack"),
		game:GetService("ServerStorage"),
		game:GetService("Workspace"),
		game:GetService("Lighting"),
	}

	for _, root in ROOTS do
		if #matches >= maxResults then break end
		for _, desc in root:GetDescendants() do
			if #matches >= maxResults then break end
			local path = getPath(desc)
			local nameMatch = pcall(function() return string.find(path, luaPattern) end)
			if nameMatch then
				local ok, found = pcall(function() return string.find(path, luaPattern) end)
				if ok and found then
					if not classFilter or desc.ClassName == classFilter then
						table.insert(matches, {
							name = desc.Name,
							className = desc.ClassName,
							path = path,
							hasChildren = #desc:GetChildren() > 0,
						})
					end
				end
			end
		end
	end

	return {
		matches = matches,
		totalFound = #matches,
		truncated = #matches >= maxResults,
	}
end

-- ═══════════════════════════════════════════════════════════
-- GREP: Search script source code for text or Lua patterns
-- ═══════════════════════════════════════════════════════════

handlers["grep"] = function(params)
	local query = params.query :: string
	if not query or query == "" then error("No query provided") end
	local isPattern = (params.isPattern :: boolean?) or false
	local ignoreCase = (params.ignoreCase :: boolean?) or true
	local maxResults = math.min((params.maxResults :: number?) or Config.MAX_SEARCH_RESULTS, Config.MAX_SEARCH_RESULTS)
	local scriptClassFilter = params.scriptClassFilter :: string?

	local SCRIPT_CLASSES = { Script = true, LocalScript = true, ModuleScript = true }
	local matches = {}

	local ROOTS = {
		game:GetService("ServerScriptService"),
		game:GetService("ReplicatedStorage"),
		game:GetService("ReplicatedFirst"),
		game:GetService("StarterPlayer"),
		game:GetService("StarterGui"),
		game:GetService("StarterPack"),
		game:GetService("ServerStorage"),
		game:GetService("Workspace"),
	}

	local searchQuery = query
	if ignoreCase and not isPattern then
		searchQuery = string.lower(query)
	end

	for _, root in ROOTS do
		if #matches >= maxResults then break end
		for _, desc in root:GetDescendants() do
			if #matches >= maxResults then break end
			if not SCRIPT_CLASSES[desc.ClassName] then continue end
			if scriptClassFilter and desc.ClassName ~= scriptClassFilter then continue end

			local ok, source = pcall(function() return (desc :: any).Source end)
			if not ok or not source or source == "" then continue end

			local lines = string.split(source, "\n")
			for lineNum, line in lines do
				if #matches >= maxResults then break end
				local found = false
				if isPattern then
					found = pcall(function() return string.find(line, query) end) and string.find(line, query) ~= nil
				else
					local searchLine = if ignoreCase then string.lower(line) else line
					found = string.find(searchLine, searchQuery, 1, true) ~= nil
				end
				if found then
					table.insert(matches, {
						name = desc.Name,
						className = desc.ClassName,
						path = getPath(desc),
						lineNumber = lineNum,
						matchText = string.sub(line, 1, 200), -- truncate long lines
					})
				end
			end
		end
	end

	return {
		matches = matches,
		totalFound = #matches,
		truncated = #matches >= maxResults,
	}
end

-- ═══════════════════════════════════════════════════════════
-- RUN TESTS: Execute game simulation and capture errors
-- ═══════════════════════════════════════════════════════════

handlers["runTests"] = function(params)
	local RunService = game:GetService("RunService")
	local LogService = game:GetService("LogService")

	local timeout = math.min((params.timeout :: number?) or 10, Config.MAX_TEST_TIMEOUT)
	local errors = {}
	local messages = {}

	-- Connect to LogService to capture errors in real-time
	local connection = LogService.MessageOut:Connect(function(message: string, messageType: Enum.MessageType)
		-- Skip our own log messages to prevent recursion
		if string.find(message, Config.LOG_PREFIX, 1, true) then return end

		if messageType == Enum.MessageType.MessageError or messageType == Enum.MessageType.MessageWarning then
			-- Parse script path and line number from error message
			local scriptPath = string.match(message, "([%w%.]+):%d+:") or "Unknown"
			scriptPath = string.gsub(scriptPath, "%.", "/")
			local lineNum = tonumber(string.match(message, ":(%d+):"))

			table.insert(errors, {
				scriptPath = scriptPath,
				lineNumber = lineNum,
				message = message,
			})
		elseif messageType == Enum.MessageType.MessageInfo or messageType == Enum.MessageType.MessageOutput then
			table.insert(messages, message)
		end
	end)

	-- Start game simulation
	local startTime = os.clock()
	local startOk, startErr = pcall(function()
		RunService:Run()
	end)

	if not startOk then
		connection:Disconnect()
		return {
			success = false,
			error = "Failed to start game simulation: " .. tostring(startErr),
		}
	end

	-- Wait for timeout
	task.wait(timeout)

	-- Stop simulation
	pcall(function() RunService:Stop() end)

	local duration = math.floor((os.clock() - startTime) * 1000)
	connection:Disconnect()

	return {
		success = true,
		totalTests = 1,
		passedTests = if #errors == 0 then 1 else 0,
		failedTests = if #errors > 0 then 1 else 0,
		errors = errors,
		messages = messages,
		duration = duration,
	}
end

-- ═══════════════════════════════════════════════════════════
-- IMPORT TOOLBOX ASSET: Import Roblox asset by ID
-- ═══════════════════════════════════════════════════════════

handlers["importToolboxAsset"] = function(params)
	return withRecording("Import toolbox asset", function()
		local parentPath = params.parentPath :: string
		local parent = resolveInstance(parentPath)
		if not parent then error("Parent not found: " .. parentPath) end

		local assetId = params.assetId :: number
		if not assetId or assetId <= 0 then error("Invalid assetId: " .. tostring(assetId)) end

		local name = (params.name :: string?) or ("Asset_" .. tostring(assetId))
		local stripScripts = if params.stripScripts == nil then true else (params.stripScripts :: boolean)

		-- Use game:GetObjects for broader asset compatibility
		local ok, instances = pcall(function()
			return game:GetObjects("rbxassetid://" .. assetId)
		end)

		if not ok or not instances or #instances == 0 then
			-- Fallback to InsertService
			ok, instances = pcall(function()
				local model = InsertService:LoadAsset(assetId)
				local children = model:GetChildren()
				model:Destroy()
				return children
			end)
		end

		if not ok or not instances or #instances == 0 then
			error("Failed to load asset " .. tostring(assetId))
		end

		-- Get root instance
		local rootInstance
		if #instances == 1 then
			rootInstance = instances[1]
		else
			local model = Instance.new("Model")
			model.Name = name
			for _, inst in instances do
				inst.Parent = model
			end
			rootInstance = model
		end

		rootInstance.Name = name
		rootInstance.Parent = parent

		-- Optionally strip scripts for security
		local scriptsRemoved = 0
		if stripScripts then
			for _, desc in rootInstance:GetDescendants() do
				if desc:IsA("LuaSourceContainer") then
					desc:Destroy()
					scriptsRemoved += 1
				end
			end
		end

		local childCount = #rootInstance:GetDescendants()

		return {
			imported = true,
			path = getPath(rootInstance),
			className = rootInstance.ClassName,
			name = rootInstance.Name,
			childCount = childCount,
			scriptsRemoved = scriptsRemoved,
			assetId = assetId,
		}
	end)
end

-- ═══════════════════════════════════════════════════════════
-- SERIALIZE: Snapshot an instance tree for rollback
-- ═══════════════════════════════════════════════════════════

handlers["serialize"] = function(params)
	local instance = resolveInstance(params.path :: string)
	if not instance then error("Instance not found: " .. params.path) end

	local HttpService = game:GetService("HttpService")

	local function serializeInstance(inst: Instance): { [string]: any }
		local data: { [string]: any } = {
			name = inst.Name,
			className = inst.ClassName,
			properties = {},
			attributes = {},
			children = {},
		}

		-- Serialize attributes using RbxDom
		pcall(function()
			local attrs = inst:GetAttributes()
			if next(attrs) then
				local ok, encoded = pcall(RbxDom.EncodedValue.encode, attrs, "Attributes")
				if ok and encoded then
					data.attributes = attrs -- Store raw for JSON compatibility
				else
					data.attributes = attrs
				end
			end
		end)

		-- Serialize common properties using RbxDom.EncodedValue for proper type handling
		local tryProps = {
			"Position", "Size", "CFrame", "Color", "BrickColor", "Transparency", "Anchored",
			"CanCollide", "CanQuery", "CanTouch", "Material", "Reflectance", "Shape",
			"Visible", "Enabled", "Value", "Text", "TextColor3", "BackgroundColor3",
			"Image", "SoundId", "Volume", "Brightness", "Range",
		}
		for _, prop in tryProps do
			pcall(function()
				local val = (inst :: any)[prop]
				-- Try RbxDom encoding first, fall back to DataTypeSerializer
				local encOk, encoded = RbxDom.EncodedValue.encodeNaive(val)
				if encOk then
					data.properties[prop] = encoded
				else
					data.properties[prop] = DataTypeSerializer.serialize(val)
				end
			end)
		end

		-- Serialize script source
		if inst:IsA("LuaSourceContainer") then
			pcall(function() data.source = (inst :: any).Source end)
		end

		-- Recurse children
		for _, child in inst:GetChildren() do
			table.insert(data.children, serializeInstance(child))
		end

		return data
	end

	local serialized = serializeInstance(instance)
	local jsonOk, json = pcall(HttpService.JSONEncode, HttpService, serialized)
	if not jsonOk then error("Failed to serialize: " .. tostring(json)) end

	return {
		path = params.path,
		className = instance.ClassName,
		parentPath = if instance.Parent then getPath(instance.Parent) else nil,
		data = json,
		source = if instance:IsA("LuaSourceContainer") then (instance :: any).Source else nil,
	}
end

-- ═══════════════════════════════════════════════════════════
-- DESERIALIZE: Recreate an instance from serialized data
-- ═══════════════════════════════════════════════════════════

handlers["deserialize"] = function(params)
	return withRecording("Deserialize instance", function()
		local parentPath = params.parentPath :: string
		local parent = resolveInstance(parentPath)
		if not parent then error("Parent not found: " .. parentPath) end

		local HttpService = game:GetService("HttpService")
		local ok, data = pcall(HttpService.JSONDecode, HttpService, params.data :: string)
		if not ok then error("Failed to decode serialized data") end

		local function recreateInstance(nodeData: { [string]: any }, parentInst: Instance): Instance
			local inst = Instance.new(nodeData.className)
			inst.Name = nodeData.name

			-- Apply properties
			if nodeData.properties then
				local props = DataTypeSerializer.deepDeserialize(nodeData.properties)
				if props then
					for prop, value in props :: any do
						pcall(function() (inst :: any)[prop] = value end)
					end
				end
			end

			-- Apply attributes
			if nodeData.attributes then
				for key, value in nodeData.attributes :: any do
					pcall(function() inst:SetAttribute(key, value) end)
				end
			end

			-- Apply source
			if nodeData.source and inst:IsA("LuaSourceContainer") then
				pcall(function() (inst :: any).Source = nodeData.source end)
			end

			inst.Parent = parentInst

			-- Recurse children
			if nodeData.children then
				for _, childData in nodeData.children :: any do
					recreateInstance(childData, inst)
				end
			end

			return inst
		end

		local instance = recreateInstance(data, parent)
		local childCount = #instance:GetDescendants()

		return {
			created = true,
			path = getPath(instance),
			className = instance.ClassName,
			childCount = childCount,
		}
	end)
end

-- ═══════════════════════════════════════════════════════════
-- GET FULL SCRIPT SOURCE (no truncation, for AI reading)
-- ═══════════════════════════════════════════════════════════

handlers["getFullSource"] = function(params)
	local instance = resolveInstance(params.path :: string)
	if not instance then error("Script not found: " .. params.path) end
	if not instance:IsA("LuaSourceContainer") then error("Not a script: " .. params.path) end

	local ScriptEditorService = game:GetService("ScriptEditorService")
	local source: string
	local ok, editorSource = pcall(function()
		return (ScriptEditorService :: any):GetEditorSource(instance)
	end)
	if ok and editorSource then
		source = editorSource
	else
		source = (instance :: any).Source
	end

	return {
		path = params.path,
		className = instance.ClassName,
		name = instance.Name,
		source = source,
		lineCount = #string.split(source, "\n"),
	}
end

-- ═══════════════════════════════════════════════════════════
-- GET PLUGIN VERSION (for version compatibility checking)
-- ═══════════════════════════════════════════════════════════

handlers["getPluginVersion"] = function(_params)
	return {
		version = Config.PLUGIN_VERSION,
		name = Config.PLUGIN_NAME,
	}
end

-- ═══════════════════════════════════════════════════════════
-- SHOW UPDATE NOTICE (in-Studio overlay when plugin is outdated)
-- ═══════════════════════════════════════════════════════════

handlers["showUpdateNotice"] = function(params)
	local CoreGui = game:GetService("CoreGui")

	-- Remove any existing notice
	local existing = CoreGui:FindFirstChild("RoStackUpdateNotice")
	if existing then existing:Destroy() end

	local currentVersion = (params.currentVersion :: string?) or Config.PLUGIN_VERSION
	local expectedVersion = (params.expectedVersion :: string?) or "latest"

	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "RoStackUpdateNotice"
	screenGui.DisplayOrder = 999998
	screenGui.IgnoreGuiInset = true
	screenGui.ResetOnSpawn = false

	-- Container in bottom-right corner
	local container = Instance.new("Frame")
	container.Name = "Container"
	container.Size = UDim2.new(0, 280, 0, 60)
	container.Position = UDim2.new(1, -16, 1, -16)
	container.AnchorPoint = Vector2.new(1, 1)
	container.BackgroundColor3 = Color3.fromRGB(40, 30, 10)
	container.BorderSizePixel = 0
	container.Parent = screenGui

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 8)
	corner.Parent = container

	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.fromRGB(250, 204, 21)
	stroke.Transparency = 0.6
	stroke.Thickness = 1
	stroke.Parent = container

	-- Warning icon + text
	local title = Instance.new("TextLabel")
	title.Name = "Title"
	title.Size = UDim2.new(1, -20, 0, 20)
	title.Position = UDim2.new(0, 10, 0, 8)
	title.BackgroundTransparency = 1
	title.Text = "⚠ Plugin Outdated (v" .. currentVersion .. ")"
	title.TextColor3 = Color3.fromRGB(250, 204, 21)
	title.TextSize = 13
	title.Font = Enum.Font.GothamBold
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.Parent = container

	local subtitle = Instance.new("TextLabel")
	subtitle.Name = "Subtitle"
	subtitle.Size = UDim2.new(1, -20, 0, 16)
	subtitle.Position = UDim2.new(0, 10, 0, 30)
	subtitle.BackgroundTransparency = 1
	subtitle.Text = "Update to v" .. expectedVersion .. " in the desktop app & restart"
	subtitle.TextColor3 = Color3.fromRGB(200, 180, 100)
	subtitle.TextSize = 11
	subtitle.Font = Enum.Font.Gotham
	subtitle.TextXAlignment = Enum.TextXAlignment.Left
	subtitle.Parent = container

	screenGui.Parent = CoreGui

	-- Auto-dismiss after 15 seconds
	task.delay(15, function()
		if screenGui and screenGui.Parent then
			screenGui:Destroy()
		end
	end)

	return { shown = true, currentVersion = currentVersion, expectedVersion = expectedVersion }
end

-- ── Public API for registering custom command handlers ──

-- ═══════════════════════════════════════════════════════════
-- RUN CODE (execute arbitrary Luau in the plugin context)
-- ═══════════════════════════════════════════════════════════

handlers["runCode"] = function(params)
	local code = params.code :: string
	if not code or code == "" then error("No code provided") end

	local fn, compileErr = loadstring(code)
	if not fn then
		error("Compile error: " .. tostring(compileErr))
	end

	local ok, result = pcall(fn)
	if not ok then
		error("Runtime error: " .. tostring(result))
	end

	return { executed = true, result = if result ~= nil then tostring(result) else nil }
end

-- ═══════════════════════════════════════════════════════════
-- PACKAGE INSTALLATION (handled via batch commands from desktop)
-- The desktop parses .rbxmx files and sends createInstance/insertScript
-- commands as a batch. This handler is a fallback for direct asset ID installs.
-- ═══════════════════════════════════════════════════════════

handlers["installPackage"] = function(params)
	return withRecording("Install package " .. tostring(params.package), function()
		local packageName = params.package :: string
		if not packageName or packageName == "" then error("No package name provided") end

		local parentPath = (params.parentPath :: string?) or "ReplicatedStorage"
		local parent = resolveInstance(parentPath)
		if not parent then error("Parent not found: " .. parentPath) end

		-- Check if already installed
		local existing = parent:FindFirstChild(packageName)
		if existing then
			return { installed = false, alreadyExists = true, message = packageName .. " is already installed in " .. parentPath, path = getPath(existing) }
		end

		-- If an asset ID is provided, use InsertService directly
		local assetId = params.assetId :: number?
		if assetId and assetId > 0 then
			local model = InsertService:LoadAsset(assetId)
			local children = model:GetChildren()
			local installed = {}
			for _, child in children do
				child.Parent = parent
				table.insert(installed, { name = child.Name, className = child.ClassName, path = getPath(child) })
			end
			model:Destroy()
			return { installed = true, package = packageName, parentPath = parentPath, children = installed, count = #installed }
		end

		error("Package installation should be handled via batch commands from the desktop app.")
	end)
end

function CommandExecutor.registerHandler(commandType: string, handler: (params: { [string]: any }) -> any)
	if handlers[commandType] then
		Logger.warn("CommandExecutor", "Overwriting handler for: " .. commandType)
	end
	handlers[commandType] = handler
end

return CommandExecutor
