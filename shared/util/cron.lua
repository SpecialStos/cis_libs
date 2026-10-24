-- Cron expressions: parse, compute the next run, and schedule jobs.
--
--   local cron = Cis.require('cron')
--   local job = cron.schedule('*/15 9-17 * * mon-fri', function(job, due)
--       print('quarter-hourly in office hours', due)
--   end)
--   job:stop()                                   -- or cron.stop(job)
--
-- SYNTAX. Five fields: minute (0-59), hour (0-23), day of month (1-31), month
-- (1-12 or jan-dec), day of week (0-7 or sun-sat; 0 and 7 are both Sunday).
-- Each field is `*`, a number, a range `a-b`, a step `*/s`, `a-b/s` or `a/s`
-- (a to the field's maximum), or a comma list of those. Names are case-
-- insensitive and work in ranges (`mon-fri`). Ranges do not wrap: `fri-mon` is
-- refused with the fix (`fri-sat,sun-mon`). The macros @yearly (@annually),
-- @monthly, @weekly, @daily (@midnight) and @hourly expand to their five
-- fields; @reboot is refused, since a job has nothing to do with a reboot.
--
-- DAY OF MONTH AND DAY OF WEEK, as Vixie cron does it: when BOTH fields are
-- restricted, a day matches if EITHER matches (`0 0 13 * fri` is every 13th AND
-- every Friday). When either field starts with `*` -- including a step such as
-- `*/2` -- the two are ANDed, which with a bare `*` means "the other field".
--
-- TIME ZONE. Server LOCAL time, read with os.date('*t') and written back with
-- os.time -- whatever zone the host runs in. Pass `{ utc = true }` to next,
-- matches or schedule for UTC instead. Across a daylight-saving change a local
-- time that does not exist (02:30 on the spring-forward night) runs at the
-- moment os.time maps it to, and a repeated hour runs once: next() is always
-- strictly later than its `from`, so a job can never fire twice for one slot.
--
-- THE SCHEDULER. One thread per Lua state runs every job. It sleeps until the
-- earliest job is due -- not once a frame, not once a minute -- runs what is
-- due in due order, and sleeps again; with no jobs it exits. A job scheduled
-- earlier than the planned wake starts a replacement loop and the superseded
-- one exits without running anything when it wakes. A callback runs under
-- xpcall: one that raises is reported with its traceback and stays scheduled.
-- A run missed because the server stalled is run ONCE when it catches up, not
-- once per missed slot. Times are os.time() seconds, so this is meant for the
-- server; the client has no guarantee about its wall clock.

local M = {}

local MONTHS = { jan = 1, feb = 2, mar = 3, apr = 4, may = 5, jun = 6,
    jul = 7, aug = 8, sep = 9, oct = 10, nov = 11, dec = 12 }
local DAYS = { sun = 0, mon = 1, tue = 2, wed = 3, thu = 4, fri = 5, sat = 6 }

local FIELDS = {
    { key = 'minutes', label = 'minute', min = 0, max = 59 },
    { key = 'hours', label = 'hour', min = 0, max = 23 },
    { key = 'days', label = 'day of month', min = 1, max = 31 },
    { key = 'months', label = 'month', min = 1, max = 12, names = MONTHS },
    { key = 'weekdays', label = 'day of week', min = 0, max = 7, names = DAYS },
}

local MACROS = {
    ['@yearly'] = '0 0 1 1 *',
    ['@annually'] = '0 0 1 1 *',
    ['@monthly'] = '0 0 1 * *',
    ['@weekly'] = '0 0 * * 0',
    ['@daily'] = '0 0 * * *',
    ['@midnight'] = '0 0 * * *',
    ['@hourly'] = '0 * * * *',
}

local MAX_DAYS = { 31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }

local SpecMT = {}

local function isLeap(y)
    return (y % 4 == 0 and y % 100 ~= 0) or y % 400 == 0
end

local function daysIn(y, m)
    if m == 2 then
        return isLeap(y) and 29 or 28
    end
    return MAX_DAYS[m]
end

-- Days since 1970-01-01 for a proleptic Gregorian date (Howard Hinnant's
-- days_from_civil). Pure integer arithmetic: no os.time, so no time zone.
local function daysFromCivil(y, m, d)
    if m <= 2 then y = y - 1 end
    local era = (y >= 0 and y or y - 399) // 400
    local yoe = y - era * 400
    local mp = (m + 9) % 12
    local doy = (153 * mp + 2) // 5 + d - 1
    local doe = yoe * 365 + yoe // 4 - yoe // 100 + doy
    return era * 146097 + doe - 719468
end

local function weekday(y, m, d)
    -- 1970-01-01 was a Thursday (4).
    return (daysFromCivil(y, m, d) + 4) % 7
end

local function readValue(text, field)
    if text:match('^%d+$') then
        return tonumber(text)
    end
    if field.names then
        local v = field.names[text:lower()]
        if v then return v end
    end
    return nil
end

local function parseField(text, field)
    local set = {}
    if text == '' then
        return nil, ('the %s field is empty'):format(field.label)
    end
    for piece in (text .. ','):gmatch('([^,]*),') do
        if piece == '' then
            return nil, ('the %s field %q has an empty list item'):format(field.label, text)
        end
        local base, stepText = piece:match('^([^/]+)/(.+)$')
        if not base then base = piece end
        local step = 1
        if stepText then
            step = stepText:match('^%d+$') and tonumber(stepText) or nil
            if not step or step < 1 then
                return nil, ('the %s step in %q must be a whole number of at least 1'):format(field.label, piece)
            end
        end
        local lo, hi
        if base == '*' then
            lo, hi = field.min, field.max
            if field.key == 'weekdays' then hi = 6 end
        else
            local a, b = base:match('^([^-]+)-([^-]+)$')
            if a then
                lo, hi = readValue(a, field), readValue(b, field)
                if lo == nil or hi == nil then
                    return nil, ('%q is not a valid %s range'):format(piece, field.label)
                end
            else
                lo = readValue(base, field)
                if lo == nil then
                    return nil, ('%q is not a valid %s (%s-%s%s)'):format(piece, field.label,
                        tostring(field.min), tostring(field.max), field.names and ', or a name' or '')
                end
                hi = stepText and field.max or lo
                if stepText and field.key == 'weekdays' then hi = 6 end
            end
        end
        if lo < field.min or hi > field.max or lo > field.max or hi < field.min then
            return nil, ('%q is outside the %s range %s-%s'):format(piece, field.label,
                tostring(field.min), tostring(field.max))
        end
        if lo > hi then
            return nil, ('%q runs backwards; cron ranges do not wrap, so split it in two (for example fri-sat,sun-mon)')
                :format(piece)
        end
        for v = lo, hi, step do
            -- 7 is Sunday written the other way.
            local w = (field.key == 'weekdays' and v == 7) and 0 or v
            set[w] = true
        end
    end
    local list = {}
    for v = field.min, field.max do
        if set[v] then list[#list + 1] = v end
    end
    return { set = set, list = list }
end

local function nextIn(list, v)
    for i = 1, #list do
        if list[i] >= v then return list[i] end
    end
    return nil
end

local function dayMatches(spec, y, m, d)
    local domOk = spec._days.set[d] == true
    local dowOk = spec._weekdays.set[weekday(y, m, d)] == true
    if spec.domStar or spec.dowStar then
        return domOk and dowOk
    end
    return domOk or dowOk
end

--- Parse a five-field expression or a macro.
---@param expr string
---@return table|nil  the parsed spec: { source, minutes, hours, days, months, weekdays (sorted arrays), domStar, dowStar }; next/matches/schedule accept it in place of the text
---@return string|nil  why, naming the field and the fix
function M.parse(expr)
    if type(expr) ~= 'string' then
        return nil, ('a cron expression must be a string, got %s'):format(type(expr))
    end
    local text = expr:gsub('^%s+', ''):gsub('%s+$', '')
    if text:sub(1, 1) == '@' then
        local macro = MACROS[text:lower()]
        if not macro then
            return nil, ('%q is not a macro; use @yearly, @monthly, @weekly, @daily or @hourly'):format(text)
        end
        text = macro
    end
    local parts = {}
    for p in text:gmatch('%S+') do parts[#parts + 1] = p end
    if #parts ~= 5 then
        return nil, ('%q has %d fields; cron needs 5: minute hour day-of-month month day-of-week')
            :format(expr, #parts)
    end
    local spec = setmetatable({ source = expr }, SpecMT)
    for i, field in ipairs(FIELDS) do
        local parsed, why = parseField(parts[i], field)
        if not parsed then
            return nil, why
        end
        spec['_' .. field.key] = parsed
        spec[field.key] = parsed.list
    end
    spec.domStar = parts[3]:sub(1, 1) == '*'
    spec.dowStar = parts[5]:sub(1, 1) == '*'
    -- Refused here rather than searched for 400 years: when the day of month
    -- decides (the fields are ANDed), some allowed month must have that day.
    if spec.domStar or spec.dowStar then
        local possible = false
        for _, m in ipairs(spec.months) do
            for _, d in ipairs(spec.days) do
                if d <= MAX_DAYS[m] then possible = true break end
            end
            if possible then break end
        end
        if not possible then
            return nil, ('%q can never run: no allowed month has any of its days of the month'):format(expr)
        end
    end
    return spec
end

local function resolve(expr)
    if type(expr) == 'table' and getmetatable(expr) == SpecMT then
        return expr
    end
    return M.parse(expr)
end

-- The first matching (y, m, d, h, min) at or after the given fields, which may
-- overflow by one (minute 60, hour 24) and are normalised here.
local function nextFields(spec, y, m, d, h, mi)
    if mi > 59 then mi = 0; h = h + 1 end
    if h > 23 then h = 0; mi = 0; d = d + 1 end
    if d > daysIn(y, m) then d = 1; h = 0; mi = 0; m = m + 1 end
    if m > 12 then m = 1; y = y + 1 end
    local months, hours, minutes = spec._months.set, spec.hours, spec.minutes
    -- The Gregorian calendar repeats every 400 years, so a match that exists is
    -- found inside one cycle; parse has already refused the ones that never exist.
    local stop = y + 400
    while y <= stop do
        if months[m] then
            local dim = daysIn(y, m)
            while d <= dim do
                if dayMatches(spec, y, m, d) then
                    local hh = nextIn(hours, h)
                    while hh do
                        local mm = nextIn(minutes, hh == h and mi or 0)
                        if mm then
                            return y, m, d, hh, mm
                        end
                        hh = nextIn(hours, hh + 1)
                    end
                end
                d = d + 1
                h, mi = 0, 0
            end
        end
        m = m + 1
        d, h, mi = 1, 0, 0
        if m > 12 then
            m = 1
            y = y + 1
        end
    end
    return nil
end

local function toTimestamp(utc, y, m, d, h, mi)
    if utc then
        -- Float arithmetic: days * 86400 passes 2^31 in 2038, and a 32-bit
        -- integer runtime would wrap it.
        local t = daysFromCivil(y, m, d) * 86400.0 + h * 3600 + mi * 60
        return math.tointeger(t) or t
    end
    return os.time({ year = y, month = m, day = d, hour = h, min = mi, sec = 0 })
end

-- os.date raises for a time the platform cannot convert (before the epoch on
-- Windows, far past 2038 elsewhere).
local function fieldsOf(t, utc)
    local ok, f = pcall(os.date, utc and '!*t' or '*t', t)
    return ok and f or nil
end

--- The first time strictly after fromTime that the expression matches.
---@param expr string|table  an expression or a spec from parse
---@param fromTime? number  epoch seconds; default os.time()
---@param opts? table  { utc = boolean } -- default local time
---@return number|nil  epoch seconds
---@return string|nil  why
function M.next(expr, fromTime, opts)
    local spec, why = resolve(expr)
    if not spec then
        return nil, why
    end
    if fromTime == nil then
        fromTime = os.time()
    end
    if type(fromTime) ~= 'number' or fromTime ~= fromTime or fromTime == math.huge or fromTime == -math.huge then
        return nil, ('fromTime must be epoch seconds, got %s'):format(tostring(fromTime))
    end
    local from = math.floor(fromTime)
    local utc = type(opts) == 'table' and opts.utc == true
    local f = fieldsOf(from, utc)
    if not f then
        return nil, ('%s is outside the range of times this platform can convert'):format(tostring(fromTime))
    end
    local y, m, d, h, mi = f.year, f.month, f.day, f.hour, f.min + 1
    -- A daylight-saving fold can map a later wall-clock minute to an EARLIER
    -- instant; step past it rather than answer a time that is not after `from`.
    for _ = 1, 180 do
        local Y, MO, D, H, MI = nextFields(spec, y, m, d, h, mi)
        if Y == nil then
            return nil, ('%s matches no time in the next 400 years'):format(tostring(spec.source))
        end
        local t = toTimestamp(utc, Y, MO, D, H, MI)
        if t > from then
            return t
        end
        y, m, d, h, mi = Y, MO, D, H, MI + 1
    end
    return nil, 'no time after fromTime could be represented (a daylight-saving fold?)'
end

--- Whether a moment falls in a minute the expression matches.
---@param expr string|table  an expression or a spec from parse
---@param time? number  epoch seconds; default os.time()
---@param opts? table  { utc = boolean }
---@return boolean|nil
---@return string|nil  why, for a bad expression
function M.matches(expr, time, opts)
    local spec, why = resolve(expr)
    if not spec then
        return nil, why
    end
    if time == nil then
        time = os.time()
    end
    if type(time) ~= 'number' or time ~= time or time == math.huge or time == -math.huge then
        return nil, ('time must be epoch seconds, got %s'):format(tostring(time))
    end
    local f = fieldsOf(math.floor(time), type(opts) == 'table' and opts.utc == true)
    if not f then
        return nil, ('%s is outside the range of times this platform can convert'):format(tostring(time))
    end
    return spec._minutes.set[f.min] == true and spec._hours.set[f.hour] == true
        and spec._months.set[f.month] == true and dayMatches(spec, f.year, f.month, f.day)
end

-- ------------------------------------------------------------ scheduler

local JobMT = { __index = {} }
local jobs = {}
local nextJobId = 0
local nextLoopId = 0
local liveLoop = nil       -- the id of the loop allowed to run jobs
local plannedWake = nil    -- what the live loop is asleep until; nil while it is running jobs

local function report(job, err)
    print(('^1[ERROR] cis_libs cron: job %s (%s) raised: %s^7')
        :format(tostring(job.name or job.id), tostring(job.spec.source), tostring(err)))
end

local function earliestDue()
    local best
    for _, job in pairs(jobs) do
        if best == nil or job.due < best then best = job.due end
    end
    return best
end

local function runDue(nowTime)
    local due = {}
    for _, job in pairs(jobs) do
        if job.due <= nowTime then due[#due + 1] = job end
    end
    table.sort(due, function(a, b)
        if a.due ~= b.due then return a.due < b.due end
        return a.id < b.id
    end)
    for _, job in ipairs(due) do
        -- A job an earlier callback stopped does not run.
        if jobs[job.id] == job then
            local slot = job.due
            -- The next slot is computed BEFORE the callback, from whichever is
            -- later of the slot and now: a stall runs once, not once per slot.
            local nextDue = M.next(job.spec, slot > nowTime and slot or nowTime, { utc = job.utc })
            if nextDue then
                job.due = nextDue
            else
                jobs[job.id] = nil
                job.active = false
            end
            job.runs = job.runs + 1
            local ok, err = xpcall(job.fn, debug.traceback, job, slot)
            if not ok then report(job, err) end
        end
    end
end

local function loop(id)
    while liveLoop == id do
        plannedWake = nil
        runDue(os.time())
        if liveLoop ~= id then return end
        local due = earliestDue()
        if due == nil then
            liveLoop = nil
            return
        end
        plannedWake = due
        local ms = (due - os.time()) * 1000
        if ms < 0 then ms = 0 end
        Wait(ms)
    end
end

local function wake(due)
    if liveLoop ~= nil and (plannedWake == nil or plannedWake <= due) then
        -- The live loop is running jobs (and will re-plan) or wakes in time.
        return
    end
    nextLoopId = nextLoopId + 1
    local id = nextLoopId
    liveLoop = id
    plannedWake = due
    CreateThread(function() loop(id) end)
end

--- Run fn at every time the expression matches, until stopped.
---@param expr string|table  an expression or a spec from parse
---@param fn fun(job: table, due: number)  called with the job and the slot it is running for (epoch seconds)
---@param opts? table  { utc = boolean, name = string (for error reports) }
---@return table|nil  the job: job:stop(), job:isActive(), job:nextRun()
---@return string|nil  why, for a bad expression or a non-function
function M.schedule(expr, fn, opts)
    if type(fn) ~= 'function' then
        return nil, ('cron.schedule needs a function to run, got %s'):format(type(fn))
    end
    local spec, why = resolve(expr)
    if not spec then
        return nil, why
    end
    local utc = type(opts) == 'table' and opts.utc == true
    local due, nextWhy = M.next(spec, os.time(), { utc = utc })
    if not due then
        return nil, nextWhy
    end
    nextJobId = nextJobId + 1
    local job = setmetatable({
        id = nextJobId,
        spec = spec,
        fn = fn,
        utc = utc,
        name = type(opts) == 'table' and opts.name or nil,
        due = due,
        runs = 0,
        active = true,
    }, JobMT)
    jobs[job.id] = job
    wake(due)
    return job
end

--- Stop a job. Safe from inside its own callback and more than once.
---@param job table  from schedule
---@return boolean  true when it was still scheduled
function M.stop(job)
    if type(job) ~= 'table' or jobs[job.id] ~= job then
        return false
    end
    jobs[job.id] = nil
    job.active = false
    return true
end

--- Whether a job is still scheduled.
---@param job table  from schedule
---@return boolean
function M.isActive(job)
    return type(job) == 'table' and jobs[job.id] == job
end

--- When a job runs next.
---@param job table  from schedule
---@return number|nil  epoch seconds, or nil once stopped
function M.nextRun(job)
    if not M.isActive(job) then
        return nil
    end
    return job.due
end

--- How many jobs are scheduled in this Lua state.
---@return integer
function M.count()
    local n = 0
    for _ in pairs(jobs) do n = n + 1 end
    return n
end

JobMT.__index.stop = M.stop
JobMT.__index.isActive = M.isActive
JobMT.__index.nextRun = M.nextRun

-- A MODULE, NOT A GLOBAL.
if ... ~= 'cis_require' then
    CisCron = M
end

return M
