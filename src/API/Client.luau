--!strict
-- Studio Bridge API Client
-- Handles HTTP + WebSocket communication with the server
-- Uses session-based auth with Bearer tokens
-- Uses CreateWebStreamClient WebSocket for fully bidirectional real-time communication

local HttpService = game:GetService("HttpService")
local Config = require(script.Parent.Parent.Config)
local Promise = require(script.Parent.Parent.Packages.Promise)
local Signal = require(script.Parent.Parent.Packages.Signal)

local Client = {}

local _serverUrl: string = ""
local _sessionToken: string = ""
local _sessionId: string = ""
local _wsClient: any = nil

-- Signals for real-time events from the server
Client.OnCommandsReceived = Signal.new()   -- fires with { {id, type, params} }
Client.OnWebEditsReceived = Signal.new()   -- fires with { ScriptEntry }
Client.OnSyncAck          = Signal.new()   -- fires with { scriptCount, objectCount, webEdits? }
Client.OnConnected        = Signal.new()   -- fires when WebSocket authenticates
Client.OnDisconnected     = Signal.new()   -- fires when WebSocket closes
Client.OnError            = Signal.new()   -- fires with error string

function Client.init(serverUrl: string)
	_serverUrl = serverUrl
end

function Client.getSessionId(): string
	return _sessionId
end

function Client.getSessionToken(): string
	return _sessionToken
end

function Client.isConnected(): boolean
	return _sessionToken ~= ""
end

function Client.isWSConnected(): boolean
	return _wsClient ~= nil
end

-- Low-level HTTP request with optional auth (used for initial session claim + ping)
local function request(method: string, endpoint: string, body: any?, useAuth: boolean?)
	return Promise.new(function(resolve, reject)
		local url = _serverUrl .. endpoint
		local headers: { [string]: string } = {
			["Content-Type"] = "application/json",
			["X-Studio-Bridge"] = Config.PLUGIN_NAME .. "/" .. Config.PLUGIN_VERSION,
		}
		if useAuth ~= false and _sessionToken ~= "" then
			headers["Authorization"] = "Bearer " .. _sessionToken
		end

		local payload = {
			Url = url,
			Method = method,
			Headers = headers,
			Body = body and HttpService:JSONEncode(body) or nil,
		}

		-- Timeout wrapper: prevent hanging when network is disconnected
		local TIMEOUT_SECONDS = Config.HTTP_TIMEOUT
		local requestCompleted = false
		local pcallSuccess, result

		task.spawn(function()
			pcallSuccess, result = pcall(function()
				return HttpService:RequestAsync(payload)
			end)
			requestCompleted = true
		end)

		if TIMEOUT_SECONDS > 0 then
			local startTime = os.clock()
			while not requestCompleted and (os.clock() - startTime) < TIMEOUT_SECONDS do
				task.wait(0.1)
			end

			if not requestCompleted then
				reject("Request timed out after " .. TIMEOUT_SECONDS .. "s: " .. method .. " " .. endpoint)
				return
			end
		else
			-- No timeout, wait indefinitely
			while not requestCompleted do
				task.wait(0.1)
			end
		end

		if not pcallSuccess then
			reject("HTTP request failed: " .. tostring(result))
			return
		end

		if result.StatusCode < 200 or result.StatusCode >= 300 then
			reject("Server error " .. result.StatusCode .. ": " .. result.Body)
			return
		end

		local ok, decoded = pcall(HttpService.JSONDecode, HttpService, result.Body)
		if not ok then
			reject("Failed to decode response JSON")
			return
		end

		resolve(decoded)
	end)
end

-- Ping the server to check connectivity (HTTP, pre-WebSocket)
function Client.ping()
	return request("GET", "/api/ping", nil, false)
end

-- Auto-discover an available session from the desktop IDE (replaces manual pairing)
function Client.discover()
	return request("GET", "/api/discover", nil, false):andThen(function(data)
		if data.success then
			_sessionToken = data.token
			_sessionId = data.sessionId
		end
		return data
	end)
end

-- Disconnect the current session and close WebSocket
function Client.disconnect()
	Client.disconnectWS()
	_sessionToken = ""
	_sessionId = ""
end

-- ── WebSocket: single bidirectional connection ──

-- Send a JSON message over the WebSocket
function Client.wsSend(msgType: string, payload: { [string]: any }?)
	if not _wsClient then return end
	local msg = payload or {}
	msg.type = msgType
	pcall(function()
		_wsClient:Send(HttpService:JSONEncode(msg))
	end)
end

-- Send plugin_hello with composite session context
function Client.wsSendHello(context: {
	sessionId: string,
	projectId: string?,
	placeName: string?,
	universeId: string,
	placeId: string,
	placeVersion: string,
})
	local compositeKey = context.universeId .. ":" .. context.placeId .. ":" .. context.sessionId
	Client.wsSend("plugin_hello", {
		sessionId = context.sessionId,
		projectId = context.projectId,
		placeName = context.placeName,
		universeId = context.universeId,
		placeId = context.placeId,
		placeVersion = context.placeVersion,
		compositeKey = compositeKey,
		pluginVersion = Config.PLUGIN_VERSION,
		protocolVersion = Config.PROTOCOL_VERSION,
	})
end

-- Connect WebSocket to the server
function Client.connectWS()
	if _wsClient then
		Client.disconnectWS()
	end

	if _sessionToken == "" then return end

	-- Build WebSocket URL: ws:// from http://, wss:// from https://
	local wsUrl = string.gsub(_serverUrl, "^http", "ws") .. "/api/ws?token=" .. _sessionToken

	local ok, client = pcall(function()
		return HttpService:CreateWebStreamClient(Enum.WebStreamClientType.WebSocket, {
			Url = wsUrl,
		})
	end)

	if not ok or not client then
		Client.OnError:Fire("Failed to create WebSocket client: " .. tostring(client))
		return
	end

	_wsClient = client

	-- Handle incoming messages
	client.MessageReceived:Connect(function(message: string)
		local decodeOk, data = pcall(HttpService.JSONDecode, HttpService, message)
		if not decodeOk or not data then return end

		local msgType = data.type

		if msgType == "authenticated" then
			Client.OnConnected:Fire()
		elseif msgType == "commands" then
			if data.commands and #data.commands > 0 then
				Client.OnCommandsReceived:Fire(data.commands)
			end
		elseif msgType == "web_edits" then
			if data.edits and #data.edits > 0 then
				Client.OnWebEditsReceived:Fire(data.edits)
			end
		elseif msgType == "sync_ack" then
			Client.OnSyncAck:Fire(data)
			-- Also check for web edits in the sync ack
			if data.webEdits and #data.webEdits > 0 then
				Client.OnWebEditsReceived:Fire(data.webEdits)
			end
		elseif msgType == "error" then
			Client.OnError:Fire(data.message or "Unknown server error")
		elseif msgType == "session_ended" then
			_sessionToken = ""
			_sessionId = ""
			Client.disconnectWS()
		elseif msgType == "datamodel_ack" then
			-- DataModel tree acknowledged by server
		elseif msgType == "pong" then
			-- Keep-alive acknowledged, no action needed
		end
	end)

	-- Handle WebSocket close (server restart, network drop, etc.)
	client.Closed:Connect(function()
		if _wsClient == client then
			_wsClient = nil
			_sessionToken = ""
			_sessionId = ""
			Client.OnDisconnected:Fire()
		end
	end)

	-- Handle WebSocket errors
	client.Error:Connect(function(_statusCode: number, errorMessage: string)
		Client.OnError:Fire("WebSocket error: " .. tostring(errorMessage))
		if _wsClient == client then
			_wsClient = nil
			_sessionToken = ""
			_sessionId = ""
			Client.OnDisconnected:Fire()
		end
	end)
end

-- Disconnect the WebSocket
function Client.disconnectWS()
	local client = _wsClient
	if client then
		_wsClient = nil
		pcall(function()
			client:Close()
		end)
		-- Only fire if we still had a client (avoid double-fire)
		Client.OnDisconnected:Fire()
	end
end

-- ── High-level WebSocket operations ──

-- Push sync data over WebSocket
function Client.wsSyncAll(scripts: { any }, gameObjects: { any })
	Client.wsSend("sync", {
		scripts = scripts,
		gameObjects = gameObjects,
	})
end

-- Report command results over WebSocket
function Client.wsReportResults(results: { any })
	Client.wsSend("command_results", {
		results = results,
	})
end

-- Send DataModel tree over WebSocket for luau-lsp integration
function Client.wsSendDataModel(tree: any)
	Client.wsSend("datamodel", {
		tree = tree,
	})
end

-- Send keep-alive ping over WebSocket
function Client.wsPing()
	Client.wsSend("ping")
end

return Client
