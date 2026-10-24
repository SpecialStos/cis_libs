-- Pausable countdown timers, and setTimeout / setInterval with cancellation.
--
--   local timer = Cis.require('timer')
--   local t = timer.new(30000, function() print('done') end)
--   t:pause()  t:play()  t:getTimeLeft('s')  t:restart()  t:forceEnd(true)
--
--   local id = timer.setTimeout(function() print('later') end, 5000)
--   timer.clearTimeout(id)
--
-- Every timer method is also a module function taking the timer first, like
-- every other module: `timer.pause(t)` is `t:pause()`.
--
-- NO BUSY-WAIT. A running timer is one thread asleep in Wait() for exactly the
-- time left; nothing polls per frame. Pausing does not wake that thread: it
-- exits without doing anything if the timer is paused or ended when it wakes,
-- and a play before then reuses it, so pause/play cycles never pile up threads. Time is GetGameTimer() milliseconds, which is monotonic and
-- does not jump with the wall clock.
--
-- ARGUMENT ORDER. setTimeout and setInterval accept the callback and the delay
-- in EITHER order, so both the JavaScript habit `setTimeout(fn, ms)` and the
-- FiveM habit `SetTimeout(ms, fn)` work. Extra arguments are passed to the
-- callback. An interval whose callback raises keeps running, and the error is
-- printed with its traceback.

local M = {}

local TimerMT = { __index = M }

local function now()
    return GetGameTimer()
end

local function checkMs(ms, who)
    if type(ms) ~= 'number' or ms ~= ms or ms < 0 or ms == math.huge then
        error(('timer.%s: the delay must be a finite number of milliseconds >= 0, got %s')
            :format(who, tostring(ms)), 3)
    end
end

local function checkTimer(t, who)
    if type(t) ~= 'table' or getmetatable(t) ~= TimerMT then
        error(('timer.%s: expected a timer from timer.new, got %s -- call it as t:%s(...) or timer.%s(t, ...)')
            :format(who, type(t), who, who), 3)
    end
end

local function remaining(t)
    if t._ended then
        return 0
    end
    local used = t._elapsed
    if not t._paused then
        used = used + (now() - t._startedAt)
    end
    local left = t._duration - used
    if left < 0 then left = 0 end
    return left
end

-- One sleeping thread per timer at a time. A pause, restart or forceEnd leaves
-- it asleep; when it wakes it exits if the timer is paused or ended, and else
-- sleeps on for the time left. A play while it sleeps reuses it: the new
-- deadline is never earlier than the one it is sleeping towards.
local function arm(t)
    if t._sleeper then return end
    t._sleeper = true
    CreateThread(function()
        while true do
            if t._paused or t._ended then
                t._sleeper = false
                return
            end
            local left = remaining(t)
            if left <= 0 then break end
            Wait(left)
        end
        t._sleeper = false
        t._ended = true
        t._elapsed = t._duration
        if t._onEnd then
            t._onEnd(t)
        end
    end)
end

--- A countdown timer that calls onEnd when it runs out.
---@param ms number  the duration in milliseconds
---@param onEnd? fun(timer: table)  called once, in its own thread, when the time is up
---@param opts? table  { autoStart = boolean (default true) }
---@return table  the timer
function M.new(ms, onEnd, opts)
    checkMs(ms, 'new')
    if onEnd ~= nil and type(onEnd) ~= 'function' then
        error(('timer.new: onEnd must be a function or nil, got %s'):format(type(onEnd)), 2)
    end
    local t = setmetatable({
        _duration = ms,
        _onEnd = onEnd,
        _elapsed = 0,
        _startedAt = 0,
        _paused = true,
        _ended = false,
        _sleeper = false,
    }, TimerMT)
    if not (type(opts) == 'table' and opts.autoStart == false) then
        M.play(t)
    end
    return t
end

--- Start or resume.
---@param t table  the timer
---@return boolean  false when it is already running or has ended
function M.play(t)
    checkTimer(t, 'play')
    if t._ended or not t._paused then
        return false
    end
    t._paused = false
    t._startedAt = now()
    arm(t)
    return true
end

--- Pause, keeping the time left.
---@param t table  the timer
---@return boolean  false when it is already paused or has ended
function M.pause(t)
    checkTimer(t, 'pause')
    if t._ended or t._paused then
        return false
    end
    t._elapsed = t._elapsed + (now() - t._startedAt)
    t._paused = true
    return true
end

--- Back to the full duration.
---@param t table  the timer
---@param autoStart? boolean  default true; false leaves it paused at the full duration
---@return boolean  true
function M.restart(t, autoStart)
    checkTimer(t, 'restart')
    t._elapsed = 0
    t._ended = false
    t._paused = true
    if autoStart ~= false then
        M.play(t)
    end
    return true
end

--- End now.
---@param t table  the timer
---@param triggerOnEnd? boolean  call onEnd as well (synchronously); default false
---@return boolean  false when it had already ended
function M.forceEnd(t, triggerOnEnd)
    checkTimer(t, 'forceEnd')
    if t._ended then
        return false
    end
    t._ended = true
    t._paused = false
    t._elapsed = t._duration
    if triggerOnEnd and t._onEnd then
        t._onEnd(t)
    end
    return true
end

--- Whether it is paused (a new timer with autoStart = false is paused).
---@param t table  the timer
---@return boolean
function M.isPaused(t)
    checkTimer(t, 'isPaused')
    return t._paused
end

--- Whether it has run out or been ended.
---@param t table  the timer
---@return boolean
function M.hasEnded(t)
    checkTimer(t, 'hasEnded')
    return t._ended
end

local function round2(v)
    return math.floor(v * 100 + 0.5) / 100
end

--- The time left.
---@param t table  the timer
---@param format? string  'ms', 's', 'm' or 'h' for one number (s/m/h rounded to 2 decimals); nil for a breakdown
---@return number|table  a number, or { h, m, s, ms } where each is the whole part left after the larger units
function M.getTimeLeft(t, format)
    checkTimer(t, 'getTimeLeft')
    local left = remaining(t)
    if format == 'ms' then
        return left
    elseif format == 's' then
        return round2(left / 1000)
    elseif format == 'm' then
        return round2(left / 60000)
    elseif format == 'h' then
        return round2(left / 3600000)
    elseif format ~= nil then
        error(("timer.getTimeLeft: format must be 'ms', 's', 'm', 'h' or nil, got %s"):format(tostring(format)), 2)
    end
    local whole = math.floor(left)
    return {
        h = whole // 3600000,
        m = (whole % 3600000) // 60000,
        s = (whole % 60000) // 1000,
        ms = whole % 1000,
    }
end

-- ------------------------------------------------------------ timeouts

local nextId = 0
local active = {}

local function callbackAndDelay(a, b, who)
    if type(a) == 'function' then
        checkMs(b, who)
        return a, b
    end
    if type(b) == 'function' then
        checkMs(a, who)
        return b, a
    end
    error(('timer.%s: pass a function and a delay in milliseconds, in either order; got %s and %s')
        :format(who, type(a), type(b)), 3)
end

local function report(id, err)
    print(('^1[ERROR] cis_libs timer: interval %s raised: %s^7'):format(tostring(id), tostring(err)))
end

--- Call fn once after a delay, unless cleared first.
---@param a function|number  the callback, or the delay
---@param b function|number  the delay, or the callback
---@param ... any  passed to the callback
---@return integer  an id for clearTimeout
function M.setTimeout(a, b, ...)
    local fn, ms = callbackAndDelay(a, b, 'setTimeout')
    nextId = nextId + 1
    local id = nextId
    active[id] = true
    local args = table.pack(...)
    CreateThread(function()
        Wait(ms)
        if not active[id] then return end
        active[id] = nil
        fn(table.unpack(args, 1, args.n))
    end)
    return id
end

--- Call fn every ms milliseconds until cleared. The first call is one interval after this one.
---@param a function|number  the callback, or the interval
---@param b function|number  the interval, or the callback
---@param ... any  passed to the callback
---@return integer  an id for clearInterval
function M.setInterval(a, b, ...)
    local fn, ms = callbackAndDelay(a, b, 'setInterval')
    nextId = nextId + 1
    local id = nextId
    active[id] = true
    local args = table.pack(...)
    CreateThread(function()
        while true do
            Wait(ms)
            if not active[id] then return end
            local ok, err = xpcall(fn, debug.traceback, table.unpack(args, 1, args.n))
            if not ok then report(id, err) end
        end
    end)
    return id
end

--- Cancel a timeout or an interval. Safe to call from inside its own callback, and more than once.
---@param id integer
---@return boolean  true when it was still pending
function M.clearTimeout(id)
    if id == nil or active[id] == nil then
        return false
    end
    active[id] = nil
    return true
end

M.clearInterval = M.clearTimeout

-- A MODULE, NOT A GLOBAL.
if ... ~= 'cis_require' then
    CisTimer = M
end

return M
