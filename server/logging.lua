-- Console and Discord logging, and the error reporter every other server file funnels
-- its failures through.

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

-- DISCORD IS DEDUPED AND RATE-LIMITED. A webhook is a remote
-- API with its own limit, and a log line repeated every second -- a flood report,
-- a handler raising on every event -- used to be one post per line until Discord
-- answered 429 and dropped the lines that mattered with the rest. Two rules:
--   * the same (channel, text) is forwarded once per DISCORD_DEDUPE_MS; the next
--     copy after that carries how many were folded into it;
--   * a channel forwards at most DISCORD_PER_WINDOW posts per DISCORD_WINDOW_MS.
-- What either rule holds back is counted and said ONCE, on the console, as the
-- window rolls. Both tables are bounded: dedupe keys are pruned on every roll and
-- capped at DISCORD_SEEN_CAP, and a key is the first 512 characters of the text.
local DISCORD_WINDOW_MS = 10000
local DISCORD_PER_WINDOW = 10
local DISCORD_DEDUPE_MS = 60000
local DISCORD_SEEN_CAP = 256
local discordSeen, discordSeenCount = {}, 0
local discordWindow = { started = nil, sent = {}, held = {} }

local function nowMs()
    return type(GetGameTimer) == 'function' and GetGameTimer() or 0
end

local function rollDiscordWindow(now)
    for channel, n in pairs(discordWindow.held) do
        print(('[cis_libs] [WARN] discord: %d %s message(s) held back in the last %ds (deduped or over %d per window)')
            :format(n, channel, DISCORD_WINDOW_MS // 1000, DISCORD_PER_WINDOW))
    end
    discordWindow.started = now
    discordWindow.sent = {}
    discordWindow.held = {}
    for key, seen in pairs(discordSeen) do
        -- A key still holding folded repeats is kept one more dedupe window, so
        -- its next copy can say how many were folded into it.
        local age = now - seen.at
        if age >= 2 * DISCORD_DEDUPE_MS or (age >= DISCORD_DEDUPE_MS and seen.repeats == 0) then
            discordSeen[key] = nil
            discordSeenCount = discordSeenCount - 1
        end
    end
end

--- Whether a Discord post may go out, and the text it goes out with.
--- @return string|nil  the text (with a repeat count folded in), or nil when held back
function Logging.DiscordAdmit(channel, text)
    local now = nowMs()
    if not discordWindow.started or now - discordWindow.started >= DISCORD_WINDOW_MS
        or now < discordWindow.started then
        rollDiscordWindow(now)
    end
    local key = channel .. '\29' .. text:sub(1, 512)
    local seen = discordSeen[key]
    if seen and now - seen.at < DISCORD_DEDUPE_MS then
        seen.repeats = seen.repeats + 1
        discordWindow.held[channel] = (discordWindow.held[channel] or 0) + 1
        return nil
    end
    if (discordWindow.sent[channel] or 0) >= DISCORD_PER_WINDOW then
        discordWindow.held[channel] = (discordWindow.held[channel] or 0) + 1
        return nil
    end
    discordWindow.sent[channel] = (discordWindow.sent[channel] or 0) + 1
    local repeats = seen and seen.repeats or 0
    if seen then
        seen.at, seen.repeats = now, 0
    elseif discordSeenCount < DISCORD_SEEN_CAP then
        discordSeen[key] = { at = now, repeats = 0 }
        discordSeenCount = discordSeenCount + 1
    end
    if repeats > 0 then
        text = ('%s\n\n(repeated %d more time(s) since the last post)'):format(text, repeats)
    end
    return text
end

-- THE CONSOLE IS RATE-LIMITED PER MESSAGE. One client sending a bad payload a
-- frame, or a handler raising on every event, printed one line each time, and
-- a console scrolling thousands of identical lines a second buries every other
-- line and costs a server frame to write. Within each CONSOLE_WINDOW_MS:
--   * the same message (its first CONSOLE_KEY_LEN characters) prints at most
--     CONSOLE_PER_KEY times;
--   * all messages together print at most CONSOLE_PER_WINDOW lines;
--   * at most CONSOLE_KEY_CAP distinct messages are tracked; the rest share one
--     overflow count, so the table cannot grow with the attacker's input.
-- What is held back is never silent: as the window rolls, each held message
-- prints ONE line saying how many copies were suppressed (at most
-- CONSOLE_REPORT_LINES of those, then one line for the rest). Discord is
-- decided separately, below; a held console line can still be forwarded.
local CONSOLE_WINDOW_MS = 10000
local CONSOLE_PER_KEY = 20
local CONSOLE_PER_WINDOW = 500
local CONSOLE_KEY_CAP = 512
local CONSOLE_KEY_LEN = 200
local CONSOLE_REPORT_LINES = 20
local consoleWindow = { started = nil, printed = 0, keys = {}, keyCount = 0, overflow = 0 }

local function rollConsoleWindow(now)
    local reported, rest = 0, consoleWindow.overflow
    for key, entry in pairs(consoleWindow.keys) do
        if entry.held > 0 then
            if reported < CONSOLE_REPORT_LINES then
                reported = reported + 1
                print(('[cis_libs] [WARN] console: %d more cop%s of this line suppressed in the last %ds: %s')
                    :format(entry.held, entry.held == 1 and 'y' or 'ies', CONSOLE_WINDOW_MS // 1000, key))
            else
                rest = rest + entry.held
            end
        end
    end
    if rest > 0 then
        print(('[cis_libs] [WARN] console: %d other line(s) suppressed in the last %ds (over %d per message or %d in all)')
            :format(rest, CONSOLE_WINDOW_MS // 1000, CONSOLE_PER_KEY, CONSOLE_PER_WINDOW))
    end
    consoleWindow.started = now
    consoleWindow.printed = 0
    consoleWindow.keys = {}
    consoleWindow.keyCount = 0
    consoleWindow.overflow = 0
end

--- Whether a console line may print now. A held line is counted, not lost.
--- @return boolean
function Logging.ConsoleAdmit(text)
    local now = nowMs()
    if not consoleWindow.started or now - consoleWindow.started >= CONSOLE_WINDOW_MS
        or now < consoleWindow.started then
        rollConsoleWindow(now)
    end
    local key = tostring(text):sub(1, CONSOLE_KEY_LEN)
    local entry = consoleWindow.keys[key]
    if not entry then
        if consoleWindow.keyCount >= CONSOLE_KEY_CAP then
            consoleWindow.overflow = consoleWindow.overflow + 1
            return false
        end
        entry = { printed = 0, held = 0 }
        consoleWindow.keys[key] = entry
        consoleWindow.keyCount = consoleWindow.keyCount + 1
    end
    if entry.printed >= CONSOLE_PER_KEY or consoleWindow.printed >= CONSOLE_PER_WINDOW then
        entry.held = entry.held + 1
        return false
    end
    entry.printed = entry.printed + 1
    consoleWindow.printed = consoleWindow.printed + 1
    return true
end

local function debugEnabled()
    -- Read per call rather than captured at load, so turning debug on from the console
    return Config and Config.Printing and Config.Printing.Debug
end

-- `discordType` picks a CHANNEL, not a severity -- the severity is `level`.
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

    -- Console output happens BEFORE every Discord check, rate-limited per message.
    if Logging.ConsoleAdmit(tag .. ' ' .. tostring(message)) then
        print(('%s[cis_libs] [%s] %s%s'):format(color, tag, tostring(message), Colors.reset))
    end

    if not (Config and Config.Printing and Config.Printing.UseDiscordLogs) then
        return
    end
    -- The outbound sink is a CAPABILITY, not a global.
    if not CisRegistry.has('discord') then
        return
    end

    local discordColor = 'lightblue'
    if level == Logging.Levels.ERROR then
        discordColor = 'red'
    elseif level == Logging.Levels.WARN then
        discordColor = 'yellow'
    end

    -- The expansion is Discord-only.
    local discordMessage = tostring(message)
    if errorInfo then
        discordMessage = discordMessage .. '\n\nError Details:\nFile: ' .. tostring(errorInfo.file)
            .. '\nLine: ' .. tostring(errorInfo.line)
            .. '\nEvent: ' .. tostring(errorInfo.event or 'N/A')
            .. '\n\nStack Trace:\n' .. tostring(errorInfo.stackTrace)
    end

    local channel = (discordType == 'cheating' or discordType == 'error') and discordType or 'master'
    discordMessage = Logging.DiscordAdmit(channel, discordMessage)
    if not discordMessage then
        return
    end

    local prefix = '[cis_libs] [' .. tag .. ']'
    local links = DiscordConfig and DiscordConfig.DiscordLogsLinks or {}
    if discordType == 'cheating' then
        CisRegistry.call('discord', 'log', links.CheatingLogs, prefix, discordMessage, 'red', true)
    elseif discordType == 'error' then
        -- Falls back to the master channel when ErrorLogs is unset, so a config with no
        CisRegistry.call('discord', 'log', links.ErrorLogs or links.MasterLogs, prefix, discordMessage, 'red', true)
    else
        CisRegistry.call('discord', 'log', links.MasterLogs, prefix, discordMessage, discordColor, false)
    end
end

-- Thin wrappers, so the numeric Levels do not leak into every call site and a new level
function Logging.Debug(message, discordType)
    Logging.Log(message, Logging.Levels.DEBUG, discordType)
end

function Logging.Info(message, discordType)
    Logging.Log(message, Logging.Levels.INFO, discordType)
end

function Logging.Warn(message, discordType)
    -- Counted at the ENTRY POINT, not inside Log(), because a caller that raises inside
    CisDiagnostics.Inc(CisDiagnostics.NAMES.WARNINGS)
    Logging.Log(message, Logging.Levels.WARN, discordType)
end

function Logging.Error(message, discordType, errorInfo)
    CisDiagnostics.Inc(CisDiagnostics.NAMES.ERRORS)
    Logging.Log(message, Logging.Levels.ERROR, discordType, errorInfo)
end

-- A trapped error: the message, plus where it happened, captured while the failing
-- frame was still on the stack. tostring() gives the message, so a caller that only
-- wants text cannot tell the difference.
local Trapped = {}
Trapped.__index = Trapped
Trapped.__tostring = function(self)
    return tostring(self.err)
end

--- xpcall's message handler. `pcall` unwinds the stack BEFORE anyone can look at it,
--- so a reporter that reads debug.getinfo afterwards names its own caller -- every
--- error in every consumer handler was filed under server/security.lua. This runs
--- at the raise, so the file, the line and the trace are the failure's.
--- @param err any
--- @return table  a trapped error; tostring() of it is the original message
function Logging.Trap(err)
    if getmetatable(err) == Trapped then
        return err
    end
    -- Level 2 is the raiser. `error()` itself is a native frame with no line, so
    -- step past those to the first frame that HAS a line: the one a developer has
    -- to go and read.
    local info
    for level = 2, 12 do
        info = debug.getinfo(level, 'Sl')
        if not info or (info.currentline or -1) > 0 then
            break
        end
    end
    return setmetatable({
        err = err,
        file = info and info.short_src,
        line = info and info.currentline,
        trace = debug.traceback(tostring(err), 2),
    }, Trapped)
end

-- Every handler cis_libs dispatches is run under xpcall(fn, Logging.Trap) and ends here.
-- An untrapped error still logs, with the reporter's caller as its best guess.
function Logging.AutoLogError(err, event)
    local info, trace
    if getmetatable(err) == Trapped then
        info = { short_src = err.file, currentline = err.line }
        trace = err.trace
    else
        info = debug.getinfo(2, 'Sl') or {}
        trace = debug.traceback(tostring(err), 2)
    end
    Logging.Error('Automatic Error Log:\n' .. tostring(err), 'error', {
        file = info.short_src,
        line = info.currentline,
        event = event,
        stackTrace = trace,
        -- Recorded because the same handler behaves differently on different
        framework = Config and Config.Framework and Config.Framework.Type or 'NONE',
    })
end

-- String levels, not the numeric ones.
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

-- The function VALUES, not wrappers.
exports('LogDebug', Logging.Debug)
exports('LogInfo', Logging.Info)
exports('LogWarn', Logging.Warn)
exports('LogError', Logging.Error)
exports('AutoLogError', Logging.AutoLogError)
exports('GetLogging', function()
    return Logging
end)
