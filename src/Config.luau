--!strict
-- Studio Bridge Plugin Configuration

local Config = {
	DEBUG                = true,
	SERVER_URL           = "http://localhost:34872",
	AUTO_SYNC_INTERVAL   = 1,
	FALLBACK_SYNC_INTERVAL = 15,  -- seconds between full fallback scans (event-driven handles real-time)
	PLUGIN_VERSION       = "0.3.1",
	DISCOVER_INTERVAL    = 5,     -- seconds between auto-discover attempts
	RECONNECT_DELAY      = 5,     -- seconds before reconnect after disconnect
	LOG_PREFIX           = "[Plugin]",
	PLUGIN_NAME          = "StudioBridge",
}

return Config
