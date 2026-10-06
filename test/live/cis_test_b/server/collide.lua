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
-- ==================================================== 5.1: a direct include
--
-- Two answers, both of them claims this resource now makes about the platform:
-- that `@include` of a cis_libs module still installs that module's legacy
-- global on this realm, and that a manifest include passes no vararg at all.
--
-- The second is not academic. A module installs its global when the chunk did
-- NOT receive the marker, so if an include passed even one argument the whole
-- distinction would silently invert and every directly-included module in the
-- ecosystem would stop existing. Reading it here is cheaper than finding out
-- from a consumer.
exports('IncludeProbe', function()
    -- QUALIFIED, because the bare getter form answered nil on a live
    -- server: `exports('Name')` inside a resource is ambiguous with the SETTER
    -- `exports('Name', fn)`, and reading it back is not a call the platform
    -- promises. Naming the resource removes the ambiguity.
    local varargs = exports['cis_test_b']:VarargProbe()
    return {
        lru = type(CisLRU),
        varargCount = varargs.varargCount,
        firstVararg = varargs.firstVararg,
        -- Proving the module is real, not just present: one LRU built and read
        -- back. A table that is a table but does not work would satisfy every
        -- check above it.
        lruWorks = (function()
            if type(CisLRU) ~= 'table' then return false end
            local cache = CisLRU.new(2)
            if not cache then return false end
            -- DOT calls, read out of the module: new/get/put take the cache
            -- as a plain first argument, not a self. Guessing colon here gives a
            -- nil argument and a failure that looks like a broken module.
            CisLRU.put(cache, 'k', 1)
            return CisLRU.get(cache, 'k') == 1
        end)(),
    }
end)
