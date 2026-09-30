-- One-shot ready gate. Shared so client and server both expose Cis.ready.
--
-- This one DOES hold module-level state (`CisReadyState.ready`, `.failed`,
-- `.waiters`) and is still safe to duplicate (COMPATIBILITY.md §10.2), which is
-- the exception that needs stating: a consumer's copy is only ever READ. It
-- waits, and the only thing that marks it ready is cis_libs marking the original
-- ready. A copy can never resolve early, so the failure mode of duplicating it
-- is a gate that never opens -- visible, not silent. Every other stateful file
-- in this library fails the other way, by answering with values nobody else sees.

CisReadyState = {
    ready = false,
    failed = false,
    waiters = {},
}

-- os.clock is the fallback so the module loads and is testable outside a
-- FiveM runtime. Inside one, GetGameTimer is monotonic; os.clock is wall time
-- and a clock adjustment would cut a wait short.
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
    CisReadyState.waiters = {}
end

-- Waiters are released exactly once: the list is swapped out before they run,
-- so a waiter that itself calls wait() or onReady() cannot be re-entered and
-- cannot see a half-drained list. pcall around each one because a consumer's
-- callback throwing must not strand the waiters behind it.
function CisReadyState.markReady()
    if CisReadyState.ready then
        return
    end
    CisReadyState.ready = true
    CisReadyState.failed = false
    local waiters = CisReadyState.waiters
    CisReadyState.waiters = {}
    for i = 1, #waiters do
        local ok, err = pcall(waiters[i], true)
        if not ok and print then
            print(('[cis_libs] ready waiter error: %s'):format(err))
        end
    end
    if Cis then
        Cis.isReady = true
        Cis.isFailed = false
    end
end

-- Failure is terminal and distinct from "not yet". wait() returns false for
-- both, but only `failed` is permanent: it means the library gave up waiting
-- for its configuration and the API is unavailable for the rest of the session.
-- Nothing retries.
function CisReadyState.markFailed(reason)
    CisReadyState.failed = true
    local waiters = CisReadyState.waiters
    CisReadyState.waiters = {}
    for i = 1, #waiters do
        pcall(waiters[i], false, reason)
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

function CisReadyState.onReady(cb)
    if CisReadyState.ready then
        cb(true)
        return
    end
    if CisReadyState.failed then
        cb(false)
        return
    end
    CisReadyState.waiters[#CisReadyState.waiters + 1] = cb
end
