# Studio Bridge Plugin

A generic Roblox Studio plugin that bridges Studio with any external server over HTTP and WebSocket. It provides real-time synchronization of the game tree, script editing, command execution, and output forwarding.

## Features

- Auto-discovers and connects to a local server via `/api/discover`
- Bidirectional WebSocket communication (sync, commands, edits, output)
- Full game tree scanning and real-time change detection
- Script editing via ScriptEditorService (live buffer updates)
- 40+ built-in command handlers (instances, scripts, terrain, lighting, CSG, etc.)
- Extensible command system via `CommandExecutor.registerHandler()`
- DataModel tree encoding for luau-lsp integration
- Output and error forwarding with batching
- Configurable branding, server URL, and intervals via `Config.luau`

## Configuration

All settings are in `src/Config.luau`:

| Field | Default | Description |
|-------|---------|-------------|
| `SERVER_URL` | `http://localhost:34872` | Server endpoint |
| `PLUGIN_NAME` | `StudioBridge` | Display name in logs and UI |
| `LOG_PREFIX` | `[Plugin]` | Prefix for log messages |
| `PLUGIN_VERSION` | `0.3.0` | Version string |
| `AUTO_SYNC_INTERVAL` | `1` | Seconds between sync cycles |
| `DISCOVER_INTERVAL` | `5` | Seconds between discover attempts |
| `RECONNECT_DELAY` | `5` | Seconds before reconnect |
| `DEBUG` | `true` | Enable debug logging |

## Building

### With Rojo

```bash
rojo build -o StudioBridge.rbxmx
```

### Manual Installation

1. Install [Wally](https://wally.run) dependencies: `wally install`
2. Build with Rojo or your preferred toolchain
3. Copy the `.rbxmx` to `~/Documents/Roblox/Plugins/` (macOS) or `%LOCALAPPDATA%\Roblox\Plugins\` (Windows)

## Project Structure

```
src/
├── init.server.luau          # Entry point — auto-discover loop
├── Config.luau               # All configuration defaults
├── Logger.luau               # Logging with configurable prefix
├── API/
│   └── Client.luau           # HTTP + WebSocket client
├── Features/
│   ├── Sync.luau             # Game tree sync, output forwarding
│   ├── CommandExecutor.luau  # Command dispatch + handler registry
│   └── DataTypeSerializer.luau  # Roblox datatype serialization
└── Packages/                 # Wally dependencies (Promise, Signal)
```

## Adding Custom Commands

Use the registration API to add your own command handlers:

```luau
local CommandExecutor = require(path.to.CommandExecutor)

CommandExecutor.registerHandler("myCustomCommand", function(params)
    -- Your logic here
    return { success = true, data = "result" }
end)
```

See [CONTRIBUTING.md](CONTRIBUTING.md) for more details.

## License

MIT — see [LICENSE](LICENSE).
