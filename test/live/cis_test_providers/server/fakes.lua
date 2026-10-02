-- Every capability slot on the server, as a recording fake.
--
-- THE SIGNATURE IS NOT OBVIOUS AND GETTING IT WRONG IS SILENT.
--
-- cis_libs resolves a provider by calling the exported function with the
-- exports table as its only argument and reading the method table back. It then
-- dispatches with `pcall(fn, arg1, arg2, ...)` -- the METHOD NAME IS STRIPPED
-- and there is NO leading `self`.
--
-- So a method is `function(sql, params)`, not `function(self, sql, params)`.
-- Writing the self form does not raise: a Lua function is perfectly happy to
-- be handed an extra argument, so every method silently receives the caller's
-- first argument where it expected `self`, and every argument after that is
-- shifted one slot left. A `db.query(sql, params)` reaches the fake as
-- `query(<self>, sql)` with params nil.
--
-- That is not hypothetical. The same trap is why the exports table is passed
-- explicitly in shared/registry.lua and why a comment there says do not
-- "simplify" it back.

-- Wraps one method so that it records before it answers, and honours any fault
-- the test injected for it. `answers` supplies the normal return values.
local function method(slot, name, answers)
    return function(...)
        local args = table.pack(...)
        CisTestRing.Record(slot, name, args)

        local fault = CisTestRing.ApplyFault(slot, name)
        if fault == true then
            -- `nil` fault: answer nothing at all.
            return nil
        elseif fault == 'false_reason' then
            return false, ('cis_test_providers: injected refusal on %s.%s'):format(slot, name)
        elseif fault == 'wrong_shape' then
            -- Right arity, wrong types. The failure no return-value assertion
            -- catches and every type check does.
            return 'not-a-number', false
        end

        return answers(args)
    end
end

-- ---------------------------------------------------------------- framework
local framework = {
    get = method('framework', 'get', function() return {} end),
    NormalizedPlayer = method('framework', 'NormalizedPlayer', function(a)
        return { id = a[1], name = 'test', job = 'unemployed', identifier = 'test', money = 0, metadata = {} }
    end),
    Notify = method('framework', 'Notify', function() return nil end),
    ShowNotification = method('framework', 'ShowNotification', function() return nil end),
    IsLoaded = method('framework', 'IsLoaded', function() return true end),
    -- Answers TRUE for every permission. The security suite needs a framework
    -- that grants, and the cases that must be refused are refused by cis_libs
    -- before this is ever asked -- so a permissive fake here cannot mask a
    -- refusal bug in the library.
    HasPermission = method('framework', 'HasPermission', function() return true end),
    GetPlayerJob = method('framework', 'GetPlayerJob', function()
        return { name = 'unemployed', label = 'Unemployed', grade = 0 }
    end),
}

-- ----------------------------------------------------------------- database
-- Rows the tests can seed. A test writes them here and the fake answers with
-- them, so `nil rows` and `empty rows` are distinguishable -- the difference
-- between "no result" and "no rows", which several callers get wrong.
CisTestRing.dbRows = {}
CisTestRing.dbResult = nil
CisTestRing.dbTransactions = {}

local database = {
    query = method('database', 'query', function() return CisTestRing.dbRows end),
    single = method('database', 'single', function()
        local rows = CisTestRing.dbRows
        return rows and rows[1] or nil
    end),
    scalar = method('database', 'scalar', function() return CisTestRing.dbResult end),
    insert = method('database', 'insert', function() return 1 end),
    update = method('database', 'update', function() return 1 end),
    transaction = method('database', 'transaction', function(a)
        CisTestRing.dbTransactions[#CisTestRing.dbTransactions + 1] = a[1]
        return true
    end),
    ready = method('database', 'ready', function() return true end),
}

-- ------------------------------------------------------------------- target
local target = {
    available = method('target', 'available', function() return true end),
    create = method('target', 'create', function() return true end),
    remove = method('target', 'remove', function() return true end),
    exists = method('target', 'exists', function() return true end),
    named = method('target', 'named', function() return 'cis_test_target' end),
}

-- --------------------------------------------------------------- inventory
CisTestRing.inventory = {}

local function invCount(args)
    local item = args[#args]
    return (CisTestRing.inventory[item] or 0)
end

local inventory = {
    count = method('inventory', 'count', function(a) return invCount(a) end),
    add = method('inventory', 'add', function(a)
        local item, amount = a[#a - 1], a[#a]
        CisTestRing.inventory[item] = (CisTestRing.inventory[item] or 0) + (amount or 1)
        return true
    end),
    remove = method('inventory', 'remove', function(a)
        local item, amount = a[#a - 1], a[#a]
        CisTestRing.inventory[item] = (CisTestRing.inventory[item] or 0) - (amount or 1)
        return true
    end),
    has = method('inventory', 'has', function(a) return invCount(a) >= (a[#a] or 1) end),
    snapshot = method('inventory', 'snapshot', function() return CisTestRing.inventory end),
}

local inventoryProvider = {
    name = method('inventoryProvider', 'name', function() return 'cis_test_inventory' end),
    available = method('inventoryProvider', 'available', function() return true end),
    count = method('inventoryProvider', 'count', function(a) return invCount(a) end),
    add = method('inventoryProvider', 'add', function() return true end),
    remove = method('inventoryProvider', 'remove', function() return true end),
}

-- ------------------------------------------------------------------- doors
local doors = {
    state = method('doors', 'state', function() return false end),
    lock = method('doors', 'lock', function() return 0 end),
    unlock = method('doors', 'unlock', function() return 0 end),
    add = method('doors', 'add', function() return true end),
    addGroup = method('doors', 'addGroup', function() return true end),
    breakDoor = method('doors', 'breakDoor', function() return nil end),
    fixDoor = method('doors', 'fixDoor', function() return nil end),
    all = method('doors', 'all', function() return { doors = {}, groups = {} } end),
    -- FALSE on purpose, and this is the interesting one. The security posture
    -- asks whether this install has EVER persisted anything rather than
    -- querying a table, and the plan's 3.8 change deletes that question. A fake
    -- answering true here would make an uninstalled install look migrated.
    persisted = method('doors', 'persisted', function() return false end),
}

-- ----------------------------------------------------------------- discord
CisTestRing.discord = {}

local discord = {
    log = method('discord', 'log', function(a)
        -- Record the webhook key so a test can prove the RIGHT one was chosen.
        -- An operator's failure mode is a message going to the wrong channel,
        -- which no return-value assertion can see.
        CisTestRing.discord[#CisTestRing.discord + 1] = {
            webhook = a[1], title = a[2], message = a[3],
        }
        return nil
    end),
    depth = method('discord', 'depth', function() return #CisTestRing.discord end),
}

-- ---------------------------------------------------------------- security
CisTestRing.drops = {}

local security = {
    -- Returns FALSE and records, so a case that reaches this has NOT removed the
    -- player. The harness config also sets DropPlayer false and the fake refuses
    -- to call it at all: the contract is that the harness never drops a player,
    -- and the cleanest way to guarantee that is to have nothing in this file
    -- capable of dropping one.
    drop = method('security', 'drop', function(a)
        CisTestRing.drops[#CisTestRing.drops + 1] = { src = a[1], reason = a[2] }
        return false, 'cis_test_providers never drops a player'
    end),
}

-- --------------------------------------------------------------- dataProbe
-- Kept registrable for compatibility (the plan's 3.8 removes its USE, not the
-- slot), so the fakes take it: a slot nobody holds is a slot whose absence the
-- harness would report as an environment fault rather than a test result.
local dataProbe = {
    hasRows = method('dataProbe', 'hasRows', function() return false end),
}

-- --------------------------------------------------------------- migration
local migration = {
    plan = method('migration', 'plan', function() return { { id = '001', statements = {} } } end),
    apply = method('migration', 'apply', function() return true end),
    sources = method('migration', 'sources', function() return {} end),
}

-- ------------------------------------------------------------- registration
local PROVIDERS = {
    framework = framework,
    database = database,
    target = target,
    inventory = inventory,
    inventoryProvider = inventoryProvider,
    doors = doors,
    discord = discord,
    security = security,
    dataProbe = dataProbe,
    migration = migration,
}

-- One export per slot, so a failure names the slot. Registering them all under
-- one export would mean every provider is the same function object and the
-- first registration to resolve would answer for all of them.
for slot, table_ in pairs(PROVIDERS) do
    exports('Provider_' .. slot, function(_self)
        return table_
    end)
end

-- Claimed after cis_libs has finished starting, otherwise RegisterCapability is
-- refused for a resource that has not started yet -- a partial restart orders
-- this before cis_libs is ready.
CreateThread(function()
    local waited = 0
    while GetResourceState('cis_libs') ~= 'started' and waited < 100 do
        Wait(100)
        waited = waited + 100
    end
    if GetResourceState('cis_libs') ~= 'started' then
        print('[cis_test_providers] cis_libs never started; no slot was claimed')
        return
    end

    local claimed, refused = {}, {}
    for slot in pairs(PROVIDERS) do
        local ok, why = exports['cis_libs']:RegisterCapability(slot, 'cis_test_providers:Provider_' .. slot)
        if ok then
            claimed[#claimed + 1] = slot
        else
            refused[#refused + 1] = ('%s (%s)'):format(slot, tostring(why))
        end
    end
    table.sort(claimed)
    table.sort(refused)
    print(('[cis_test_providers] claimed %d slot(s): %s'):format(#claimed, table.concat(claimed, ', ')))
    if #refused > 0 then
        -- Loudly, because the plan's preflight refuses to run when any slot is
        -- held by something else, and this is the message that explains why.
        print(('[cis_test_providers] REFUSED %d slot(s): %s'):format(#refused, table.concat(refused, ' | ')))
    end

    -- Release and re-claim, so the lifecycle suites have something real to do.
    --
    -- UnregisterCapability, not the force-override command: this resource OWNS
    -- these slots, so it is allowed to release them, and using the owner-checked
    -- export means a release that fails is cis_libs refusing rather than this
    -- file reaching past its own authority.
    exports('ReleaseSlot', function(slot)
        if type(slot) ~= 'string' then return false, 'slot name required' end
        return exports['cis_libs']:UnregisterCapability(slot)
    end)
    exports('ClaimSlot', function(slot)
        if type(slot) ~= 'string' then return false, 'slot name required' end
        return exports['cis_libs']:RegisterCapability(slot, 'cis_test_providers:Provider_' .. slot)
    end)
end)

-- ------------------------------------------------------------ control plane
-- What the harness reads and writes. Names are deliberately obvious: a test
-- that fails at 2am is read by whoever is on call, not by whoever wrote it.

exports('GetCalls', function(slot, methodName)
    if type(slot) ~= 'string' then return false, 'slot name required' end
    return CisTestRing.GetCalls(slot, methodName)
end)

exports('ResetCalls', function(slot)
    return CisTestRing.ResetCalls(slot)
end)

exports('SetFault', function(slot, methodName, mode)
    if type(slot) ~= 'string' or type(methodName) ~= 'string' then
        return false, 'slot and method names required'
    end
    local ok, err = pcall(CisTestRing.SetFault, slot, methodName, mode)
    if not ok then return false, tostring(err) end
    return true
end)

exports('ClearFaults', function(slot)
    CisTestRing.ClearFaults(slot)
    return true
end)

-- Seeded fixtures. A test writes these rather than poking a field on another
-- resource, so every input the fakes have is named in one place.
exports('SetDbRows', function(rows)
    CisTestRing.dbRows = rows
    return true
end)

exports('SetInventory', function(t)
    CisTestRing.inventory = t or {}
    return true
end)

exports('GetDrops', function() return CisTestRing.drops end)
exports('GetDiscord', function() return CisTestRing.discord end)
exports('GetTransactions', function() return CisTestRing.dbTransactions end)