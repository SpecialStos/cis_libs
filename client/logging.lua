-- cis_libs/client/logging.lua

Logging = {}

-- Log levels
Logging.Levels = {
    DEBUG = 1,
    INFO = 2,
    WARN = 3,
    ERROR = 4
}

-- Function to log messages
function Logging.Log(message, level)
    -- Check if Debug Mode is enabled
    if not Config or not Config.Printing or not Config.Printing.Debug then
        return
    end

    level = level or Logging.Levels.INFO
    
    local prefix = "[cis_libs]"

    if level == Logging.Levels.DEBUG then
        prefix = prefix .. " [DEBUG]"
    elseif level == Logging.Levels.INFO then
        prefix = prefix .. " [INFO]"
    elseif level == Logging.Levels.WARN then
        prefix = prefix .. " [WARN]"
    elseif level == Logging.Levels.ERROR then
        prefix = prefix .. " [ERROR]"
    end

    -- Print to console
    print(prefix .. " " .. tostring(message))
end

-- Convenience functions for different log levels
function Logging.Debug(message)
    Logging.Log(message, Logging.Levels.DEBUG)
end

function Logging.Info(message)
    Logging.Log(message, Logging.Levels.INFO)
end

function Logging.Warn(message)
    Logging.Log(message, Logging.Levels.WARN)
end

function Logging.Error(message)
    Logging.Log(message, Logging.Levels.ERROR)
end

-- Function to automatically log errors with stack trace
function Logging.AutoLogError(err, context)
    if not Config or not Config.Printing or not Config.Printing.Debug then
        return
    end

    local stackTrace = debug.traceback(err, 2)
    local errorInfo = {
        context = context or "Unknown",
        stackTrace = stackTrace
    }
    
    local errorMsg = "Automatic Error Log:\nContext: " .. errorInfo.context .. "\nError: " .. tostring(err) .. "\n\nStack Trace:\n" .. errorInfo.stackTrace
    
    Logging.Error(errorMsg)
end

-- Export functions
exports('LogDebug', Logging.Debug)
exports('LogInfo', Logging.Info)
exports('LogWarn', Logging.Warn)
exports('LogError', Logging.Error)
exports('AutoLogError', Logging.AutoLogError)

-- Export the entire Logging table
exports('GetClientLogging', function()
    return Logging
end)

-- Initialize logging system
Citizen.CreateThread(function()
    while Config == nil do
        Citizen.Wait(0)
    end
    
    if Config.Printing and Config.Printing.Debug then
        Logging.Info("Client-side logging system initialized in Debug Mode")
    end
end)