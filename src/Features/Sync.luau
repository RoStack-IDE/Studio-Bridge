--!strict
-- Studio Bridge Sync Feature
-- Scans the ENTIRE game hierarchy, syncs all objects + scripts.
-- Uses a single WebSocket (CreateWebStreamClient) for ALL communication:
--   - Plugin → Server: sync pushes, command results, pings
--   - Server → Plugin: AI tool commands, web editor edits, sync acks

local APIClient = require(script.Parent.Parent.API.Client)
local Config = require(script.Parent.Parent.Config)
local Logger = require(script.Parent.Parent.Logger)
local CommandExecutor = require(script.Parent.CommandExecutor)

type ScriptEntry = {
	name: string,
	path: string,
	source: string,
	className: string,
	guid: string,
}

type GameObjectEntry = {
	id: string,
	name: string,
	type: string,
	path: string,
	parentId: string?,
	children: { string },
	source: string?,
}

local Sync = {}

local SCRIPT_CLASSES = {
	["Script"] = true,
	["LocalScript"] = true,
	["ModuleScript"] = true,
}

-- Technically you could add more roots if needed
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
	game:GetService("Players"),
	game:GetService("Teams"),
}

local function stableId(path: string): string
	return "obj-" .. string.gsub(path, "[^%w/]", "_")
end

local function getPath(instance: Instance): string
	local parts = {}
	local current: Instance? = instance
	while current and current ~= game do
		table.insert(parts, 1, (current :: Instance).Name)
		current = (current :: Instance).Parent
	end
	return table.concat(parts, "/")
end

local function scanAll(instance: Instance, parentId: string?, scripts: { ScriptEntry }, objects: { GameObjectEntry })
	local path = getPath(instance)
	local id = stableId(path)
	local isScript = SCRIPT_CLASSES[instance.ClassName] == true

	local source: string? = nil
	if isScript then
		local ok, src = pcall(function()
			return (instance :: any).Source
		end)
		if ok and src then
			source = src
			table.insert(scripts, {
				name = instance.Name,
				path = path,
				source = src,
				className = instance.ClassName,
				guid = id,
			})
		end
	end

	local childIds: { string } = {}
	for _, child in ipairs(instance:GetChildren()) do
		local childPath = getPath(child)
		table.insert(childIds, stableId(childPath))
	end

	table.insert(objects, {
		id = id,
		name = instance.Name,
		type = instance.ClassName,
		path = path,
		parentId = parentId,
		children = childIds,
		source = source,
	})

	for _, child in ipairs(instance:GetChildren()) do
		scanAll(child, id, scripts, objects)
	end
end

function Sync.collectAll(): ({ ScriptEntry }, { GameObjectEntry })
	local scripts: { ScriptEntry } = {}
	local objects: { GameObjectEntry } = {}
	for _, root in ipairs(ROOTS) do
		scanAll(root, nil, scripts, objects)
	end
	return scripts, objects
end

-- ── DataModel encoding for luau-lsp ──
-- Matches the EncodedInstance format expected by luau-lsp's $/plugin/full notification:
-- { Name: string, ClassName: string, FilePaths: {string}, Children: {EncodedInstance} }

type EncodedInstance = {
	Name: string,
	ClassName: string,
	FilePaths: { string },
	Children: { EncodedInstance },
}

local function encodeInstance(instance: Instance): EncodedInstance
	local children: { EncodedInstance } = {}
	for _, child in ipairs(instance:GetChildren()) do
		table.insert(children, encodeInstance(child))
	end

	-- Build FilePaths for script instances so luau-lsp can map
	-- opened file URIs back to DataModel instances for autocomplete.
	-- The web editor opens files as file:///workspace/<path>.luau
	local filePaths: { string } = {}
	if SCRIPT_CLASSES[instance.ClassName] then
		local path = getPath(instance)
		table.insert(filePaths, path .. ".luau")
	end

	return {
		Name = instance.Name,
		ClassName = instance.ClassName,
		FilePaths = filePaths,
		Children = children,
	}
end

function Sync.encodeDataModel(): EncodedInstance
	local rootChildren: { EncodedInstance } = {}
	for _, root in ipairs(ROOTS) do
		table.insert(rootChildren, encodeInstance(root))
	end
	return {
		Name = "game",
		ClassName = "DataModel",
		FilePaths = {},
		Children = rootChildren,
	}
end

-- Track whether DM info has been sent this session (avoids redundant sends)
local _lastDMHash: string? = nil

local function getTreeHash(tree: EncodedInstance): string
	-- Simple hash: count total nodes (cheap proxy for tree identity)
	local count = 0
	local function walk(node: EncodedInstance)
		count += 1
		for _, child in node.Children do
			walk(child)
		end
	end
	walk(tree)
	return tostring(count) .. ":" .. tree.Name
end

-- Send DataModel tree to server (debounced externally)
function Sync.pushDataModel()
	if not APIClient.isConnected() or not APIClient.isWSConnected() then
		return
	end

	local tree = Sync.encodeDataModel()
	local hash = getTreeHash(tree)

	-- Skip if tree hasn't changed
	if hash == _lastDMHash then
		return
	end
	_lastDMHash = hash

	APIClient.wsSendDataModel(tree)
	Logger.log("Sync", "Pushed DataModel tree to server")
end

-- Push game state over WebSocket (non-blocking, fire-and-forget)
function Sync.pushToServer()
	if not APIClient.isConnected() or not APIClient.isWSConnected() then
		return
	end

	local scripts, gameObjects = Sync.collectAll()
	APIClient.wsSyncAll(scripts, gameObjects)
	Logger.log("Sync", string.format("Pushed %d scripts, %d objects via WS", #scripts, #gameObjects))
end

function Sync.applyWebEdits(edits: { any })
	local ScriptEditorService = game:GetService("ScriptEditorService")

	for _, entry in ipairs(edits) do
		local ok, applyErr = pcall(function()
			local parts = string.split(entry.path, "/")
			local current: Instance = game :: Instance
			for _, part in ipairs(parts) do
				local found = (current :: any):FindFirstChild(part)
				if found then
					current = found
				else
					return
				end
			end
			if SCRIPT_CLASSES[current.ClassName] then
				local existing = (current :: any).Source
				if existing ~= entry.source then
					-- Try ScriptEditorService first (updates the open editor buffer)
					local seOk = pcall(function()
						local doc = ScriptEditorService:FindScriptDocument(current :: LuaSourceContainer)
						if doc then
							-- Script is open in editor — use EditTextAsync to replace content
							local lineCount = doc:GetLineCount()
							local lastLineText = doc:GetLine(lineCount)
							local lastLineLen = if lastLineText then #lastLineText else 0
							-- Replace entire document content
							doc:EditTextAsync(entry.source, 1, 1, lineCount, lastLineLen + 1)
							Logger.log("Sync", "Applied web edit (editor) -> " .. entry.path)

							-- Scroll Studio editor to the cursor position from the web editor
							if entry.cursorLine then
								local line = entry.cursorLine :: number
								local col = (entry.cursorColumn :: number?) or 1
								pcall(function()
									doc:RequestSetSelectionAsync(line, col, line, col)
								end)
							end
						else
							-- Script not open in editor — set Source directly
							(current :: any).Source = entry.source
							Logger.log("Sync", "Applied web edit (source) -> " .. entry.path)
						end
					end)
					if not seOk then
						-- Fallback: set Source property directly
						(current :: any).Source = entry.source
						Logger.log("Sync", "Applied web edit (fallback) -> " .. entry.path)
					end
				end
			end
		end)
		if not ok then
			Logger.error("Sync", "Failed to apply edit for " .. tostring(entry.path) .. ": " .. tostring(applyErr))
		end
	end
end

-- Execute AI tool commands received from server (via WebSocket)
function Sync.executeCommands(commands: { any })
	Logger.log("Sync", "Received " .. #commands .. " command(s) via WebSocket")
	local results = {}

	for _, cmd in ipairs(commands) do
		local success, result = CommandExecutor.execute(cmd.type, cmd.params)
		table.insert(results, {
			commandId = cmd.id,
			success = success,
			result = if success then result else nil,
			error = if not success then tostring(result) else nil,
		})
	end

	-- Report results back over WebSocket
	if #results > 0 then
		APIClient.wsReportResults(results)
		Logger.log("Sync", "Reported " .. #results .. " command result(s) via WS")
	end

	-- After executing commands, do an immediate sync push
	-- so the web explorer reflects the changes right away
	task.spawn(function()
		task.wait(0.5)
		Sync.pushToServer()
	end)
end

-- Combined auto-sync + WebSocket event listeners
local _syncRunning = false
local _cmdConnection: any = nil
local _editsConnection: any = nil
local _syncAckConnection: any = nil
local _disconnectConnection: any = nil
local _changeConnections: { RBXScriptConnection } = {}
local _pendingPush = false
local _logConnection: RBXScriptConnection? = nil
local _errorConnection: RBXScriptConnection? = nil

-- ── Output batching state ──
type OutputBufferEntry = {
	seq: number,
	level: string,
	message: string,
	timestamp: number,
	context: string?,
}

local _outputBuffer: { OutputBufferEntry } = {}
local _outputSeq: number = 0
local _outputFlushScheduled: boolean = false
local _sessionStartEpoch: number = 0

local function bufferOutput(level: string, message: string, context: string?)
	_outputSeq += 1
	table.insert(_outputBuffer, {
		seq = _outputSeq,
		level = level,
		message = message,
		timestamp = _sessionStartEpoch + math.floor(os.clock() * 1000),
		context = context,
	})
	if not _outputFlushScheduled then
		_outputFlushScheduled = true
		task.delay(0.1, function()
			_outputFlushScheduled = false
			if #_outputBuffer > 0 and APIClient.isWSConnected() then
				APIClient.wsSend("output", { entries = _outputBuffer })
			end
			table.clear(_outputBuffer)
		end)
	end
end

-- Debounced push: coalesces rapid changes into a single sync
local function debouncedPush()
	if _pendingPush then return end
	_pendingPush = true
	task.defer(function()
		task.wait(0.15) -- 150ms debounce
		_pendingPush = false
		if _syncRunning then
			pcall(function() Sync.pushToServer() end)
		end
	end)
end

-- Debounced DataModel push: separate debounce for DM tree (0.5s like official plugin)
local _pendingDMPush = false
local function debouncedDMPush()
	if _pendingDMPush then return end
	_pendingDMPush = true
	task.defer(function()
		task.wait(0.5) -- 500ms debounce (matches official luau-lsp plugin)
		_pendingDMPush = false
		if _syncRunning then
			pcall(function() Sync.pushDataModel() end)
		end
	end)
end

export type GameContext = {
	sessionId: string,
	universeId: string,
	placeId: string,
	placeVersion: string,
}

function Sync.startAutoSync(onStatus: ((status: string, msg: string) -> ())?, onDisconnect: (() -> ())?, gameContext: GameContext?)
	if _syncRunning then return end
	_syncRunning = true

	-- Reset output batching state for new session
	_outputSeq = 0
	_sessionStartEpoch = os.time() * 1000
	table.clear(_outputBuffer)
	_outputFlushScheduled = false

	-- Connect WebSocket for bidirectional real-time communication
	APIClient.connectWS()
	Logger.step("Sync", "WebSocket connected, auto-sync started")

	-- Send plugin_hello with composite session data after WS authenticates
	if gameContext then
		local _helloConnection
		_helloConnection = APIClient.OnConnected:Connect(function()
			APIClient.wsSendHello(gameContext)
			Logger.step("Sync", "Sent plugin_hello: " .. gameContext.universeId .. ":" .. gameContext.placeId .. ":" .. gameContext.sessionId)
			if _helloConnection then
				_helloConnection:Disconnect()
				_helloConnection = nil
			end
		end)
	end

	-- Listen for AI tool commands from the server
	_cmdConnection = APIClient.OnCommandsReceived:Connect(function(commands)
		Sync.executeCommands(commands)
	end)

	-- Listen for web editor edits from the server
	_editsConnection = APIClient.OnWebEditsReceived:Connect(function(edits)
		Logger.log("Sync", "Received " .. #edits .. " web edit(s) via WebSocket")
		Sync.applyWebEdits(edits)
	end)

	-- Listen for sync acknowledgments
	_syncAckConnection = APIClient.OnSyncAck:Connect(function(data)
		if onStatus then onStatus("synced", "Synced") end
	end)

	-- Listen for remote disconnect (web client ended session)
	_disconnectConnection = APIClient.OnDisconnected:Connect(function()
		Logger.step("Sync", "Session ended by web client")
		Sync.stopAutoSync()
		if onDisconnect then onDisconnect() end
	end)

	-- Listen for game tree changes → push immediately (debounced)
	for _, root in ipairs(ROOTS) do
		table.insert(_changeConnections, root.DescendantAdded:Connect(function()
			debouncedPush()
			debouncedDMPush()
		end))
		table.insert(_changeConnections, root.DescendantRemoving:Connect(function()
			debouncedPush()
			debouncedDMPush()
		end))
		-- Listen for property changes on scripts (source edits in Studio)
		table.insert(_changeConnections, root.DescendantAdded:Connect(function(desc)
			if desc:IsA("LuaSourceContainer") then
				local conn = desc.Changed:Connect(function()
					debouncedPush()
				end)
				-- Clean up when removed
				desc.Destroying:Once(function()
					conn:Disconnect()
				end)
			end
		end))
	end

	-- Also watch existing scripts for changes
	for _, root in ipairs(ROOTS) do
		for _, desc in root:GetDescendants() do
			if desc:IsA("LuaSourceContainer") then
				local conn = desc.Changed:Connect(function()
					debouncedPush()
				end)
				desc.Destroying:Once(function()
					conn:Disconnect()
				end)
			end
		end
	end

	-- Fallback periodic sync (catches anything the events miss)
	task.spawn(function()
		while _syncRunning do
			local ok, err = pcall(function()
				Sync.pushToServer()
			end)
			if not ok then
				Logger.error("Sync", "Auto-sync cycle failed: " .. tostring(err))
				if onStatus then onStatus("error", tostring(err)) end
			end
			-- Also periodically refresh DataModel tree
			pcall(function() Sync.pushDataModel() end)
			task.wait(Config.AUTO_SYNC_INTERVAL)
		end
	end)

	-- Initial push (sync + DataModel tree)
	debouncedPush()
	debouncedDMPush()

	-- Capture LogService output and forward to desktop IDE (batched)
	local LogService = game:GetService("LogService")
	_logConnection = LogService.MessageOut:Connect(function(message: string, messageType: Enum.MessageType)
		if not APIClient.isWSConnected() then return end
		-- Filter out our own log messages to avoid feedback loops
		local prefixLen = #Config.LOG_PREFIX
		if string.sub(message, 1, prefixLen) == Config.LOG_PREFIX then return end
		local level = "log"
		if messageType == Enum.MessageType.MessageError then
			level = "error"
		elseif messageType == Enum.MessageType.MessageWarning then
			level = "warning"
		elseif messageType == Enum.MessageType.MessageInfo then
			level = "info"
		elseif messageType == Enum.MessageType.MessageOutput then
			level = "log"
		end
		bufferOutput(level, message)
	end)

	-- Capture ScriptContext errors for richer error info with stack traces (batched)
	local ScriptContext = game:GetService("ScriptContext")
	_errorConnection = ScriptContext.Error:Connect(function(message: string, stackTrace: string, scriptInstance: LuaSourceContainer?)
		if not APIClient.isWSConnected() then return end
		-- Filter out our own errors
		if string.find(message, Config.LOG_PREFIX, 1, true) then return end
		local scriptPath = if scriptInstance then scriptInstance:GetFullName() else "unknown"
		local fullMessage = message
		if stackTrace and stackTrace ~= "" then
			fullMessage = message .. "\n" .. stackTrace
		end
		bufferOutput("error", fullMessage, scriptPath)
	end)
end

function Sync.stopAutoSync()
	_syncRunning = false
	_lastDMHash = nil

	-- Clear output buffer
	table.clear(_outputBuffer)
	_outputFlushScheduled = false

	-- Disconnect change listeners
	for _, conn in _changeConnections do
		conn:Disconnect()
	end
	table.clear(_changeConnections)

	-- Disconnect WebSocket event listeners
	if _cmdConnection then
		_cmdConnection:Disconnect()
		_cmdConnection = nil
	end
	if _editsConnection then
		_editsConnection:Disconnect()
		_editsConnection = nil
	end
	if _syncAckConnection then
		_syncAckConnection:Disconnect()
		_syncAckConnection = nil
	end
	if _disconnectConnection then
		_disconnectConnection:Disconnect()
		_disconnectConnection = nil
	end

	-- Disconnect log listener
	if _logConnection then
		_logConnection:Disconnect()
		_logConnection = nil
	end

	-- Disconnect error listener
	if _errorConnection then
		_errorConnection:Disconnect()
		_errorConnection = nil
	end

	-- Close WebSocket
	APIClient.disconnectWS()

	Logger.step("Sync", "Auto-sync and WebSocket stopped")
end

function Sync.isRunning(): boolean
	return _syncRunning
end

return Sync
