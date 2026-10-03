-- cis_test_c: owns state, on purpose, and answers questions about it.
--
-- Every other harness resource exists to answer something. This one exists to
-- BE the answer -- a second resource that genuinely holds a sync record and a
-- pending callback, so that cis_libs's ownership rules have something real to
-- be right or wrong about.
--
-- The callback is deliberately left unanswered. `RegisterCallback` on the
-- server creates the handler; `AwaitCallback` is what a client does to reach it.
-- This resource registers the handler and never awaits it, which is exactly the
-- state a foreign resource must not be able to resolve.

CisTestC = { syncId = nil, callbackName = nil, created = false, why = nil }

local SYNC_ID = 'cis_test_c_record'
local CALLBACK_NAME = 'cis_test_c_pending'

CisTestC.syncId = SYNC_ID
CisTestC.callbackName = CALLBACK_NAME

CreateThread(function()
    -- Started after cis_libs, or RegisterCapability refuses a resource that has
    -- not started yet and a partial restart orders this ahead of it.
    local waited = 0
    while GetResourceState('cis_libs') ~= 'started' and waited < 100 do
        Wait(100)
        waited = waited + 100
    end
    if GetResourceState('cis_libs') ~= 'started' then
        print('[cis_test_c] cis_libs never started; nothing was owned')
        return
    end

    -- A HANDLER THAT IS NEVER INVOKED. If some other resource can complete this,
    -- `invoked` goes true and the case that cares has its answer.
    exports['cis_libs']:RegisterCallback(CALLBACK_NAME, function()
        CisTestC.invoked = true
        return 'answered by its owner'
    end)

    -- One sync record under this resource's own name, so the per-owner count can
    -- tell it apart from cis_test's.
    local made, why = exports['cis_libs']:SyncCreate('prop', {
        id = SYNC_ID,
        model = 'prop_barrier_05a',
        coords = { x = -100.0, y = 0.0, z = 0.0 },
    })
    CisTestC.created = made ~= nil
    CisTestC.why = why
    print(('[cis_test_c] sync record %s (ok=%s why=%s)')
        :format(SYNC_ID, tostring(CisTestC.created), tostring(why)))
end)

--- What cis_test asks. Everything about ownership is a question only the OWNER
--- can answer honestly -- asking cis_libs whether a record exists is asking the
--- thing under test whether it did its job.
exports('Owns', function()
    return {
        syncId = SYNC_ID,
        callbackName = CALLBACK_NAME,
        created = CisTestC.created,
        why = CisTestC.why,
        invoked = CisTestC.invoked == true,
    }
end)

--- Re-own the record after a restart of this resource, on demand. The lifecycle
--- tier stops and starts this resource, and a resource that does not rebuild
--- what it owned leaves the following cases with nothing to check.
exports('Reown', function()
    local made, why = exports['cis_libs']:SyncCreate('prop', {
        id = SYNC_ID,
        model = 'prop_barrier_05a',
        coords = { x = -100.0, y = 0.0, z = 0.0 },
    })
    CisTestC.created = made ~= nil
    CisTestC.why = why
    return CisTestC.created, why
end)
