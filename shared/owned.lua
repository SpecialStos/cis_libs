-- Ownership ledger: which resource asked for which record, and what has to happen to

CisOwned = {}

-- A function handed over by another resource crosses the exports boundary as a
-- callable table carrying `__cfx_functionReference`, not as a Lua function.
-- Both are callable; nothing else is. Every API that takes a handler uses this.
--- @param v any
--- @return boolean
function CisCallable(v)
    if type(v) == 'function' then
        return true
    end
    return type(v) == 'table' and rawget(v, '__cfx_functionReference') ~= nil
end

-- A REAL STOP, OR A FORGED ONE. `onResourceStop` is an ordinary event, so any
-- client resource can TriggerEvent('onResourceStop', 'victim') and have the
-- victim's zones, keybinds, callbacks and capability slots released. Checking
-- GetResourceState(victim) == 'stopping' does NOT tell them apart: FiveM fires
-- the event from Resource::Stop while the state is still Started, and only
-- sets Stopped after (citizen-resources-core Resource.cpp; nothing sets
-- Stopping). What differs is the caller. GetInvokingResource() is the script
-- runtime below the handler's own on the runtime stack (ScriptHost.cpp): the
-- forger's, for a TriggerEvent from a script, and nil for the stop the engine
-- itself fires on a client. A resource "stopping" itself only hurts itself.
-- On the SERVER a real restart can come from a script (txAdmin's monitor runs
-- `restart` from its own runtime), so the caller alone cannot decide there and
-- this answers true; server handlers go through CisWhenRealStop below.
--- @param resource string  the resource named by the event
--- @return boolean
function CisRealStop(resource)
    if IsDuplicityVersion() then
        return true
    end
    local by = GetInvokingResource()
    return by == nil or by == resource
end

-- Whether a server resource may stop resources: the ACE `stop` itself checks.
local function mayStopResources(by)
    if type(IsPrincipalAceAllowed) ~= 'function' then
        return false
    end
    local ok, allowed = pcall(IsPrincipalAceAllowed, 'resource.' .. by, 'command.stop')
    return ok and allowed == true
end

-- A FORGED STOP ON THE SERVER. Any server resource could TriggerEvent(
-- 'onResourceStop', 'victim') and have the victim's capability slots, net
-- handlers, callbacks, commands and records released -- then register into the
-- slot the victim held. A stop counts AT ONCE when the engine fired it (no
-- invoker), the resource stopped itself, cis_libs fired it, or the invoker holds
-- command.stop (txAdmin's monitor restarting a resource). Any other invoker is
-- checked ONE TICK LATER: a real StopResource has finished by then and the
-- resource is no longer 'started'; a forged event leaves it 'started' and is
-- ignored. LIMITATION: an untrusted script that calls StopResource and then
-- StartResource in the same tick leaves the old instance's records (keyed by the
-- same name) in place until that resource's next stop.
-- On the client this is CisRealStop: run now or not at all.
--- @param resource string  the resource named by the event
--- @param fn function  called as fn(resource) for a real stop
function CisWhenRealStop(resource, fn)
    if not IsDuplicityVersion() then
        if CisRealStop(resource) then
            fn(resource)
        end
        return
    end
    local by = GetInvokingResource()
    if by == nil or by == resource or by == GetCurrentResourceName() or mayStopResources(by) then
        fn(resource)
        return
    end
    SetTimeout(0, function()
        if GetResourceState(resource) ~= 'started' then
            fn(resource)
        end
    end)
end

--- AddEventHandler('onResourceStop', fn), with a forged stop filtered out.
--- @param fn function  called as fn(resource)
function CisOnResourceStop(fn)
    AddEventHandler('onResourceStop', function(resource)
        CisWhenRealStop(resource, fn)
    end)
end

--- @return table
function CisOwned.new()
    return {
        -- kind -> id -> owner. The direction every hot path asks: "who owns THIS
        byKind = {},
        -- owner -> { [kind] = { [id] = true } }.
        byOwner = {},
    }
end

--- @param ledger table  from CisOwned.new()
--- @param owner string|nil  the invoking resource; nil or 'cis_libs' means cis_libs itself
--- @param kind string  what sort of record this is ('zone', 'target', ...)
--- @param id any  the record's identifier
function CisOwned.track(ledger, owner, kind, id)
    if type(kind) ~= 'string' or id == nil then
        return false
    end
    owner = owner or 'cis_libs'
    local existing = ledger.byKind[kind] and ledger.byKind[kind][id]
    if existing and existing ~= owner then
        CisOwned.forget(ledger, kind, id)
    end
    ledger.byKind[kind] = ledger.byKind[kind] or {}
    ledger.byKind[kind][id] = owner
    ledger.byOwner[owner] = ledger.byOwner[owner] or {}
    ledger.byOwner[owner][kind] = ledger.byOwner[owner][kind] or {}
    ledger.byOwner[owner][kind][id] = true
    return true
end

--- @param ledger table
--- @param kind string
--- @param id any
--- @return boolean  whether there was anything to forget
function CisOwned.forget(ledger, kind, id)
    local bucket = ledger.byKind[kind]
    local owner = bucket and bucket[id]
    if not owner then
        return false
    end
    bucket[id] = nil
    if next(bucket) == nil then
        ledger.byKind[kind] = nil
    end
    local held = ledger.byOwner[owner]
    if held and held[kind] then
        held[kind][id] = nil
        if next(held[kind]) == nil then
            held[kind] = nil
        end
    end
    if held and next(held) == nil then
        ledger.byOwner[owner] = nil
    end
    return true
end

--- @param ledger table
--- @param owner string|nil
--- @return table  { { kind = ..., id = ... }, ... }
function CisOwned.release(ledger, owner)
    local out = {}
    local held = owner and ledger.byOwner[owner]
    if not held then
        return out
    end
    for kind, ids in pairs(held) do
        local list = {}
        for id in pairs(ids) do
            list[#list + 1] = id
        end
        table.sort(list, function(a, b) return tostring(a) < tostring(b) end)
        for i = 1, #list do
            out[#out + 1] = { kind = kind, id = list[i] }
        end
    end
    table.sort(out, function(a, b)
        if a.kind ~= b.kind then return a.kind < b.kind end
        return tostring(a.id) < tostring(b.id)
    end)
    return out
end

--- @param ledger table
--- @param kind string
--- @param id any
--- @param owner string|nil
--- @return boolean
function CisOwned.isHeldBy(ledger, kind, id, owner)
    local bucket = ledger.byKind[kind]
    return bucket ~= nil and bucket[id] == (owner or 'cis_libs')
end

--- @param ledger table
--- @param kind string
--- @param id any
--- @return string|nil
function CisOwned.ownerOf(ledger, kind, id)
    local bucket = ledger.byKind[kind]
    return bucket and bucket[id] or nil
end

--- @param ledger table
--- @return number
function CisOwned.count(ledger)
    local n = 0
    for _, bucket in pairs(ledger.byKind) do
        for _ in pairs(bucket) do
            n = n + 1
        end
    end
    return n
end

--- @param ledger table
function CisOwned.clear(ledger)
    ledger.byKind = {}
    ledger.byOwner = {}
end
