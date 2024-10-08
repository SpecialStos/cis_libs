-- cis_libs/server/logging.lua

Logging = {}

-- Define color codes for console output
local Colors = {
    reset = "^0",
    red = "^1",
    green = "^2",
    yellow = "^3",
    blue = "^4",
    cyan = "^5",
    magenta = "^6",
    white = "^7"
}

-- Log levels
Logging.Levels = {
    DEBUG = 1,
    INFO = 2,
    WARN = 3,
    ERROR = 4
}

-- Function to log messages
function Logging.Log(message, level, discordType, errorInfo)
    level = level or Logging.Levels.INFO
    
    if level == Logging.Levels.DEBUG and not Config.Printing.Debug then
        return
    end

    local prefix = "[cis_libs]"
    local color = Colors.white

    if level == Logging.Levels.DEBUG then
        prefix = prefix .. " [DEBUG]"
        color = Colors.cyan
    elseif level == Logging.Levels.INFO then
        prefix = prefix .. " [INFO]"
        color = Colors.green
    elseif level == Logging.Levels.WARN then
        prefix = prefix .. " [WARN]"
        color = Colors.yellow
    elseif level == Logging.Levels.ERROR then
        prefix = prefix .. " [ERROR]"
        color = Colors.red
    end

    -- Print to console
    print(color .. prefix .. " " .. tostring(message) .. Colors.reset)

    -- Log to Discord if enabled
    if Config.Printing.UseDiscordLogs then
        local discordColor = 'lightblue'
        if level == Logging.Levels.ERROR then
            discordColor = 'red'
        elseif level == Logging.Levels.WARN then
            discordColor = 'yellow'
        end

        local discordMessage = tostring(message)
        if errorInfo then
            discordMessage = discordMessage .. "\n\nError Details:\n" ..
                             "File: " .. errorInfo.file .. "\n" ..
                             "Line: " .. errorInfo.line .. "\n" ..
                             "Event: " .. (errorInfo.event or "N/A") .. "\n\n" ..
                             "Stack Trace:\n" .. errorInfo.stackTrace
        end

        if discordType == "master" or discordType == nil then
            exports['cis_libs']:SendDiscordLog(Discord.DiscordLogsLinks.MasterLogs, prefix, discordMessage, discordColor, false)
        elseif discordType == "cheating" then
            exports['cis_libs']:SendDiscordLog(Discord.DiscordLogsLinks.CheatingLogs, prefix, discordMessage, 'red', true)
        elseif discordType == "error" then
            exports['cis_libs']:SendDiscordLog(Discord.DiscordLogsLinks.ErrorLogs, prefix, discordMessage, 'red', true)
        end
    end
end

-- Convenience functions for different log levels
function Logging.Debug(message, discordType)
    Logging.Log(message, Logging.Levels.DEBUG, discordType)
end

function Logging.Info(message, discordType)
    Logging.Log(message, Logging.Levels.INFO, discordType)
end

function Logging.Warn(message, discordType)
    Logging.Log(message, Logging.Levels.WARN, discordType)
end

function Logging.Error(message, discordType, errorInfo)
    Logging.Log(message, Logging.Levels.ERROR, discordType, errorInfo)
end

function Logging.AutoLogError(err, event)
    local stackTrace = debug.traceback(err, 2)
    local errorInfo = {
        file = debug.getinfo(2, "S").short_src,
        line = debug.getinfo(2, "l").currentline,
        event = event,
        stackTrace = stackTrace,
        framework = Config.Framework.Type or "No Framework"  -- Add this line
    }
    
    local errorMsg = "Automatic Error Log:\n" .. tostring(err)
    
    Logging.Error(errorMsg, "error", errorInfo)
end

-- Export functions
exports('LogDebug', Logging.Debug)
exports('LogInfo', Logging.Info)
exports('LogWarn', Logging.Warn)
exports('LogError', Logging.Error)
exports('AutoLogError', Logging.AutoLogError)

-- Export the entire Logging table
exports('GetLogging', function()
    return Logging
end)