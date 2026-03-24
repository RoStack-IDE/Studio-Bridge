--!strict
-- Studio Bridge Plugin Entry Point (Headless)
-- Automatically discovers and connects to the server IDE.

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

-- ── Auto-discover and connect loop ──
-- Polls the server's /api/discover endpoint to find a session.
-- Once found, claims it and starts auto-sync. On disconnect, loops back.

local _running = true

plugin.Unloading:Connect(function()
	Logger.log("Init", "Plugin unloading...")
	_running = false
	Sync.stopAutoSync()
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

					-- Build composite session context from game metadata
					-- IDs may be 0 initially (Studio loads them async) — we'll re-send
					-- plugin_hello once they become available
					local gameContext = {
						sessionId = _ephemeralSessionId,
						universeId = tostring(game.GameId),
						placeId = tostring(game.PlaceId),
						placeVersion = tostring(game.PlaceVersion),
					}
					Logger.step("Init", "Game context: universe=" .. gameContext.universeId .. " place=" .. gameContext.placeId .. " v" .. gameContext.placeVersion)

					-- Start auto-sync (handles WebSocket, commands, edits, output)
					Sync.startAutoSync(function(status: string, msg: string)
						if status == "error" then
							Logger.error("Sync", "Sync error: " .. msg)
						end
					end, function()
						-- On disconnect callback — will loop back to discover
						Logger.step("Init", "Disconnected from IDE, will retry...")
					end, gameContext)

					-- Watch for game IDs to become available and re-send hello
					-- This handles both slow PCs and places opened after Studio loads
					if game.GameId == 0 or game.PlaceId == 0 then
						task.spawn(function()
							while _running and APIClient.isConnected() do
								task.wait(2)
								if game.GameId ~= 0 or game.PlaceId ~= 0 then
									local updatedContext = {
										sessionId = _ephemeralSessionId,
										universeId = tostring(game.GameId),
										placeId = tostring(game.PlaceId),
										placeVersion = tostring(game.PlaceVersion),
									}
									Logger.step("Init", "Game IDs now available — re-sending hello: universe=" .. updatedContext.universeId .. " place=" .. updatedContext.placeId)
									APIClient.wsSendHello(updatedContext)
									break
								end
							end
						end)
					end
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
