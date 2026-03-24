# Contributing to Studio Bridge Plugin

Thanks for your interest in contributing! This plugin is a generic connection layer between Roblox Studio and external servers.

## Adding Custom Command Handlers

The plugin uses a handler registry pattern. You can register new commands without modifying the core `CommandExecutor.luau`:

```luau
local CommandExecutor = require(script.Parent.Features.CommandExecutor)

-- Register a custom command
CommandExecutor.registerHandler("myCommand", function(params)
    local target = params.target :: string
    -- Do something in Studio...
    return { success = true, message = "Done" }
end)
```

Handlers receive a `params` table and should return a result table. Errors can be raised with `error()` and will be caught and reported automatically.

### Handler Guidelines

- Use `withRecording()` (via ChangeHistoryService) for any operation that modifies the game tree, so users can undo it
- Return descriptive result tables so the server knows what happened
- Use `resolveInstance(path)` to find instances by their dot-separated or slash-separated path
- Use `DataTypeSerializer` for serializing/deserializing Roblox data types

## Project Setup

1. Install [Wally](https://wally.run): `cargo install wally-cli`
2. Install dependencies: `wally install`
3. Build: `rojo build -o StudioBridge.rbxmx`
4. Copy to your Roblox Studio plugins folder

## Code Style

- Use `--!strict` type checking
- Use the `Logger` module for all output (not raw `print`/`warn`)
- Keep command handlers self-contained
- Use `Config` module values instead of hardcoded strings
