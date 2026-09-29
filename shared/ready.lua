-- One-shot ready gate. Shared so client and server both expose Cis.ready.

CisReadyState = {
    ready = false,
    failed = false,
    waiters = {},
}

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
