--!strict
-- InstanceMap: Bidirectional map between IDs and Roblox instances
-- Ported from Rojo's InstanceMap with per-instance pause and change signals
-- Replaces path-based resolution with stable ID-based tracking

local RunService = game:GetService("RunService")
local Logger = require(script.Parent.Parent.Logger)

local InstanceMap = {}
InstanceMap.__index = InstanceMap

function InstanceMap.new(onInstanceChanged: ((Instance, string) -> ())?)
	local self = setmetatable({
		-- ID → Instance
		fromIds = {} :: { [string]: Instance },
		-- Instance → ID
		fromInstances = {} :: { [Instance]: string },
		-- Instances with paused change detection
		pausedInstances = {} :: { [Instance]: boolean },
		-- Instance → signal connection(s)
		signals = {} :: { [Instance]: any },
		-- Callback for property changes
		onInstanceChanged = onInstanceChanged,
	}, InstanceMap)
	return self
end

function InstanceMap:size(): number
	local count = 0
	for _ in pairs(self.fromIds) do count += 1 end
	return count
end

function InstanceMap:stop()
	for instance in pairs(self.fromInstances) do
		self:removeInstance(instance)
	end
end

function InstanceMap:insert(id: string, instance: Instance)
	-- Remove any existing mappings for this ID or instance
	self:removeId(id)
	self:removeInstance(instance)

	self.fromIds[id] = instance
	self.fromInstances[instance] = id
	self:_connectSignals(instance)
end

function InstanceMap:removeId(id: string)
	local instance = self.fromIds[id]
	if instance then
		self:_disconnectSignals(instance)
		self.fromIds[id] = nil
		self.fromInstances[instance] = nil
		self.pausedInstances[instance] = nil
	end
end

function InstanceMap:removeInstance(instance: Instance)
	local id = self.fromInstances[instance]
	self:_disconnectSignals(instance)
	if id then
		self.fromInstances[instance] = nil
		self.fromIds[id] = nil
		self.pausedInstances[instance] = nil
	end
end

-- Use Parent = nil instead of Destroy() so ChangeHistoryService can undo
function InstanceMap:destroyInstance(instance: Instance)
	local descendants = instance:GetDescendants()
	local id = self.fromInstances[instance]

	instance.Parent = nil

	if id then self:removeId(id) end
	for _, desc in descendants do
		self:removeInstance(desc)
	end
end

function InstanceMap:destroyId(id: string)
	local instance = self.fromIds[id]
	if instance then
		self:destroyInstance(instance)
	else
		self:removeId(id)
	end
end

function InstanceMap:getInstance(id: string): Instance?
	return self.fromIds[id]
end

function InstanceMap:getId(instance: Instance): string?
	return self.fromInstances[instance]
end

-- Per-instance pause (not global — safe for concurrent operations)
function InstanceMap:pauseInstance(instance: Instance)
	if self.fromInstances[instance] then
		self.pausedInstances[instance] = true
	end
end

function InstanceMap:unpauseInstance(instance: Instance)
	self.pausedInstances[instance] = nil
end

function InstanceMap:unpauseAll()
	table.clear(self.pausedInstances)
end

-- Execute a function with an instance paused, then unpause
function InstanceMap:withPaused(instance: Instance, fn: () -> ())
	self:pauseInstance(instance)
	local ok, err = pcall(fn)
	self:unpauseInstance(instance)
	if not ok then error(err) end
end

function InstanceMap:_connectSignals(instance: Instance)
	-- ValueBase instances override Changed to only fire for Value property
	if instance:IsA("ValueBase") then
		local sigs = {
			instance:GetPropertyChangedSignal("Name"):Connect(function()
				self:_onChanged(instance, "Name")
			end),
			instance:GetPropertyChangedSignal("Value"):Connect(function()
				self:_onChanged(instance, "Value")
			end),
			instance:GetPropertyChangedSignal("Parent"):Connect(function()
				self:_onChanged(instance, "Parent")
			end),
		}
		self.signals[instance] = sigs
	else
		self.signals[instance] = instance.Changed:Connect(function(propertyName)
			self:_onChanged(instance, propertyName)
		end)
	end
end

function InstanceMap:_onChanged(instance: Instance, propertyName: string)
	if self.pausedInstances[instance] then return end
	if self.onInstanceChanged == nil then return end
	if RunService:IsRunning() then return end
	self.onInstanceChanged(instance, propertyName)
end

function InstanceMap:_disconnectSignals(instance: Instance)
	local sigs = self.signals[instance]
	if sigs == nil then return end

	if typeof(sigs) == "table" then
		for _, sig in sigs do sig:Disconnect() end
	else
		sigs:Disconnect()
	end
	self.signals[instance] = nil
end

return InstanceMap
