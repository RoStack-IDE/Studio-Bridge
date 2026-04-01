--!strict
-- Studio Bridge Plugin Configuration

local Config = {
	DEBUG                = true,
	SERVER_URL           = "http://localhost:34872",
	AUTO_SYNC_INTERVAL   = 1,
	FALLBACK_SYNC_INTERVAL = 15,  -- seconds between full fallback scans (event-driven handles real-time)
	PLUGIN_VERSION       = "0.3.2",
	PROTOCOL_VERSION     = 1,     -- Increment when wire format changes incompatibly
	DISCOVER_INTERVAL    = 5,     -- seconds between auto-discover attempts
	RECONNECT_DELAY      = 5,     -- seconds before reconnect after disconnect
	LOG_PREFIX           = "[Plugin]",
	PLUGIN_NAME          = "StudioBridge",

	-- Log levels: 0=Off, 1=Error, 2=Warn, 3=Info, 4=Debug, 5=Trace
	LOG_LEVEL            = 4,

	-- HTTP request timeout in seconds (0 = no timeout)
	HTTP_TIMEOUT         = 45,

	-- Maximum results for glob/grep searches
	MAX_SEARCH_RESULTS   = 200,

	-- runTests max simulation timeout in seconds
	MAX_TEST_TIMEOUT     = 30,
}

return Config
