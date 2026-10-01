-- Duration formatting and parsing, and relative "3 minutes ago" text.
--
-- PURE, no natives, no module state, no dependencies. Safe to `shared_script`
-- for a private copy (COMPATIBILITY.md §10.2).
--
-- NOTHING HERE READS A CLOCK. There is no os.time() call anywhere in this file,
-- and that is the single most important property of it: `relative` takes the
-- reference instant as an ARGUMENT, so "3 minutes ago" is a function you can
-- assert on under fengari with no server and no sleeping. The alternative --
-- reading the clock inside the formatter -- makes every one of these untestable
-- and turns a typo in a duration parser into something you find out about from
-- a player's screenshot.
--
-- UNITS ARE SECONDS everywhere on the public surface. A millisecond constant is
-- available (CisTime.MS) because that is what a FiveM frame budget is written
-- in, but every function that takes or returns a duration names its unit in the
-- parameter or the function, because a bare number is exactly the ambiguity
-- this file exists to remove.
--
-- WHAT IS NOT HERE: calendar formatting. Rendering a wall-clock date needs
-- os.date, a timezone, and locale, none of which this file may use and all of
-- which are a config decision. A server that needs "2026-09-30 14:45:01" in a
-- log line formats it in Lua with its own date choice, where the decision is
-- visible.

CisTime = {
    SECOND = 1,
    MINUTE = 60,
    HOUR = 3600,
    DAY = 86400,
    WEEK = 604800,
    -- Milliseconds, for the frame budgets and rate-limit windows the rest of
    -- the library is written in. Not used by any function here.
    MS = 1 / 1000,
}

-- Largest unit first, so formatDuration and parseDuration agree on which
-- letter means what. Kept as one list because two lists is how those two
-- functions end up disagreeing.
--
-- `symbol` is what a formatter prints ('2h'); `field` is what parts() names the
-- result key after ('hours'). They are separate because '2h' and 'hours' are
-- different words, and deriving one from the other is how you end up with a
-- function returning `hours = '2h'`.
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
---
--- There is deliberately no default. `CisTime.now()` with no argument refuses
--- rather than reaching for os.time, because a library that quietly reads the
--- real clock in one place and takes a `now` parameter in another gives you two
--- functions with the same name and different testability, and the one you
--- cannot test is the one you will not.
---
--- @param clock function returning a number of seconds, or nil.
--- @return the number, or `nil, reason`.
function CisTime.now(clock)
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
---
--- Every field is always present, so a caller never has to test one before
--- reading it. Values are not converted between units: 1 day 2 hours is
--- `{weeks=0, days=1, hours=2, minutes=0, seconds=0}`, never hours=26.
---
--- A negative duration decomposes into zeroed fields plus `negative = true`,
--- because there is no such thing as "negative 3 hours" and forcing one is how
--- a formatter ends up printing `--1h`. `fractional` carries whatever is left
--- over below one second.
function CisTime.parts(seconds)
    local negative = false
    -- Strict about the type, unlike a `tonumber(seconds) or 0`. Half this file
    -- refusing a string and half of it accepting one would mean a caller had to
    -- know which function they were holding.
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
---
--- RULES, all of them load-bearing:
---   * ZERO-PIECES ARE OMITTED. formatDuration(8140) is '2h 14m', not
---     '2h 14m 0s'. That is what makes the output readable at a glance.
---   * BUT IT IS NEVER AN EMPTY STRING. Zero is '0s', because an empty string
---     in a log line or a UI label looks like a bug in the caller.
---   * ONLY THE LARGEST `opts.max` NON-ZERO PIECES ARE SHOWN (default 2).
---     Without that, 8140 would be '2h 14m 0s' anyway and a 40-day value would
---     be six pieces wide. Increase it when the precision matters.
---   * A SUB-SECOND duration formats as '0s' unless opts.ms, which switches to
---     milliseconds: 0.25 -> '250ms'.
---   * A NEGATIVE duration keeps its sign on the whole string: -8140 is '-2h 14m'.
---
--- opts.max       how many units to show (default 2)
--- opts.ms        render sub-second values in milliseconds (default false)
--- opts.sep       the joiner (default ' ')
--- opts.always    '0s' for zero instead of '' (the default; pass false for '')
---
--- @return a string. A non-numeric input is '0s', not an error: this is a
---   formatter, and a formatter that refuses to format is not one.
function CisTime.formatDuration(seconds, opts)
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

--- Parse a human duration back into seconds. The inverse of
--- formatDuration, and deliberately strict.
---
--- Accepts '2h 14m', '2h14m', '90s', '1d12h', '1.5h', '3 days', '1 week ago'?
--- -- no: the trailing words are rejected. What IS accepted:
---
---   * a bare number, read as SECONDS: '300' is 300
---   * a decimal on any unit: '1.5h' is 5400
---   * an optional leading sign: '-30s'
---   * long names and their plurals, case-insensitively: '2 hours', '2HOURS'
---   * whitespace between the pieces, in any amount
---
--- Every piece is CONSUMED, not merely scanned. '5x' parses as 5 and leaves 'x'
--- over, which would turn a typo into a silently wrong duration -- exactly the
--- kind of wrong answer that ends up as a ban that expires in 5 seconds.
---
--- @return the number of seconds, or `nil, reason` naming the offending piece.
function CisTime.parseDuration(text)
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
    -- A number, then optional whitespace, then letters. `.-` is lazy so '2h30m'
    -- does not swallow the whole rest of the string as one unit name.
    for num, gap, unit in s:gmatch('([%d%.]+)(%s*)([%a]+)') do
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
    -- Everything must have been consumed. Leftover text is a typo, and a typo
    -- here is a timeout that fires at the wrong moment.
    local leftover = s:gsub('([%d%.]+)(%s*)([%a]+)', '')
    leftover = leftover:gsub('%s+', '')
    if leftover ~= '' then
        return nil, ('trailing %q could not be understood'):format(leftover)
    end
    return sign * total
end

--- Relative time in words: '3 minutes ago', 'in 3 minutes', 'just now'.
---
--- `timestamp` and `now` are BOTH in seconds and BOTH are required. The
--- asymmetry is deliberate: `now` has no default because there is no clock to
--- default it to in a pure module, and this file does not read one.
---
--- THE FUTURE CASE IS HANDLED, not clamped. A timestamp later than `now`
--- formats as 'in 3 minutes'. Clamping it to 'just now' would be a lie about
--- either the clock or the data, and it is the answer that hides a desynchronised
--- server -- the exact case where the string is worth reading.
---
--- opts.within   anything closer than this is 'just now' (default 5 seconds).
---                The window exists because '0 seconds ago' reads like an error.
--- opts.future   'in %s' (default), or 'in ' .. nil -- pass false for 'after %s'
--- opts.past     '%s ago' (default)
---
--- @return a string. nil in gives 'unknown', because "this thing has no
---   timestamp" and "this thing happened just now" must not look alike.
function CisTime.relative(timestamp, now, opts)
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
    if magnitude >= CisTime.WEEK then
        local n = math.floor(magnitude / CisTime.WEEK)
        piece = ('%d %s'):format(n, n == 1 and 'week' or 'weeks')
    elseif magnitude >= CisTime.DAY then
        local n = math.floor(magnitude / CisTime.DAY)
        piece = ('%d %s'):format(n, n == 1 and 'day' or 'days')
    elseif magnitude >= CisTime.HOUR then
        local n = math.floor(magnitude / CisTime.HOUR)
        piece = ('%d %s'):format(n, n == 1 and 'hour' or 'hours')
    elseif magnitude >= CisTime.MINUTE then
        local n = math.floor(magnitude / CisTime.MINUTE)
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
---
--- The sign is KEPT, so a future `since` is negative rather than clamped to
--- zero. Clamping here would make a scheduled-but-not-yet-fired task look like
--- it just fired, which is the bug this function exists to make visible.
---
--- @return a number, or 0 when either argument is not a number. Compare the
---   argument types yourself if a missing timestamp is worth distinguishing.
function CisTime.elapsed(now, since)
    if type(now) ~= 'number' or type(since) ~= 'number' then
        return 0
    end
    return now - since
end

--- Round a duration in SECONDS to a whole number of `unit`s, to the NEAREST,
--- and return it in SECONDS.
---
--- opts.unit  one of CisTime.SECOND/MINUTE/HOUR/DAY/WEEK (default MINUTE)
---
--- NEAREST rather than down, because rounding down is a systematic bias: a
--- window configured as 90s becomes 60s, the caller's rate limit is silently
--- tightened by a third, and every window between two exact multiples loses
--- the same fraction every time. Rounding to nearest keeps the average exact,
--- so the configured budget is the budget that runs.
---
--- THE RETURN IS SECONDS, NOT A COUNT OF UNITS. The doc here used to say
--- "the number of whole units", which is a factor of `unit` away from the truth:
--- `roundTo(90, 60)` returns 120, not 2. Nothing else in this file is ambiguous
--- about its unit -- everything public is seconds or milliseconds, named as
--- such -- so "units" here was the odd one out, and it was the one a caller
--- reading only the doc would get wrong. `roundTo(90, 60) == 120` is pinned in
--- test/modules.lua so the doc cannot drift back.
---
--- @return SECONDS, rounded to a whole multiple of `unit`. Ties go UP (30s to a
---   60s unit is 60, not 0), which is the conservative direction for a rate
---   limit and the documented one rather than whatever a float landed on.
function CisTime.roundTo(seconds, unit)
    if type(seconds) ~= 'number' or seconds ~= seconds then
        return 0
    end
    if unit == nil then
        unit = CisTime.MINUTE
    end
    if type(unit) ~= 'number' or unit <= 0 then
        return 0
    end
    return math.floor(seconds / unit + 0.5) * unit
end
