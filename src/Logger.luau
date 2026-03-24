--!strict
-- Studio Bridge Logger

local Config = require(script.Parent.Config)

local Logger = {}

function Logger.log(tag: string, msg: string)
	if Config.DEBUG then
		print(string.format("%s [%s] %s", Config.LOG_PREFIX, tag, msg))
	end
end

function Logger.step(tag: string, step: string)
	if Config.DEBUG then
		print(string.format("%s [%s] ✓ %s", Config.LOG_PREFIX, tag, step))
	end
end

function Logger.warn(tag: string, msg: string)
	if Config.DEBUG then
		warn(string.format("%s [%s] %s", Config.LOG_PREFIX, tag, msg))
	end
end

function Logger.error(tag: string, msg: string)
	warn(string.format("%s [%s] ERROR: %s", Config.LOG_PREFIX, tag, msg))
end

return Logger
