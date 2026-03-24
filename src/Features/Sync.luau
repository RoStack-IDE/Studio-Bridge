--!strict
-- Studio Bridge Sync Feature
-- Uses incremental delta sync to minimize lag on large games.
-- First sync sends everything (full), subsequent syncs send only changes.
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

-- ── Delta sync state ──
-- Caches from the last sync cycle to detect changes
local _lastScriptHashes: { [string]: string } = {}   -- guid -> hash of source
local _lastObjectHashes: { [string]: string } = {}   -- id -> hash of structure
local _lastObjectIds: { [string]: boolean } = {}      -- set of all known object ids
local _hasSentFullSync = false                         -- first sync must be full

-- Simple fast hash: use string.len + first/last/mid chars + a checksum
-- This avoids serializing the entire source just to detect changes
local function quickHash(s: string): string
	local len = #s
	if len == 0 then return "0:" end
	-- Sample a few bytes for a fast fingerprint
	local mid = math.floor(len / 2)
	local q1 = math.floor(len / 4)
	local q3 = math.floor(len * 3 / 4)
	return tostring(len) .. ":" 
		.. string.byte(s, 1) .. ":"
		.. string.byte(s, mid > 0 and mid or 1) .. ":"
		.. string.byte(s, q1 > 0 and q1 or 1) .. ":"
		.. string.byte(s, q3 > 0 and q3 or 1) .. ":"
		.. string.byte(s, len)
end

-- Hash an object's structure (name + type + children count) without source.
-- We use child count instead of the full list because GetChildren() order
-- is not stable in Roblox — sorting 21K child lists every tick is wasteful.
-- Count changes reliably detect adds/removes, and name/type catch renames.
local function objectHash(name: string, className: string, childCount: number): string
	return name .. ":" .. className .. ":" .. tostring(childCount)
end

-- Optimized scan: passes the already-computed path down to avoid walking up
-- to root for every node. Disambiguates siblings with the same name by
-- appending [2], [3], etc. to the path (Roblox allows duplicate names).
local function scanAllFast(
	instance: Instance,
	myPath: string,
	parentId: string?,
	scripts: { ScriptEntry },
	objects: { GameObjectEntry }
)
	local id = stableId(myPath)
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
				path = myPath,
				source = src,
				className = instance.ClassName,
				guid = id,
			})
		end
	end

	local children = instance:GetChildren()

	-- Detect duplicate names among siblings and disambiguate paths
	local nameCount: { [string]: number } = {}
	for _, child in ipairs(children) do
		nameCount[child.Name] = (nameCount[child.Name] or 0) + 1
	end
	local nameIndex: { [string]: number } = {}
	local childPaths: { string } = {}
	for i, child in ipairs(children) do
		local n = child.Name
		if nameCount[n] > 1 then
			nameIndex[n] = (nameIndex[n] or 0) + 1
			if nameIndex[n] == 1 then
				childPaths[i] = myPath .. "/" .. n
			else
				childPaths[i] = myPath .. "/" .. n .. "[" .. tostring(nameIndex[n]) .. "]"
			end
		else
			childPaths[i] = myPath .. "/" .. n
		end
	end

	local childIds: { string } = {}
	for i, _ in ipairs(children) do
		table.insert(childIds, stableId(childPaths[i]))
	end

	table.insert(objects, {
		id = id,
		name = instance.Name,
		type = instance.ClassName,
		path = myPath,
		parentId = parentId,
		children = childIds,
		source = source,
	})

	for i, child in ipairs(children) do
		scanAllFast(child, childPaths[i], id, scripts, objects)
	end
end

function Sync.collectAll(): ({ ScriptEntry }, { GameObjectEntry })
	local scripts: { ScriptEntry } = {}
	local objects: { GameObjectEntry } = {}
	for _, root in ipairs(ROOTS) do
		scanAllFast(root, root.Name, nil, scripts, objects)
	end
	return scripts, objects
end

-- Collect delta: only scripts whose source changed, only objects whose structure changed,
-- plus lists of removed object IDs.
-- Returns: changedScripts, changedObjects, removedIds, isFull, hasChanges
function Sync.collectDelta(): ({ ScriptEntry }, { GameObjectEntry }, { string }, boolean, boolean)
	local allScripts: { ScriptEntry } = {}
	local allObjects: { GameObjectEntry } = {}
	for _, root in ipairs(ROOTS) do
		scanAllFast(root, root.Name, nil, allScripts, allObjects)
	end

	-- First sync: send everything, populate caches
	if not _hasSentFullSync then
		_hasSentFullSync = true
		-- Populate caches (first-seen wins for duplicate IDs)
		for _, s in ipairs(allScripts) do
			if not _lastScriptHashes[s.guid] then
				_lastScriptHashes[s.guid] = quickHash(s.source)
			end
		end
		for _, o in ipairs(allObjects) do
			if not _lastObjectIds[o.id] then
				_lastObjectHashes[o.id] = objectHash(o.name, o.type, #o.children)
				_lastObjectIds[o.id] = true
			end
		end
		return allScripts, allObjects, {}, true, true
	end

	-- Delta: compare against caches
	local changedScripts: { ScriptEntry } = {}
	local changedObjects: { GameObjectEntry } = {}
	local currentObjectIds: { [string]: boolean } = {}

	-- Build new script hash map (first-seen wins for duplicate IDs)
	local newScriptHashes: { [string]: string } = {}
	for _, s in ipairs(allScripts) do
		if not newScriptHashes[s.guid] then
			local h = quickHash(s.source)
			newScriptHashes[s.guid] = h
			if _lastScriptHashes[s.guid] ~= h then
				table.insert(changedScripts, s)
			end
		end
	end

	-- Build new object hash map and detect changes (first-seen wins for duplicate IDs)
	local newObjectHashes: { [string]: string } = {}
	for _, o in ipairs(allObjects) do
		if not currentObjectIds[o.id] then
			currentObjectIds[o.id] = true
			local h = objectHash(o.name, o.type, #o.children)
			newObjectHashes[o.id] = h
			if _lastObjectHashes[o.id] ~= h then
				table.insert(changedObjects, o)
			end
		end
	end

	-- Detect removed objects
	local removedIds: { string } = {}
	for id in pairs(_lastObjectIds) do
		if not currentObjectIds[id] then
			table.insert(removedIds, id)
		end
	end

	-- Update caches
	_lastScriptHashes = newScriptHashes
	_lastObjectHashes = newObjectHashes
	_lastObjectIds = currentObjectIds

	local hasChanges = #changedScripts > 0 or #changedObjects > 0 or #removedIds > 0
	return changedScripts, changedObjects, removedIds, false, hasChanges
end

-- Reset delta state (e.g. on reconnect)
function Sync.resetDeltaState()
	_lastScriptHashes = {}
	_lastObjectHashes = {}
	_lastObjectIds = {}
	_hasSentFullSync = false
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

local function getPath(instance: Instance): string
	local parts = {}
	local current: Instance? = instance
	while current and current ~= game do
		local inst = current :: Instance
		local name = inst.Name
		-- Disambiguate siblings with the same name
		local parent = inst.Parent
		if parent and parent ~= game then
			local idx = 0
			local myIdx = 0
			for _, sibling in ipairs(parent:GetChildren()) do
				if sibling.Name == name then
					idx += 1
					if sibling == inst then
						myIdx = idx
					end
				end
			end
			if idx > 1 and myIdx > 1 then
				name = name .. "[" .. tostring(myIdx) .. "]"
			end
		end
		table.insert(parts, 1, name)
		current = inst.Parent
	end
	return table.concat(parts, "/")
end

local function encodeInstance(instance: Instance): EncodedInstance
	local children: { EncodedInstance } = {}
	for _, child in ipairs(instance:GetChildren()) do
		table.insert(children, encodeInstance(child))
	end

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

function Sync.pushDataModel()
	if not APIClient.isConnected() or not APIClient.isWSConnected() then
		return
	end

	local tree = Sync.encodeDataModel()
	local hash = getTreeHash(tree)

	if hash == _lastDMHash then
		return
	end
	_lastDMHash = hash

	APIClient.wsSendDataModel(tree)
	Logger.log("Sync", "Pushed DataModel tree to server")
end

-- Push game state over WebSocket using delta sync
-- First push sends full state, subsequent pushes send only changes
function Sync.pushToServer()
	if not APIClient.isConnected() or not APIClient.isWSConnected() then
		return
	end

	local scripts, gameObjects, removedIds, isFull, hasChanges = Sync.collectDelta()

	if isFull then
		-- First sync: send everything using the original sync message
		APIClient.wsSyncAll(scripts, gameObjects)
		Logger.log("Sync", string.format("Full sync: %d scripts, %d objects via WS", #scripts, #gameObjects))
	elseif hasChanges then
		-- Delta sync: send only changes
		APIClient.wsSend("sync_delta", {
			scripts = scripts,
			gameObjects = gameObjects,
			removedIds = removedIds,
		})
		Logger.log("Sync", string.format(
			"Delta sync: %d scripts, %d objects changed, %d removed",
			#scripts, #gameObjects, #removedIds
		))
	end
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
					local seOk = pcall(function()
						local doc = ScriptEditorService:FindScriptDocument(current :: LuaSourceContainer)
						if doc then
							local lineCount = doc:GetLineCount()
							local lastLineText = doc:GetLine(lineCount)
							local lastLineLen = if lastLineText then #lastLineText else 0
							doc:EditTextAsync(entry.source, 1, 1, lineCount, lastLineLen + 1)
							Logger.log("Sync", "Applied web edit (editor) -> " .. entry.path)

							if entry.cursorLine then
								local line = entry.cursorLine :: number
								local col = (entry.cursorColumn :: number?) or 1
								pcall(function()
									doc:RequestSetSelectionAsync(line, col, line, col)
								end)
							end
						else
							(current :: any).Source = entry.source
							Logger.log("Sync", "Applied web edit (source) -> " .. entry.path)
						end
					end)
					if not seOk then
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

	if #results > 0 then
		APIClient.wsReportResults(results)
		Logger.log("Sync", "Reported " .. #results .. " command result(s) via WS")
	end

	-- After executing commands, force a full re-sync so changes are reflected
	task.spawn(function()
		task.wait(0.5)
		Sync.resetDeltaState()
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
		task.wait(0.5)
		_pendingDMPush = false
		if _syncRunning then
			pcall(function() Sync.pushDataModel() end)
		end
	end)
end

export type GameContext = {
	sessionId: string,
	projectId: string?,
	universeId: string,
	placeId: string,
	placeVersion: string,
}

function Sync.startAutoSync(onStatus: ((status: string, msg: string) -> ())?, onDisconnect: (() -> ())?, gameContext: GameContext?)
	if _syncRunning then return end
	_syncRunning = true

	-- Reset delta state for fresh session
	Sync.resetDeltaState()

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
		table.insert(_changeConnections, root.DescendantAdded:Connect(function(desc)
			if desc:IsA("LuaSourceContainer") then
				local conn = desc.Changed:Connect(function()
					debouncedPush()
				end)
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

	-- Fallback periodic sync — safety net only, events handle real-time changes.
	-- Runs at a much longer interval to avoid lagging Studio on large games.
	task.spawn(function()
		while _syncRunning do
			task.wait(Config.FALLBACK_SYNC_INTERVAL)
			if not _syncRunning then break end
			local ok, err = pcall(function()
				Sync.pushToServer()
			end)
			if not ok then
				Logger.error("Sync", "Auto-sync cycle failed: " .. tostring(err))
				if onStatus then onStatus("error", tostring(err)) end
			end
			pcall(function() Sync.pushDataModel() end)
		end
	end)

	-- Initial push (sync + DataModel tree)
	debouncedPush()
	debouncedDMPush()

	-- Capture LogService output and forward to desktop IDE (batched)
	local LogService = game:GetService("LogService")
	_logConnection = LogService.MessageOut:Connect(function(message: string, messageType: Enum.MessageType)
		if not APIClient.isWSConnected() then return end
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

	-- Reset delta state
	Sync.resetDeltaState()

	-- Clear output buffer
	table.clear(_outputBuffer)
	_outputFlushScheduled = false

	-- Disconnect change listeners
	for _, conn in _changeConnections do
		conn:Disconnect()
	end
	table.clear(_changeConnections)

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

	if _logConnection then
		_logConnection:Disconnect()
		_logConnection = nil
	end

	if _errorConnection then
		_errorConnection:Disconnect()
		_errorConnection = nil
	end

	APIClient.disconnectWS()

	Logger.step("Sync", "Auto-sync and WebSocket stopped")
end

function Sync.isRunning(): boolean
	return _syncRunning
end

return Sync
