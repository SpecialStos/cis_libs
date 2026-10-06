-- One-shot ready gate. Shared so client and server both expose Cis.ready.

CisReadyState = {
    ready = false,
    failed = false,
    -- WHY it failed, kept so a consumer that arrives after the fact is told the reason
    reason = nil,
    waiters = {},
}

-- os.clock is the fallback so the module loads and is testable outside a FiveM runtime.
local function nowMs()
    if GetGameTimer then
        return GetGameTimer()
    end
    return math.floor(os.clock() * 1000)
end

local function sleep(ms)
    if Citizen and Citizen.Wait then
        Citizen.Wait(ms)
    elseif Wait then
        Wait(ms)
    end
end

function CisReadyState.reset()
    CisReadyState.ready = false
    CisReadyState.failed = false
    CisReadyState.reason = nil
    CisReadyState.waiters = {}
end

-- Run one waiter's callback, under pcall, always.
local function callWaiter(context, cb, ...)
    local ok, err = pcall(cb, ...)
    if not ok and print then
        print(('[cis_libs] %s error: %s'):format(context, err))
    end
end

-- Ready is terminal. Both setters refuse once the gate has settled, in EITHER
local function settle()
    return CisReadyState.ready or CisReadyState.failed
end

-- Waiters are released exactly once: the list is swapped out before they run, so a
function CisReadyState.markReady()
    if settle() then
        return
    end
    CisReadyState.ready = true
    CisReadyState.reason = nil
    local waiters = CisReadyState.waiters
    CisReadyState.waiters = {}
    for i = 1, #waiters do
        callWaiter('ready waiter', waiters[i], true)
    end
    if Cis then
        Cis.isReady = true
        Cis.isFailed = false
    end
end

-- Failure is terminal and distinct from "not yet".
function CisReadyState.markFailed(reason)
    if settle() then
        return
    end
    CisReadyState.failed = true
    CisReadyState.reason = reason
    local waiters = CisReadyState.waiters
    CisReadyState.waiters = {}
    for i = 1, #waiters do
        callWaiter('failure waiter', waiters[i], false, reason)
    end
    if Cis then
        Cis.isReady = false
        Cis.isFailed = true
    end
end

function CisReadyState.wait(timeout)
    if CisReadyState.ready then
        return true
    end
    if CisReadyState.failed then
        return false
    end
    local deadline = nowMs() + (timeout or 15000)
    while not CisReadyState.ready and not CisReadyState.failed and nowMs() < deadline do
        sleep(50)
    end
    return CisReadyState.ready
end

--- Register interest in the gate.
--- @param cb function  called `(true)` when the gate becomes ready, or
function CisReadyState.onReady(cb)
    if type(cb) ~= 'function' then
        return
    end
    if CisReadyState.ready then
        callWaiter('ready waiter', cb, true)
        return
    end
    if CisReadyState.failed then
        callWaiter('failure waiter', cb, false, CisReadyState.reason)
        return
    end
    CisReadyState.waiters[#CisReadyState.waiters + 1] = cb
end
