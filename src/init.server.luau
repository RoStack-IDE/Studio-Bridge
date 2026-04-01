--!strict
-- Studio Bridge Plugin Entry Point (Headless)
-- Automatically discovers and connects to the server IDE.

local RunService = game:GetService("RunService")

-- Don't run during playtesting — only in Edit mode
if RunService:IsRunning() then
	return
end

local Config = require(script.Config)
local Logger = require(script.Logger)

if not plugin then
	warn(Config.LOG_PREFIX .. " Not running in Studio context — aborting.")
	return
end

local HttpService = game:GetService("HttpService")
local APIClient = require(script.API.Client)
local Sync      = require(script.Features.Sync)

Logger.step("Init", Config.PLUGIN_NAME .. " v" .. Config.PLUGIN_VERSION .. " (headless) loading...")
APIClient.init(Config.SERVER_URL)

-- Generate ephemeral session UUID at plugin startup
local _ephemeralSessionId = HttpService:GenerateGUID(false)

-- ── Persistent project ID via Workspace attribute ──
-- This ID is saved with the place file and uniquely links it to its
-- RoStack session, chat history, etc. — no reliance on PlaceId/GameId.
local ATTR_NAME = "RoStackProjectId"

local function getOrCreateProjectId(): string
	local existing = game.Workspace:GetAttribute(ATTR_NAME)
	if typeof(existing) == "string" and #existing > 0 then
		Logger.step("Init", "Existing project ID: " .. existing)
		return existing
	end
	local newId = HttpService:GenerateGUID(false)
	local setOk, setErr = pcall(function()
		game.Workspace:SetAttribute(ATTR_NAME, newId)
	end)
	if setOk then
		-- Verify it was actually saved
		local verify = game.Workspace:GetAttribute(ATTR_NAME)
		Logger.step("Init", "Generated new project ID: " .. newId .. " (verified=" .. tostring(verify == newId) .. ")")
	else
		Logger.error("Init", "Failed to set project ID attribute: " .. tostring(setErr))
	end
	return newId
end

local _projectId = getOrCreateProjectId()

-- ── Auto-discover and connect loop ──
-- Polls the server's /api/discover endpoint to find a session.
-- Once found, claims it and starts auto-sync. On disconnect, loops back.

local _running = true

plugin.Unloading:Connect(function()
	Logger.log("Init", "Plugin unloading...")
	_running = false
	Sync.stopAutoSync()

	-- Finish any in-progress ChangeHistoryService recording to prevent orphans
	Sync.finishActiveRecording()

	APIClient.disconnect()
end)

task.spawn(function()
	while _running do
		-- Only try to discover if not already connected
		if not APIClient.isConnected() then
			Logger.log("Init", "Searching for server session...")

			local ok, err = pcall(function()
				local data = APIClient.discover():expect()
				if data.success then
					Logger.step("Init", "Session found! ID=" .. tostring(data.sessionId))

					local gameContext = {
						sessionId = _ephemeralSessionId,
						projectId = _projectId,
						placeName = game.Name or "Untitled",
						universeId = tostring(game.GameId),
						placeId = tostring(game.PlaceId),
						placeVersion = tostring(game.PlaceVersion),
					}
					Logger.step("Init", "Game context: projectId=" .. _projectId .. " universe=" .. gameContext.universeId .. " place=" .. gameContext.placeId)

					-- Start auto-sync (handles WebSocket, commands, edits, output)
					Sync.startAutoSync(function(status: string, msg: string)
						if status == "error" then
							Logger.error("Sync", "Sync error: " .. msg)
						end
					end, function()
						-- On disconnect callback — will loop back to discover
						Logger.step("Init", "Disconnected from IDE, will retry...")
					end, gameContext)
				end
			end)

			if not ok then
				-- Server not reachable or no session available — that's fine, retry
				Logger.log("Init", "No server session found, retrying in " .. Config.DISCOVER_INTERVAL .. "s")
			end
		end

		task.wait(Config.DISCOVER_INTERVAL)
	end
end)

Logger.step("Init", Config.PLUGIN_NAME .. " v" .. Config.PLUGIN_VERSION .. " (headless) loaded ✓")
