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
    -- WHY it failed, kept so a consumer that arrives after the fact is told the
    -- reason and not just the fact. It used to be dropped on the floor, which
    -- left "cis_libs never became ready" with nothing behind it.
    reason = nil,
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
    CisReadyState.reason = nil
    CisReadyState.waiters = {}
end

-- Run one waiter's callback, under pcall, always.
--
-- pcall everywhere, including on the IMMEDIATE path, because the callback is
-- the consumer's code and this is a gate rather than a sandbox: a consumer whose
-- callback throws must not be able to strand the waiters queued behind it, and
-- must not have its exception surface from a call whose entire job is to
-- register interest. `markReady` already did this for queued waiters; the
-- immediate call did not, and a throw there propagated straight out of
-- onReady() into whatever was configuring a zone.
local function callWaiter(context, cb, ...)
    local ok, err = pcall(cb, ...)
    if not ok and print then
        print(('[cis_libs] %s error: %s'):format(context, err))
    end
end

-- Ready is terminal. Both setters refuse once the gate has settled, in EITHER
-- direction, so `ready` and `failed` can never both be true.
--
-- They used to be able to: markReady set `failed = false` and markFailed set
-- `failed = true` without looking at `ready`, so a failure arriving after a
-- success left the gate reporting itself both ready and failed. Every reader
-- checks `ready` first and answered `true` -- a consumer was told its API was
-- available while `Cis.isFailed` said otherwise. There is no second transition
-- to make, because nothing in the library ever un-readies the gate.
local function settle()
    return CisReadyState.ready or CisReadyState.failed
end

-- Waiters are released exactly once: the list is swapped out before they run,
-- so a waiter that itself calls wait() or onReady() cannot be re-entered and
-- cannot see a half-drained list. pcall around each one because a consumer's
-- callback throwing must not strand the waiters behind it.
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

-- Failure is terminal and distinct from "not yet". wait() returns false for
-- both, but only `failed` is permanent: it means the library gave up waiting
-- for its configuration and the API is unavailable for the rest of the session.
-- Nothing retries, and nothing can undo it -- not even a later markReady.
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
---
--- @param cb function  called `(true)` when the gate becomes ready, or
---         `(false, reason)` when it has failed. The reason is passed to a
---         waiter arriving AFTER the failure as well as to one queued before
---         it -- it used to be dropped for the late case, which is the one a
---         consumer starting up late actually hits.
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
