-- Duration formatting and parsing, and relative "3 minutes ago" text.

local M = {
    SECOND = 1,
    MINUTE = 60,
    HOUR = 3600,
    DAY = 86400,
    WEEK = 604800,
    -- Milliseconds, for the frame budgets and rate-limit windows the rest of the
    MS = 1 / 1000,
}

-- Largest unit first, so formatDuration and parseDuration agree on which letter means
local UNITS = {
    { key = 'week', field = 'weeks', symbol = 'w', seconds = 604800 },
    { key = 'day', field = 'days', symbol = 'd', seconds = 86400 },
    { key = 'hour', field = 'hours', symbol = 'h', seconds = 3600 },
    { key = 'minute', field = 'minutes', symbol = 'm', seconds = 60 },
    { key = 'second', field = 'seconds', symbol = 's', seconds = 1 },
}

local SYMBOL_SECONDS = {
    w = 604800, wk = 604800, week = 604800, weeks = 604800,
    d = 86400, day = 86400, days = 86400,
    h = 3600, hr = 3600, hrs = 3600, hour = 3600, hours = 3600,
    m = 60, min = 60, mins = 60, minute = 60, minutes = 60,
    s = 1, sec = 1, secs = 1, second = 1, seconds = 1,
}

--- Read the clock from an INJECTED source.
--- @param clock function returning a number of seconds, or nil.
--- @return the number, or `nil, reason`.
function M.now(clock)
    if type(clock) ~= 'function' then
        return nil, 'no clock was injected; pass clock() returning seconds'
    end
    local ok, value = pcall(clock)
    if not ok then
        return nil, ('the injected clock raised: %s'):format(tostring(value))
    end
    if type(value) ~= 'number' then
        return nil, ('the injected clock returned %s, not a number'):format(type(value))
    end
    return value
end

--- Break a duration into { weeks, days, hours, minutes, seconds }.
--- @param seconds
--- @return table  { weeks, days, hours, minutes, seconds, fractional, negative }. A non-number, NaN or infinity is 0 rather than an error.
function M.parts(seconds)
    local negative = false
    -- Strict about the type, unlike a `tonumber(seconds) or 0`.
    local value = (type(seconds) == 'number' and seconds) or 0
    if value ~= value or value == math.huge or value == -math.huge then
        value = 0
    end
    if value < 0 then
        negative = true
        value = -value
    end
    local whole = math.floor(value)
    local fractional = value - whole
    local remaining = whole
    local out = {
        weeks = 0, days = 0, hours = 0, minutes = 0, seconds = 0,
        fractional = fractional, negative = negative,
    }
    for i = 1, #UNITS do
        local u = UNITS[i]
        local n = math.floor(remaining / u.seconds)
        out[u.field] = n
        remaining = remaining - n * u.seconds
    end
    return out
end

--- Format a duration as "2h 14m".
--- @param seconds
--- @param opts
--- @return a string. A non-numeric input is '0s', not an error: this is a
function M.formatDuration(seconds, opts)
    opts = opts or {}
    local sep = opts.sep or ' '
    if type(seconds) ~= 'number' or seconds ~= seconds
        or seconds == math.huge or seconds == -math.huge then
        return '0s'
    end
    local sign = ''
    local value = seconds
    if value < 0 then
        sign = '-'
        value = -value
    end
    local pieces = {}
    if value < 1 then
        if opts.ms then
            local ms = math.floor(value * 1000 + 0.5)
            if ms <= 0 then
                return sign .. '0ms'
            end
            return ('%s%dms'):format(sign, ms)
        end
        return sign .. '0s'
    end

    local remaining = math.floor(value)
    local shown = 0
    local max = opts.max or 2
    for i = 1, #UNITS do
        local u = UNITS[i]
        local n = math.floor(remaining / u.seconds)
        if n > 0 then
            remaining = remaining - n * u.seconds
            shown = shown + 1
            pieces[#pieces + 1] = ('%d%s'):format(n, u.symbol)
            if shown >= max then
                break
            end
        end
    end
    if #pieces == 0 then
        return '0s'
    end
    return sign .. table.concat(pieces, sep)
end

--- Parse a human duration back into seconds.
--- @param text
--- @return the number of seconds, or `nil, reason` naming the offending piece.
function M.parseDuration(text)
    if type(text) == 'number' then
        if text ~= text or text == math.huge or text == -math.huge then
            return nil, 'duration must be a finite number'
        end
        return text
    end
    if type(text) ~= 'string' then
        return nil, ('duration must be a string, got %s'):format(type(text))
    end
    local s = text:gsub('^%s+', ''):gsub('%s+$', ''):lower()
    if s == '' then
        return nil, 'duration is empty'
    end
    local sign = 1
    if s:sub(1, 1) == '-' then
        sign = -1
        s = s:sub(2)
    elseif s:sub(1, 1) == '+' then
        s = s:sub(2)
    end
    if s == '' then
        return nil, 'duration has a sign and no number'
    end
    local total = 0
    local matched = false
    -- A number, then optional whitespace, then letters.
    for num, _, unit in s:gmatch('([%d%.]+)(%s*)([%a]+)') do
        local value = tonumber(num)
        if value == nil then
            return nil, ('%q is not a number'):format(num)
        end
        local size = SYMBOL_SECONDS[unit]
        if size == nil then
            return nil, ('%q is not a known unit (w d h m s, or a long name)'):format(unit)
        end
        total = total + value * size
        matched = true
    end
    if not matched then
        -- No unit at all: a bare number, in seconds.
        local value = tonumber(s)
        if value == nil then
            return nil, ('%q is not a duration'):format(text)
        end
        return sign * value
    end
    -- Everything must have been consumed.
    local leftover = s:gsub('([%d%.]+)(%s*)([%a]+)', '')
    leftover = leftover:gsub('%s+', '')
    if leftover ~= '' then
        return nil, ('trailing %q could not be understood'):format(leftover)
    end
    return sign * total
end

--- Relative time in words: '3 minutes ago', 'in 3 minutes', 'just now'.
--- @param timestamp
--- @param now
--- @param opts
--- @return a string. nil in gives 'unknown', because "this thing has no
function M.relative(timestamp, now, opts)
    if type(timestamp) ~= 'number' or timestamp ~= timestamp then
        return 'unknown'
    end
    if type(now) ~= 'number' or now ~= now then
        return 'unknown'
    end
    opts = opts or {}
    local within = opts.within or 5
    local delta = now - timestamp
    local future = false
    if delta < 0 then
        delta = -delta
        future = true
    end
    if delta < within then
        return opts.justNow or 'just now'
    end
    local magnitude = delta
    local piece
    if magnitude >= M.WEEK then
        local n = math.floor(magnitude / M.WEEK)
        piece = ('%d %s'):format(n, n == 1 and 'week' or 'weeks')
    elseif magnitude >= M.DAY then
        local n = math.floor(magnitude / M.DAY)
        piece = ('%d %s'):format(n, n == 1 and 'day' or 'days')
    elseif magnitude >= M.HOUR then
        local n = math.floor(magnitude / M.HOUR)
        piece = ('%d %s'):format(n, n == 1 and 'hour' or 'hours')
    elseif magnitude >= M.MINUTE then
        local n = math.floor(magnitude / M.MINUTE)
        piece = ('%d %s'):format(n, n == 1 and 'minute' or 'minutes')
    else
        local n = math.floor(magnitude)
        piece = ('%d %s'):format(n, n == 1 and 'second' or 'seconds')
    end
    if future then
        if opts.future == false then
            return ('after %s'):format(piece)
        end
        if type(opts.future) == 'string' then
            return opts.future:format(piece)
        end
        return ('in %s'):format(piece)
    end
    if type(opts.past) == 'string' then
        return opts.past:format(piece)
    end
    return ('%s ago'):format(piece)
end

--- Seconds elapsed between two instants: `now - since`.
--- @param now
--- @param since
--- @return a number, or 0 when either argument is not a number. Compare the
function M.elapsed(now, since)
    if type(now) ~= 'number' or type(since) ~= 'number' then
        return 0
    end
    return now - since
end

--- Round a duration in SECONDS to a whole number of `unit`s, to the NEAREST, and return
--- @param seconds
--- @param unit
--- @return SECONDS, rounded to a whole multiple of `unit`. Ties go UP (30s to a
function M.roundTo(seconds, unit)
    if type(seconds) ~= 'number' or seconds ~= seconds then
        return 0
    end
    if unit == nil then
        unit = M.MINUTE
    end
    if type(unit) ~= 'number' or unit <= 0 then
        return 0
    end
    return math.floor(seconds / unit + 0.5) * unit
end

-- A MODULE, NOT A GLOBAL.
if ... ~= 'cis_require' then
    CisTime = M
end

return M
