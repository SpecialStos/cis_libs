-- cis_test_b's server half: colliding sync ids, colliding callback names, and a
-- record of what it was actually allowed to do.
--
-- EVERY RESULT IS RECORDED, because the harness compares cis_test's view against
-- this one. A collision that is silently resolved "correctly" from one side and
-- wrongly from the other is invisible unless both sides are written down.

CisTestB = { created = {}, refusals = {} }

local function note(kind, key, ...)
    local args = table.pack(...)
    CisTestB.created[#CisTestB.created + 1] = {
        kind = kind, key = key, args = args, n = args.n,
    }
    -- A short JSON line, so the harness reads this from the console exactly as
    -- it reads its own results rather than needing a second channel.
    local parts = {}
    for i = 1, args.n do parts[#parts + 1] = tostring(args[i]) end
    print(('[cis_test_b] %s %s %s'):format(kind, key, table.concat(parts, ' ')))
end

exports('Created', function() return CisTestB.created end)
exports('Refusals', function() return CisTestB.refusals end)
exports('Clear', function()
    CisTestB.created = {}
    CisTestB.refusals = {}
    return true
end)

CreateThread(function()
    local waited = 0
    while GetResourceState('cis_libs') ~= 'started' and waited < 100 do
        Wait(100)
        waited = waited + 100
    end
    if GetResourceState('cis_libs') ~= 'started' then
        print('[cis_test_b] cis_libs never started; nothing to collide with')
        return
    end

    -- A SYNC RECORD UNDER AN ID cis_test ALSO USES. If ids were global rather
    -- than namespaced by owner, one of these two would overwrite the other and
    -- one of the resources would be streaming an entity it never made.
    local made = exports['cis_libs']:SyncCreate('prop', {
        id = 'shared-id',
        model = 'prop_barrier_05a',
        coords = { x = 100.0, y = 0.0, z = 0.0 },
    })
    if made then
        note('sync', 'shared-id', made)
    else
        CisTestB.refusals[#CisTestB.refusals + 1] = { kind = 'sync', key = 'shared-id' }
    end

    -- A MUTATING EXPORT THAT MUST BE REFUSED. This resource is not in
    -- AuthorizedResources, so this is the case the plan's security suite is
    -- built on: the refusal has to arrive, and it has to name the fix.
    local ok, why = exports['cis_libs']:SetConfig({ CallbackTimeout = 9999 }, { DropPlayer = false })
    print(('[cis_test_b] SetConfig -> ok=%s why=%s'):format(tostring(ok), tostring(why)))
    if not ok then
        CisTestB.refusals[#CisTestB.refusals + 1] = {
            kind = 'SetConfig', key = 'unauthorized', why = why,
        }
    end
end)