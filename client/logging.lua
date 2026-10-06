-- Client logging. The `Logging` global is shared state and must exist once
-- once -- a second copy means the level tables can disagree
-- between modules in the same resource.

Logging = {
    Levels = {
        DEBUG = 1,
        INFO = 2,
        WARN = 3,
        ERROR = 4,
    },
}

local function debugEnabled()
    return Config and Config.Printing and Config.Printing.Debug
end

function Logging.Log(message, level)
    level = level or Logging.Levels.INFO
    -- Only DEBUG is gated. Errors and warnings must always reach the console,
    -- otherwise the pcall wrappers below hide real failures in production.
    if level == Logging.Levels.DEBUG and not debugEnabled() then
        return
    end
    local tag = 'INFO'
    if level == Logging.Levels.DEBUG then
        tag = 'DEBUG'
    elseif level == Logging.Levels.WARN then
        tag = 'WARN'
    elseif level == Logging.Levels.ERROR then
        tag = 'ERROR'
    end
    print(('[cis_libs] [%s] %s'):format(tag, tostring(message)))
end

function Logging.Debug(message)
    Logging.Log(message, Logging.Levels.DEBUG)
end

function Logging.Info(message)
    Logging.Log(message, Logging.Levels.INFO)
end

function Logging.Warn(message)
    CisDiagnostics.Inc(CisDiagnostics.NAMES.WARNINGS)
    Logging.Log(message, Logging.Levels.WARN)
end

function Logging.Error(message)
    CisDiagnostics.Inc(CisDiagnostics.NAMES.ERRORS)
    Logging.Log(message, Logging.Levels.ERROR)
end

-- A traceback is attached to every auto-logged error, because the only other
-- place it exists is a console nobody will be reading when a pcall catches
-- something at 3am.
function Logging.AutoLogError(err, context)
    Logging.Error(('Automatic Error Log:\nContext: %s\nError: %s\n%s'):format(
        context or 'Unknown',
        tostring(err),
        debug.traceback(err, 2)
    ))
end

function CisLog(level, message)
    if level == 'error' then
        Logging.Error(message)
    elseif level == 'warn' then
        Logging.Warn(message)
    elseif level == 'debug' then
        Logging.Debug(message)
    else
        Logging.Info(message)
    end
end

exports('LogDebug', Logging.Debug)
exports('LogInfo', Logging.Info)
exports('LogWarn', Logging.Warn)
exports('LogError', Logging.Error)
exports('AutoLogError', Logging.AutoLogError)
exports('GetClientLogging', function()
    return Logging
end)
