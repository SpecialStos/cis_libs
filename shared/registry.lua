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
        remove = 'Remove(name, spec, isPed) -> ok, reason',
        exists = 'Exists(name) -> boolean',
        named = 'name() -> string|nil',
    },
    -- The inventory SERVICE: name -> amount normalisation, framework fallback,
    -- and the client snapshot push. Not a third-party adapter -- see
    -- inventoryProvider for that.
    inventory = {
        count = 'Count(src, item) -> number. On the client: Count(item)',
        add = 'Add(src, item, amount, metadata) -> boolean. Server only',
        remove = 'Remove(src, item, amount) -> boolean. Server only',
        has = 'Has(src, item, amount) -> boolean. On the client: Has(item, amount)',
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
        add = 'AddDoorToSystem(data) -> boolean',
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
    -- cis_migrate. A single dispatcher taking the action as its first argument,
    -- so it is called through the dispatcher path in `call`.
    migration = {
        plan = 'plan(sourceName, options) -> report|nil, err',
        apply = "apply(sourceName, { confirm = 'APPLY' }) -> result|nil, err",
        sources = 'sources() -> { name }',
    },
}

-- The provider-side function name a slot method answers to: the leading
-- identifier of its declared signature. `inventory.count` is declared
-- 'Count(src, item)', so a provider exporting either `count` or `Count` serves
-- it. Products in this platform use both conventions, and a dispatch that only
-- tried the key silently answered every call with the fallback value.
local function declaredName(slot, method)
    local spec = CisRegistry.SLOTS[slot] and CisRegistry.SLOTS[slot][method]
    return type(spec) == 'string' and spec:match('^([%a_][%w_]*)') or nil
end

-- The realm a declared method is limited to, read off its contract string.
local function declaredRealm(spec)
    if spec:find('Server only', 1, true) then return 'server' end
    if spec:find('Client only', 1, true) then return 'client' end
    return nil
end

local function currentRealm()
    if type(IsDuplicityVersion) ~= 'function' then
        return nil
    end
    return IsDuplicityVersion() and 'server' or 'client'
end

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
-- T9. One place that turns a slot change into an event, so `register`,
-- `unregister`, `invalidate` and `releaseOwner` cannot drift apart and so a
-- future path that adds a fifth way to change a slot is forced through here by
-- the fact that nothing else announces.
--
-- `TriggerEvent` is guarded rather than assumed: this file is shared with the
-- CLIENT, where `TriggerEvent` exists but `TriggerServerEvent` does not, and a
-- shared file that raised on the missing one would take the whole library down.
-- The event name is written out HERE rather than held in a local, because
-- tools/validate-api.js checks that every event declared in api.lua is
-- referenced by a source file. A constant holding the only copy of the string
-- would make the declaration a lie the validator is right to reject.
local TICK_MS = 50

local function nowMs()
    if GetGameTimer then
        return GetGameTimer()
    end
    return math.floor(os.clock() * 1000)
end

function CisRegistry.announce(slot, action, previousOwner, owner)
    if not TriggerEvent then
        return
    end
    TriggerEvent('cis_libs:capabilityChanged', {
        slot = slot,
        action = action,
        owner = owner,
        previousOwner = previousOwner,
        resolved = slots[slot] ~= nil,
    })
end

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
    local wasResolved = held ~= nil
    slots[slot] = { owner = owner, ref = provider }
    -- T9. Announced HERE, at the one place a slot changes hands, rather than by
    -- each caller announcing its own registration. A caller that forgets is
    -- then the only possible way to miss the event, and the waiters below stop
    -- being the thing that decides when start order matters.
    CisRegistry.announce(slot, 'registered', wasResolved and held.owner or nil, owner)
    return true
end

--- Wait for a slot to be filled, so start order stops mattering.
---
--- `Cis.db.*` used to answer nil during boot and the caller had to poll. This is
--- the same idea as the ready gate, one slot narrower: wait up to `timeoutMs`
--- for `slot` to resolve, and answer whether it did.
---
--- @param slot string  a slot name from CisRegistry.SLOTS
--- @param timeoutMs number|nil  default 30000; 0 polls once and answers now
--- @return boolean  true when the slot resolved within the timeout
--- @return string|nil,string  the owner when it resolved, or nil and a reason --
---   which names the slot, because "no provider registered for database" is the
---   difference between "nobody installed one" and "it is named wrong".
function CisRegistry.wait(slot, timeoutMs)
    if type(slot) ~= 'string' or not CisRegistry.SLOTS[slot] then
        return false, ('unknown capability slot %q'):format(tostring(slot))
    end
    local deadline = nowMs() + (timeoutMs == nil and 30000 or tonumber(timeoutMs) or 30000)
    -- TICK_MS is a local constant rather than a literal so the waiter's cost is
    -- one readable comparison, and so changing the resolution is a one-line edit
    -- rather than a hunt through three literals.
    while not CisRegistry.has(slot) do
        if nowMs() >= deadline then
            return false, ('capability %q was not provided within %dms: %s'):format(
                slot, timeoutMs or 30000, CisRegistry.missing(slot))
        end
        Wait(TICK_MS)
    end
    return true, CisRegistry.owner(slot)
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
    -- T9: a release is announced too, and it is announced with the owner that
    -- held the slot. A consumer waiting on a capability learns it is GONE rather
    -- than waiting out its timeout for something that will not arrive -- which
    -- is the difference between a re-register that resolves in 2s and one that
    -- takes the full timeout and reports the wrong reason.
    CisRegistry.announce(slot, 'unregistered', held.owner, nil)
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
        if held.resolved then
            -- Record that this provider came across the boundary, so `call`
            -- knows to dispatch into the table it hands back. See `call` for why
            -- the two provider shapes must not be confused.
            held.crossBoundary = true
        end
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
        -- The method table belongs to the provider that handed it back. A
        -- restarted resource exports new closures over new upvalues, so keeping
        -- the old table would call the previous instance.
        held.methods = nil
        held.lookups = nil
    end
end

--- Release every slot a resource owns. Called when that resource stops: its
--- exports are gone, so a held reference would answer every call with an error
--- about a missing export instead of the honest "no provider registered", and
--- `has` would keep telling callers the capability is installed.
function CisRegistry.releaseOwner(resource)
    local released = {}
    for slot, held in pairs(slots) do
        if held.owner == resource then
            slots[slot] = nil
            released[#released + 1] = slot
            -- T9: announced per slot, inside the loop, because a consumer is
            -- waiting on ONE slot. One event naming the whole set would leave
            -- every waiter to search it, and a waiter that guessed wrong would
            -- wait out its full timeout.
            CisRegistry.announce(slot, 'unregistered', held.owner, nil)
        end
    end
    table.sort(released)
    return released
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

--- The provider's METHOD TABLE for a slot: fetched, and cached like a
--- resolution, or nil.
---
--- `resolve` hands back the provider's export -- a callable, or a callable table
--- once it has crossed the exports boundary. That is the right answer for
--- `call`, which dispatches by method name, and the WRONG answer for a caller
--- that wants to reach a method directly, because the export is not the table the
--- methods live in. `exports['cis_libs']:GetFramework()` did exactly that and
--- returned a function where every caller then did `fw.GetPlayer(src)` and got
--- nil -- so cis_core's inventory counts read 0 for every item on the server.
---
--- `missing` deliberately never fetches the table, because for some providers
--- that blocks for seconds and `missing` is called from diagnostics. This DOES
--- fetch it, which is why it is not what the debug command uses.
---
--- @return table|nil  the method table, or nil when the slot is empty or the
---         provider answered with a dispatcher rather than a table
function CisRegistry.methods(slot)
    local held = slots[slot]
    if not held then
        return nil
    end
    local cached = held.methods
    if cached ~= nil then
        return cached or nil
    end
    local provider = CisRegistry.resolve(slot)
    if not provider then
        return nil
    end
    local ok, value = pcall(provider)
    if not ok then
        return nil
    end
    if isCallable(value) then
        -- A dispatcher has no method table to hand out. Recorded so the next
        -- caller does not pay for the fetch again -- and, unlike the nil case,
        -- this verdict IS definitive.
        held.methods = false
        return nil
    end
    if type(value) ~= 'table' then
        return nil
    end
    held.methods = value
    return value
end

--- Call a capability. Returns true plus the provider's results, or false plus a
--- reason that is safe to show an operator.
---
--- THE METHOD NAME IS THE FIRST ARGUMENT, AND IT IS DISPATCHED
---
-- `CisRegistry.SLOTS` is a table of method names per slot -- a database provider
-- answers `query`, `single`, `update`, `transaction` -- so a call is
-- `call(slot, 'query', sql, params)` and the slot's provider has to be indexed
-- by that name. Every provider in the platform registers in that shape: one
-- export that RETURNS a table of methods, handed back across the boundary as
-- callable references.
--
-- The other shape is a provider cis_libs registered as a bare callable, which is
-- already the implementation and takes the method name as its first argument.
-- `resolve` tags the cross-boundary wrapper so the two are never confused --
-- without the tag the result of a callable provider is indistinguishable from a
-- method table, and a provider that returns rows would be indexed as though the
-- rows were its methods.
--
--- NEVER THROWS. A capability provider is another resource's code, and its
--- failure is not this library's to propagate into a caller's thread. The pcall
--- below is the boundary that keeps a bug in a bridge adapter from becoming a
--- stack trace in somebody else's script.
--- Find the function a method table serves `method` with. Tried in order: the
--- slot's own key (`count`), the provider-side name its contract declares
--- (`Count`), and the key with its first letter flipped in case. The answer is
--- cached on the held entry, so the lookup is paid once per method per provider
--- instance and `invalidate` discards it along with the table.
function CisRegistry.lookup(held, slot, methods, method)
    local cache = held.lookups
    if not cache then
        cache = {}
        held.lookups = cache
    end
    local key = cache[method]
    if key == nil then
        key = false
        if type(method) == 'string' then
            local declared = declaredName(slot, method)
            local flipped = method:sub(1, 1):upper() == method:sub(1, 1)
                and method:sub(1, 1):lower() .. method:sub(2)
                or method:sub(1, 1):upper() .. method:sub(2)
            for _, candidate in ipairs({ method, declared, flipped }) do
                if candidate and isCallable(methods[candidate]) then
                    key = candidate
                    break
                end
            end
        end
        cache[method] = key
    end
    return key and methods[key] or nil
end

--- The declared methods of a slot that the cached provider table cannot
--- serve in this realm, sorted. nil when there is nothing to judge yet: no
--- provider, a dispatcher-shaped provider, or a table not fetched so far.
--- Never fetches the table itself -- for some providers that blocks for
--- seconds, and this is called from diagnostics.
function CisRegistry.missing(slot)
    local held = slots[slot]
    local methods = held and held.methods
    local declared = CisRegistry.SLOTS[slot]
    if type(methods) ~= 'table' or not declared then
        return nil
    end
    local realm = currentRealm()
    local out = {}
    for method, spec in pairs(declared) do
        local limited = declaredRealm(spec)
        if (not limited or not realm or limited == realm)
            and not CisRegistry.lookup(held, slot, methods, method) then
            out[#out + 1] = method
        end
    end
    table.sort(out)
    return out
end

function CisRegistry.call(slot, ...)
    -- A method name is REQUIRED, and its absence is a refusal rather than an
    -- exception. `call('database')` used to walk into the method lookup and hit
    -- `method:sub(1, 1)` on a nil, so a caller that built the name at runtime --
    -- `call('database', config.queryName)`, where the name came from a
    -- user-editable config -- raised inside whatever thread called it. The
    -- contract everywhere else in this file is a refusal with a reason; this is
    -- the one place it was not, and it is the place a caller is most likely to
    -- reach by accident.
    if select('#', ...) < 1 or type((...)) ~= 'string' then
        return false, 'method name required'
    end
    local held = slots[slot]
    local provider = held and held.resolved or CisRegistry.resolve(slot)
    if not provider then
        return false, ('no provider registered for %q'):format(tostring(slot))
    end
    local method = ...

    if held and held.crossBoundary then
        local methods = held.methods
        if methods == nil then
            -- First call for this provider: take the table it hands back. Every
            -- provider in the platform exports exactly this, and asking for it
            -- with no arguments is asking for it the way it expects to be asked.
            local ok, value = pcall(provider)
            if not ok then
                return false, tostring(value)
            end
            if isCallable(value) then
                -- The export answered with a FUNCTION rather than a method
                -- table, so it is a dispatcher that takes the method name as its
                -- first argument -- cis_migrate's shape. Record that ONCE
                -- instead of asking again on every call.
                --
                -- This branch is checked BEFORE the method-table branch on
                -- purpose, and the order is not interchangeable. A function that
                -- arrived across the exports boundary is a TABLE carrying a
                -- `__cfx_functionReference`, so `isCallable` and "is a table"
                -- are both true of it; testing the table first would index a
                -- dispatcher's reference table for method names and find none.
                methods = false
                held.methods = false
            elseif type(value) == 'table' then
                methods = value
                held.methods = value
            elseif type(value) == 'table' and not isCallable(value) then
                methods = value
                held.methods = value
            elseif isCallable(value) then
                -- The export answered with a FUNCTION rather than a method
                -- table, so it is a dispatcher that takes the method name as its
                -- first argument -- cis_migrate's shape. That verdict is
                -- definitive and is cached, so the export is asked once.
                methods = false
                held.methods = false
            else
                -- NIL. AMBIGUOUS, AND DELIBERATELY NOT CACHED.
                --
                -- Two providers legitimately answer nil here. A dispatcher asked
                -- for no action may answer nil (cis_migrate does). And a method
                -- table export asked before its resource finished registering
                -- answers nil too -- which is the normal state of the first call
                -- during a partial restart.
                --
                -- The old code folded both into `held.methods = false`, and
                -- `false` means "confirmed dispatcher": a provider that had not
                -- finished registering was written off as a dispatcher FOREVER.
                -- Every later call put the method name at an export that takes
                -- no arguments, and the capability answered nil or an error for
                -- the lifetime of the process.
                --
                -- So this call falls through to the dispatcher path -- which is
                -- right for a dispatcher and harmless for a provider that is not
                -- ready -- and caches NOTHING. The next call asks again, and the
                -- first one after the provider is ready dispatches correctly.
                methods = false
            end
        end
        if methods then
            local fn = CisRegistry.lookup(held, slot, methods, method)
            if not isCallable(fn) then
                return false, ('provider for %q has no method %q'):format(
                    tostring(slot), tostring(method))
            end
            local results = table.pack(pcall(fn, select(2, ...)))
            if not results[1] then
                return false, tostring(results[2])
            end
            return true, table.unpack(results, 2, results.n)
        end
    end

    local results = table.pack(pcall(provider, ...))
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
            missing = CisRegistry.missing(slot),
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
