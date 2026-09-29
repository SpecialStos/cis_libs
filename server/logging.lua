Logging = {
    Levels = {
        DEBUG = 1,
        INFO = 2,
        WARN = 3,
        ERROR = 4,
    },
}

local Colors = {
    reset = '^0',
    red = '^1',
    green = '^2',
    yellow = '^3',
    cyan = '^5',
    white = '^7',
}

local function debugEnabled()
    return Config and Config.Printing and Config.Printing.Debug
end

function Logging.Log(message, level, discordType, errorInfo)
    level = level or Logging.Levels.INFO
    if level == Logging.Levels.DEBUG and not debugEnabled() then
        return
    end

    local tag = 'INFO'
    local color = Colors.white
    if level == Logging.Levels.DEBUG then
        tag, color = 'DEBUG', Colors.cyan
    elseif level == Logging.Levels.WARN then
        tag, color = 'WARN', Colors.yellow
    elseif level == Logging.Levels.ERROR then
        tag, color = 'ERROR', Colors.red
    elseif level == Logging.Levels.INFO then
        color = Colors.green
    end

    print(('%s[cis_libs] [%s] %s%s'):format(color, tag, tostring(message), Colors.reset))

    if not (Config and Config.Printing and Config.Printing.UseDiscordLogs) then
        return
    end
    if not DiscordQueue then
        return
    end

    local discordColor = 'lightblue'
    if level == Logging.Levels.ERROR then
        discordColor = 'red'
    elseif level == Logging.Levels.WARN then
        discordColor = 'yellow'
    end

    local discordMessage = tostring(message)
    if errorInfo then
        discordMessage = discordMessage .. '\n\nError Details:\nFile: ' .. tostring(errorInfo.file)
            .. '\nLine: ' .. tostring(errorInfo.line)
            .. '\nEvent: ' .. tostring(errorInfo.event or 'N/A')
            .. '\n\nStack Trace:\n' .. tostring(errorInfo.stackTrace)
    end

    local prefix = '[cis_libs] [' .. tag .. ']'
    local links = DiscordConfig and DiscordConfig.DiscordLogsLinks or {}
    if discordType == 'cheating' then
        DiscordQueue.push(links.CheatingLogs, prefix, discordMessage, 'red', true)
    elseif discordType == 'error' then
        DiscordQueue.push(links.ErrorLogs or links.MasterLogs, prefix, discordMessage, 'red', true)
    else
        DiscordQueue.push(links.MasterLogs, prefix, discordMessage, discordColor, false)
    end
end

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
    local info = debug.getinfo(2, 'Sl') or {}
    Logging.Error('Automatic Error Log:\n' .. tostring(err), 'error', {
        file = info.short_src,
        line = info.currentline,
        event = event,
        stackTrace = debug.traceback(err, 2),
        framework = Config and Config.Framework and Config.Framework.Type or 'NONE',
    })
end

function CisLog(level, message, discordType)
    if level == 'error' then
        Logging.Error(message, discordType)
    elseif level == 'warn' then
        Logging.Warn(message, discordType)
    elseif level == 'debug' then
        Logging.Debug(message, discordType)
    else
        Logging.Info(message, discordType)
    end
end

exports('LogDebug', Logging.Debug)
exports('LogInfo', Logging.Info)
exports('LogWarn', Logging.Warn)
exports('LogError', Logging.Error)
exports('AutoLogError', Logging.AutoLogError)
exports('GetLogging', function()
    return Logging
end)
