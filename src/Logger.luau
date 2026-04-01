--!strict
-- Studio Bridge Logger
-- Supports log levels: Off(0), Error(1), Warn(2), Info(3), Debug(4), Trace(5)

local Config = require(script.Parent.Config)

local Logger = {}

-- Level constants
Logger.OFF   = 0
Logger.ERROR = 1
Logger.WARN  = 2
Logger.INFO  = 3
Logger.DEBUG = 4
Logger.TRACE = 5

local function shouldLog(level: number): boolean
	return Config.LOG_LEVEL >= level
end

function Logger.trace(tag: string, msg: string)
	if shouldLog(Logger.TRACE) then
		print(string.format("%s [%s] %s", Config.LOG_PREFIX, tag, msg))
	end
end

function Logger.log(tag: string, msg: string)
	if shouldLog(Logger.DEBUG) then
		print(string.format("%s [%s] %s", Config.LOG_PREFIX, tag, msg))
	end
end

function Logger.step(tag: string, step: string)
	if shouldLog(Logger.INFO) then
		print(string.format("%s [%s] ✓ %s", Config.LOG_PREFIX, tag, step))
	end
end

function Logger.info(tag: string, msg: string)
	if shouldLog(Logger.INFO) then
		print(string.format("%s [%s] %s", Config.LOG_PREFIX, tag, msg))
	end
end

function Logger.warn(tag: string, msg: string)
	if shouldLog(Logger.WARN) then
		warn(string.format("%s [%s] %s", Config.LOG_PREFIX, tag, msg))
	end
end

function Logger.error(tag: string, msg: string)
	if shouldLog(Logger.ERROR) then
		warn(string.format("%s [%s] ERROR: %s", Config.LOG_PREFIX, tag, msg))
	end
end

return Logger
