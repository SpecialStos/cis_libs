-- Capability registry.

CisRegistry = {}

-- The capability slots, and the contract each one answers to.
CisRegistry.SLOTS = {
    -- Framework slot. Provider supplies the normalised API.
    framework = {
        get = 'CisCoreFramework() -> the normalized API table',
        NormalizedPlayer = 'NormalizedPlayer(src) -> { id, name, job, identifier, money, metadata }. Server only',
        Notify = 'Notify(src, message, kind) -> nil. Server only',
        ShowNotification = 'ShowNotification(message, kind) -> nil. Client only',
        IsLoaded = 'IsLoaded() -> boolean',
        HasPermission = 'HasPermission(src, permission) -> boolean',
        GetPlayerJob = 'GetPlayerJob(src) -> job|nil. Server only',
    },
    -- SQL. Query / Single / Scalar / Insert / Update / Transaction, all yielding and
    database = {
        query = 'Query(sql, params) -> rows',
        single = 'Single(sql, params) -> row|nil',
        scalar = 'Scalar(sql, params) -> cell',
        insert = 'Insert(sql, params) -> id',
        update = 'Update(sql, params) -> affected',
        transaction = 'Transaction(queries) -> ok, err',
        ready = 'IsReady() -> boolean',
    },
    -- Target slot. create / remove / update / exists / available.
    target = {
        available = 'Available() -> boolean',
        create = 'Create(spec) -> ok, reason',
        remove = 'Remove(name, spec, isPed) -> ok, reason',
        exists = 'Exists(name) -> boolean',
        named = 'name() -> string|nil',
    },
    -- The inventory SERVICE: name -> amount normalisation, framework fallback, and the
    inventory = {
        count = 'Count(src, item) -> number. On the client: Count(item)',
        add = 'Add(src, item, amount, metadata) -> boolean. Server only',
        remove = 'Remove(src, item, amount) -> boolean. Server only',
        has = 'Has(src, item, amount) -> boolean. On the client: Has(item, amount)',
        snapshot = 'Snapshot(src) -> { [item] = count }',
    },
    -- The third-party inventory ADAPTER behind the service.
    inventoryProvider = {
        name = 'Name() -> string',
        available = 'Available() -> boolean',
        count = 'Count(src, item) -> number|nil',
        add = 'Add(src, item, amount, metadata) -> boolean',
        remove = 'Remove(src, item, amount) -> boolean',
    },
    -- Doors, keys and access. Scoped credentials are a product; the boundary that
    doors = {
        state = 'GetDoorState(doorId) -> boolean|nil',
        lock = 'LockDoors(identifier) -> number',
        unlock = 'UnlockDoors(identifier) -> number',
        add = 'AddDoorToSystem(doorData, internal) -> boolean',
        addGroup = 'AddDoorGroup(groupData) -> boolean',
        breakDoor = 'BreakDoor(identifier) -> nil',
        fixDoor = 'FixDoor(identifier) -> nil',
        all = 'GetAllDoorData() -> { doors, groups }',
        -- Whether this install has EVER persisted anything.
        persisted = 'IsPersisted() -> boolean',
    },
    -- The CLIENT half of the same thing, which is a genuinely different problem: the
    doorsClient = {
        add = 'AddDoorToSystem(data) -> boolean',
        addGroup = 'AddDoorGroup(data) -> boolean',
        closest = 'GetClosestDoor() -> { id, distance, door }|nil',
        state = 'GetDoorState(doorId) -> boolean|nil',
        -- ADDITIVE (3.14). The client asked for a lock state by firing
        RequestState = 'RequestState(identifier, lock) -> any',
    },
    -- Discord webhooks and any other outbound sink.
    discord = {
        log = 'Log(webhookUrl, title, message, color, ping) -> nil',
        depth = 'QueueDepth() -> number',
    },
    -- The function that actually drops a cheating player.
    security = {
        drop = 'Drop(src, reason) -> nil',
    },
    -- Whether this server has ever stored anything, used to decide install posture.
    dataProbe = {
        hasRows = 'HasRows() -> boolean|nil',
    },
    -- cis_migrate. A single dispatcher taking the action as its first argument, so it
    migration = {
        plan = 'plan(sourceName, options) -> report|nil, err',
        apply = "apply(sourceName, { confirm = 'APPLY' }) -> result|nil, err",
        sources = 'sources() -> { name }',
    },
    -- cis_libs ships no NUI.
    ui = {
        Notify = 'Notify(message, kind) -> boolean, string. Client only',
        TextUIShow = 'TextUIShow(text, opts) -> boolean, string. Client only',
        TextUIHide = 'TextUIHide() -> boolean, string. Client only',
        TextUIIsOpen = 'TextUIIsOpen() -> boolean. Client only',
        Progress = 'Progress(opts) -> boolean, string. Client only',
        Confirm = 'Confirm(opts) -> any, string. Client only',
        Input = 'Input(opts) -> any, string. Client only',
    },
}

-- The provider-side function name a slot method answers to: the leading identifier of
local function declaredName(slot, method)
    local spec = CisRegistry.SLOTS[slot] and CisRegistry.SLOTS[slot][method]
    return type(spec) == 'string' and spec:match('^([%a_][%w_]*)') or nil
end

-- WHO CALLED, as the server itself reports it.
local function invokingResource()
    if type(GetInvokingResource) ~= 'function' then
        return nil
    end
    local ok, name = pcall(GetInvokingResource)
    if not ok then
        return nil
    end
    return type(name) == 'string' and name ~= '' and name or nil
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

-- A callable that arrived as a return value across the boundary reports type() ==
local function isCallable(v)
    if type(v) == 'function' then
        return true
    end
    return type(v) == 'table' and v.__cfx_functionReference ~= nil
end

--- Check a provider's DECLARED CONTRACT, if it declared one.
--- @param slot string      one of CisRegistry.SLOTS
--- @param contract table|nil `{ api = number, requiredMethods = { string } }`
--- @return boolean ok, string reason
local function sortedMethodNames(slot)
    local names = {}
    local declared = CisRegistry.SLOTS[slot] or {}
    for method in pairs(declared) do
        names[#names + 1] = method
    end
    table.sort(names)
    return names
end

local function checkContract(slot, contract)
    if contract == nil then
        return true
    end
    -- A STRING is the old unused third argument (api.lua documented it as a version
    if type(contract) == 'string' then
        return true
    end
    if type(contract) ~= 'table' then
        return false, ('contract must be a table, got %s'):format(type(contract))
    end
    if contract.api ~= nil and type(contract.api) ~= 'number' then
        return false, ('contract.api must be a number, got %s'):format(type(contract.api))
    end
    if contract.requiredMethods ~= nil and type(contract.requiredMethods) ~= 'table' then
        return false, ('contract.requiredMethods must be a table, got %s')
            :format(type(contract.requiredMethods))
    end

    local declared = CisRegistry.SLOTS[slot] or {}
    if contract.requiredMethods then
        for _, method in ipairs(contract.requiredMethods) do
            if type(method) ~= 'string' then
                return false, ('contract.requiredMethods entries must be strings, got %s')
                    :format(type(method))
            end
            -- A method the SLOT does not declare cannot be called on this slot, so
            if not declared[method] and not declaredName(slot, method) then
                return false, ('capability %q has no method %q; declared methods are %s')
                    :format(slot, method, table.concat(sortedMethodNames(slot), ', '))
            end
        end
    end
    return true
end

--- The contract a slot's provider declared, for diagnostics and the boot report.
function CisRegistry.contract(slot)
    local held = slots[slot]
    return held and held.contract or nil
end

-- T9. One place that turns a slot change into an event, so `register`, `unregister`,
--- Register a provider for a slot.
--- @param slot string     one of CisRegistry.SLOTS
--- @param provider string A "resource:Export" string, or a callable when the
--- @param contract table|nil `{ api = number, requiredMethods = { string } }`
--- @return boolean ok, string reason
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

function CisRegistry.register(slot, provider, contract)
    if type(slot) ~= 'string' or not CisRegistry.SLOTS[slot] then
        return false, ('unknown capability slot %q'):format(tostring(slot))
    end
    -- The declared contract, checked BEFORE anything is mutated.
    local contractOk, contractReason = checkContract(slot, contract)
    if not contractOk then
        return false, contractReason
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

    -- A bare callable is cis_libs registering its own capability, so it is owned by
    local owner = invokingResource()
        or (type(provider) == 'table' and provider.resource)
        or 'cis_libs'
    local held = slots[slot]
    if held and held.owner ~= owner then
        return false, ('capability %q is already registered by %s'):format(slot, held.owner)
    end
    local wasResolved = held ~= nil
    -- A re-registration by the OWNER (the onResourceStart-after-restart case) that
    local recorded = contract or (held and held.contract) or nil
    slots[slot] = { owner = owner, ref = provider, contract = recorded }
    -- T9. Announced HERE, at the one place a slot changes hands, rather than by each
    CisRegistry.announce(slot, 'registered', wasResolved and held.owner or nil, owner)
    return true
end

--- Wait for a slot to be filled, so start order stops mattering.
--- @param slot string  a slot name from CisRegistry.SLOTS
--- @param timeoutMs number|nil  default 30000; 0 polls once and answers now
--- @return boolean  true when the slot resolved within the timeout
--- @return string|nil,string  the owner when it resolved, or nil and a reason --
function CisRegistry.wait(slot, timeoutMs)
    if type(slot) ~= 'string' or not CisRegistry.SLOTS[slot] then
        return false, ('unknown capability slot %q'):format(tostring(slot))
    end
    local deadline = nowMs() + (timeoutMs == nil and 30000 or tonumber(timeoutMs) or 30000)
    -- TICK_MS is a local constant rather than a literal so the waiter's cost is one
    while not CisRegistry.has(slot) do
        if nowMs() >= deadline then
            return false, ('capability %q was not provided within %dms: %s'):format(
                slot, timeoutMs or 30000, CisRegistry.missing(slot))
        end
        Wait(TICK_MS)
    end
    return true, CisRegistry.owner(slot)
end

--- Release a slot. Only the owner may release it, or cis_libs itself at shutdown.
function CisRegistry.unregister(slot, resource)
    local held = slots[slot]
    if not held then
        return false
    end
    if resource and held.owner ~= resource then
        return false
    end
    slots[slot] = nil
    -- T9: a release is announced too, and it is announced with the owner that held the
    CisRegistry.announce(slot, 'unregistered', held.owner, nil)
    return true
end

--- The callable for a slot, or nil.
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
        -- READING THE EXPORT IS GUARDED, BOTH STEPS, because `exports[res][name]`
        local okTarget, target = pcall(function()
            return exports[ref.resource]
        end)
        local fn
        if okTarget and target then
            local okFn, value = pcall(function()
                return target[ref.export]
            end)
            if okFn then
                fn = value
            end
        end
        -- MEASURED, not inferred: `exports[res][name]` is an UNBOUND method and
        held.resolved = isCallable(fn) and function(...)
            return fn(target, ...)
        end or nil
        if held.resolved then
            -- Record that this provider came across the boundary, so `call` knows to
            held.crossBoundary = true
        end
        return held.resolved
    end
    held.resolved = ref
    return ref
end

--- Forget the cached resolution.
function CisRegistry.invalidate(slot)
    local held = slots[slot]
    if held then
        held.resolved = nil
        -- The method table belongs to the provider that handed it back.
        held.methods = nil
        held.lookups = nil
    end
end

--- Release every slot a resource owns.
function CisRegistry.releaseOwner(resource)
    local released = {}
    for slot, held in pairs(slots) do
        local ref = held.ref
        local hostsIt = type(ref) == 'table' and ref.resource == resource
        if held.owner == resource or hostsIt then
            slots[slot] = nil
            released[#released + 1] = slot
            -- T9: announced per slot, inside the loop, because a consumer is waiting on
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

--- The provider's METHOD TABLE for a slot: fetched, and cached like a resolution, or
--- @return table|nil  the method table, or nil when the slot is empty or the
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
        -- A dispatcher has no method table to hand out.
        held.methods = false
        return nil
    end
    if type(value) ~= 'table' then
        return nil
    end
    held.methods = value
    return value
end

-- `CisRegistry.SLOTS` is a table of method names per slot -- a database provider
--- Call a capability. Returns true plus the provider's results, or false plus a reason
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

--- The declared methods of a slot that the cached provider table cannot serve in this
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
    -- A method name is REQUIRED, and its absence is a refusal rather than an exception.
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
            -- First call for this provider: take the table it hands back.
            local ok, value = pcall(provider)
            if not ok then
                return false, tostring(value)
            end
            if isCallable(value) then
                -- The export answered with a FUNCTION rather than a method table, so it
                methods = false
                held.methods = false
            elseif type(value) == 'table' then
                -- The method table. Every table lands here, including one that is ALSO
                methods = value
                held.methods = value
            else
                -- NIL. AMBIGUOUS, AND DELIBERATELY NOT CACHED.
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

--- Call a capability and return only its first result, for the very common case where
function CisRegistry.value(slot, ...)
    local ok, a = CisRegistry.call(slot, ...)
    if not ok then
        return nil
    end
    return a
end

--- Every slot, resolved or not, for the debug command.
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

--- Count of registered slots. Cheap enough for the boot report, and it turns "the
function CisRegistry.registered()
    local n = 0
    for _ in pairs(slots) do
        n = n + 1
    end
    return n
end
