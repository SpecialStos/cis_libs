-- Capability registry.
--
-- cis_libs is the boundary, not the implementation. Everything this library
-- used to do itself -- reach a framework, run a query, drive a target
-- resource, open a door -- it now does by asking whichever resource registered
-- that capability. cis_libs ships with NONE of them registered and is fully
-- functional that way: it owns no table, imports no third-party resource, and
-- answers a call it cannot serve with a refusal and a reason rather than a
-- crash. A server owner can delete cis_core, cis_bridge and cis_keys right now
-- and the library still boots, still serves zones, callbacks, sync and logging,
-- and says out loud exactly which capability went missing.
--
-- WHY A REGISTRY AND NOT `exports['cis_core']` WRITTEN INTO THE CODE
--
-- A library that names its siblings has a hard dependency on all of them, and
-- the entire reason this library is free is that a server owner can throw it
-- away. It cannot throw away something it is wired to. So the dependency
-- points the other way: cis_libs knows the SHAPE of a capability and nothing
-- whatsoever about who provides it, and the products that do provide it come
-- and go without an edit here.
--
-- This is the same argument the roadmap makes about the product split, applied
-- inside one resource. It is also why the registration form is a STRING and not
-- a function -- see `resolve` for the mechanics.

CisRegistry = {}

-- The capability slots, and the contract each one answers to. `self` is what a
-- provider may be registered as when it genuinely lives inside cis_libs; every
-- real provider is a `resource:Export` string, because a function cannot be
-- SENT across the exports boundary.
--
-- Listed as data rather than as a comment so that the debug command can print
-- the full contract, and so a slot that has no implementation cannot be added
-- by accident -- an unknown slot is refused at registration.
CisRegistry.SLOTS = {
    -- ESX / QBCore / qbx_core / standalone. The normalized player object, money,
    -- job, permission and notification surface.
    --
    -- Method names are the abstraction's own, capitalised, and they DIFFER BY
    -- REALM on purpose: the server's is `Notify(src, message, kind)` because a
    -- server can address a player, and the client's is
    -- `ShowNotification(message, kind)` because a client cannot. Forcing them
    -- into one signature would mean one of the two realms is always being
    -- handed an argument that means nothing there.
    framework = {
        get = 'CisCoreFramework() -> the normalized API table',
        NormalizedPlayer = 'NormalizedPlayer(src) -> { id, name, job, identifier, money, metadata }. Server only',
        Notify = 'Notify(src, message, kind) -> nil. Server only',
        ShowNotification = 'ShowNotification(message, kind) -> nil. Client only',
        IsLoaded = 'IsLoaded() -> boolean',
        HasPermission = 'HasPermission(src, permission) -> boolean',
        GetPlayerJob = 'GetPlayerJob(src) -> job|nil. Server only',
    },
    -- SQL. Query / Single / Scalar / Insert / Update / Transaction, all yielding
    -- and returning nil on timeout.
    database = {
        query = 'Query(sql, params) -> rows',
        single = 'Single(sql, params) -> row|nil',
        scalar = 'Scalar(sql, params) -> cell',
        insert = 'Insert(sql, params) -> id',
        update = 'Update(sql, params) -> affected',
        transaction = 'Transaction(queries) -> ok, err',
        ready = 'IsReady() -> boolean',
    },
    -- ox_target / qb-target. create / remove / update / exists / available.
    target = {
        available = 'Available() -> boolean',
        create = 'Create(spec) -> ok, reason',
        remove = 'Remove(name, isPed) -> ok, reason',
        exists = 'Exists(name) -> boolean',
        named = 'ProviderName() -> string|nil',
    },
    -- The inventory SERVICE: name -> amount normalisation, framework fallback,
    -- and the client snapshot push. Not a third-party adapter -- see
    -- inventoryProvider for that.
    inventory = {
        count = 'Count(src, item) -> number',
        add = 'Add(src, item, amount, metadata) -> boolean',
        remove = 'Remove(src, item, amount) -> boolean',
        has = 'Has(src, item, amount) -> boolean',
        snapshot = 'Snapshot(src) -> { [item] = count }',
    },
    -- The third-party inventory ADAPTER behind the service. ox_inventory and its
    -- rivals register here; the service registers `inventory` and reads this.
    inventoryProvider = {
        name = 'Name() -> string',
        available = 'Available() -> boolean',
        count = 'Count(src, item) -> number|nil',
        add = 'Add(src, item, amount, metadata) -> boolean',
        remove = 'Remove(src, item, amount) -> boolean',
    },
    -- Doors, keys and access. Scoped credentials are a product; the boundary
    -- that forwards to it is not.
    doors = {
        state = 'GetDoorState(doorId) -> boolean|nil',
        lock = 'LockDoors(identifier) -> number',
        unlock = 'UnlockDoors(identifier) -> number',
        add = 'AddDoorToSystem(doorData, internal) -> boolean',
        addGroup = 'AddDoorGroup(groupData) -> boolean',
        breakDoor = 'BreakDoor(identifier) -> nil',
        fixDoor = 'FixDoor(identifier) -> nil',
        all = 'GetAllDoorData() -> { doors, groups }',
        -- Whether this install has EVER persisted anything. The security
        -- posture decision in server/security.lua asks this instead of querying
        -- a table: the product owns the table, so the product answers.
        persisted = 'IsPersisted() -> boolean',
    },
    -- The CLIENT half of the same thing, which is a genuinely different problem:
    -- the server owns the doors, and the client only knows the ones the server
    -- has told it about, so these are reads over a pushed snapshot and two
    -- REQUESTS rather than commands.
    doorsClient = {
        add = 'AddDoor(data) -> boolean',
        addGroup = 'AddDoorGroup(data) -> boolean',
        closest = 'GetClosestDoor() -> { id, distance, door }|nil',
        state = 'GetDoorState(doorId) -> boolean|nil',
    },
    -- Discord webhooks and any other outbound sink.
    discord = {
        log = 'Log(webhookUrl, title, message, color, ping) -> nil',
        depth = 'QueueDepth() -> number',
    },
    -- The function that actually drops a cheating player. Separate from the
    -- Security table because a function cannot be SENT across the boundary: the
    -- config carries the boolean, and the code arrives as a capability.
    security = {
        drop = 'Drop(src, reason) -> nil',
    },
    -- Whether this server has ever stored anything, used to decide install
    -- posture. Replaces a query against a table cis_libs no longer owns.
    dataProbe = {
        hasRows = 'HasRows() -> boolean|nil',
    },
}

-- slot -> { owner = resourceName, ref = 'resource:Export' or callable, at = time }
local slots = {}

-- A callable that arrived as a return value across the boundary reports
-- type() == 'table' and carries a __cfx_functionReference. Testing for
-- 'function' is the single most common way to break a cross-resource
-- registration, and it fails silently: the slot simply looks empty.
local function isCallable(v)
    if type(v) == 'function' then
        return true
    end
    return type(v) == 'table' and v.__cfx_functionReference ~= nil
end

--- Register a provider for a slot.
---
--- @param slot string     one of CisRegistry.SLOTS
--- @param provider string A "resource:Export" string, or a callable when the
---                       provider genuinely lives inside cis_libs.
--- @return boolean ok, string reason
---
--- FIRST REGISTRATION WINS. A second resource cannot take a slot that is
--- already held; the attempt is refused and logged with the name of the
--- resource that holds it. This is not a defence against a hostile resource --
--- anything running on your server.cfg already has every permission you have,
--- and pretending otherwise would be theatre. It is a guard against the two
--- failures that actually happen: a bridge that registers twice on a partial
--- restart and silently replaces a working provider, and two products on one
--- server that both believe they own the database. Both surface in the console
--- the moment they happen instead of as a bug report three weeks later.
---
--- Re-registering from the SAME resource is allowed and is not a conflict --
--- that is what a `onResourceStart` handler after a restart looks like.
function CisRegistry.register(slot, provider)
    if type(slot) ~= 'string' or not CisRegistry.SLOTS[slot] then
        return false, ('unknown capability slot %q'):format(tostring(slot))
    end
    if type(provider) == 'string' then
        local resource, exportName = provider:match('^([^:]+):(.+)$')
        if not resource or not exportName then
            return false, ('provider must be "resource:Export", got %q'):format(provider)
        end
        provider = { resource = resource, export = exportName }
    end
    if not isCallable(provider) and type(provider) ~= 'table' then
        return false, 'provider must be a "resource:Export" string or a callable'
    end
    if type(provider) == 'table' and not provider.resource then
        return false, 'provider table needs a resource field'
    end

    -- A bare callable is cis_libs registering its own capability, so it is
    -- owned by cis_libs. Reading `provider.resource` off a function would give
    -- nil, and a nil owner would defeat the conflict check below entirely --
    -- every second registration would look like a first one.
    local owner = type(provider) == 'table' and provider.resource or 'cis_libs'
    local held = slots[slot]
    if held and held.owner ~= owner then
        return false, ('capability %q is already registered by %s'):format(slot, held.owner)
    end
    slots[slot] = { owner = owner, ref = provider }
    return true
end

--- Release a slot. Only the owner may release it, or cis_libs itself at
--- shutdown. Returns true if the slot is now empty.
function CisRegistry.unregister(slot, resource)
    local held = slots[slot]
    if not held then
        return false
    end
    if resource and held.owner ~= resource then
        return false
    end
    slots[slot] = nil
    return true
end

--- The callable for a slot, or nil. Cached after the first successful
--- resolution, because this is on the hot path of every zone and every target.
---
--- Returns a CALLABLE, not necessarily a function. A reference that crossed a
--- boundary is a table that happens to be callable, and every consumer of this
--- must therefore test with `isCallable` semantics rather than `type()`.
function CisRegistry.resolve(slot)
    local held = slots[slot]
    if not held then
        return nil
    end
    if held.resolved ~= nil then
        return held.resolved
    end
    local ref = held.ref
    if type(ref) == 'table' and ref.resource and not isCallable(ref) then
        local target = exports[ref.resource]
        local fn = target and target[ref.export]
        -- MEASURED, not inferred: `exports[res][name]` is an UNBOUND method and
        -- swallows the first real argument. The table has to be passed
        -- explicitly -- which is exactly what the colon form does. Do not
        -- "simplify" this back to `fn(...)`; it shifts every argument one slot
        -- left and raises nothing.
        --
        -- The wrapper is variadic on purpose. An earlier version declared a
        -- leading `self` parameter, which looked correct and was not: the
        -- dispatcher calls the resolved value with the caller's arguments and
        -- nothing else, so that leading parameter bound to the FIRST REAL
        -- ARGUMENT and threw it away. Every provider call silently lost one
        -- argument -- a `Cis.db.query(sql, params)` reached the driver as
        -- `query(sql)` -- and nothing raised, because a Lua function is happy
        -- to be short of arguments and `params` simply arrived nil.
        held.resolved = isCallable(fn) and function(...)
            return fn(target, ...)
        end or nil
        return held.resolved
    end
    held.resolved = ref
    return ref
end

--- Forget the cached resolution. Called when a provider's resource stops, and
--- by the debug command. Cheap: resolution happens again on the next call.
function CisRegistry.invalidate(slot)
    local held = slots[slot]
    if held then
        held.resolved = nil
    end
end

--- Is anything registered for this slot?
function CisRegistry.has(slot)
    return slots[slot] ~= nil
end

--- Who owns this slot?
function CisRegistry.owner(slot)
    local held = slots[slot]
    return held and held.owner or nil
end

--- Call a capability. Returns true plus the provider's results, or false plus a
--- reason that is safe to show an operator.
---
--- NEVER THROWS. A capability provider is another resource's code, and its
--- failure is not this library's to propagate into a caller's thread. The pcall
--- below is the boundary that keeps a bug in a bridge adapter from becoming a
--- stack trace in somebody else's script.
function CisRegistry.call(slot, ...)
    local fn = CisRegistry.resolve(slot)
    if not fn then
        return false, ('no provider registered for %q'):format(tostring(slot))
    end
    local results = table.pack(pcall(fn, ...))
    if not results[1] then
        return false, tostring(results[2])
    end
    return true, table.unpack(results, 2, results.n)
end

--- Call a capability and return only its first result, for the very common
--- case where the caller does not care whether it worked and just wants a
--- value. An unresolvable slot yields nil rather than false, so `if not x` is
--- the only test a caller needs.
function CisRegistry.value(slot, ...)
    local ok, a = CisRegistry.call(slot, ...)
    if not ok then
        return nil
    end
    return a
end

--- Every slot, resolved or not, for the debug command. This is the one place
--- that can see the whole graph, which makes it the one place worth having.
function CisRegistry.snapshot()
    local out = {}
    for slot in pairs(CisRegistry.SLOTS) do
        out[slot] = {
            owner = slots[slot] and slots[slot].owner or nil,
            resolved = CisRegistry.resolve(slot) ~= nil,
        }
    end
    return out
end

--- Count of registered slots. Cheap enough for the boot report, and it turns
--- "the platform is not working" into "four of six capabilities are missing",
--- which is a support answer rather than a support thread.
function CisRegistry.registered()
    local n = 0
    for _ in pairs(slots) do
        n = n + 1
    end
    return n
end
