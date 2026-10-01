-- Ownership ledger: which resource asked for which record, and what has to
-- happen to that record when that resource stops.
--
-- WHY THIS EXISTS, AND IT IS NOT A NICETY
--
-- ox_lib does not have this problem because it runs inside the consumer's own
-- Lua VM. Everything a resource creates is garbage-collected the moment the
-- resource stops, because the VM is the resource. cis_libs runs in its OWN VM,
-- so a zone, a target, a synced entity, a near watcher and a remote callback
-- outlive the resource that asked for them -- silently, and until the process
-- restarts.
--
-- On a development server that is an annoyance. On a server where a developer
-- restarts their own resource a few times an hour it is the main source of
-- "why is there a prop here that I deleted twenty minutes ago", and the answer
-- is never visible from inside the game.
--
-- The rule is one line: EVERY RECORD THIS LIBRARY HOLDS ON A CONSUMER'S BEHALF
-- IS OWED TO THAT CONSUMER, and a stop event releases what it is owed. Doing that
-- by hand in each module is how it gets half-done, so it is done once, here.
--
-- PURE, and safe for a consumer to `shared_script` for a private copy: the
-- ledger is passed in, never held as a module local. That is what makes a second
-- copy harmless -- two copies cannot disagree about anything, because neither
-- copy owns the records.
--
-- Usage:
--     local owned = CisOwned.new()
--     CisOwned.track(owned, GetInvokingResource(), 'zone', name)
--     CisOwned.forget(owned, 'zone', name)          -- removed normally
--     for _, rec in ipairs(CisOwned.release(owned, resource)) do
--         -- rec.kind, rec.id
--     end

CisOwned = {}

--- A fresh, empty ledger.
---
--- Passed in rather than held as a module local for the reason in the header: a
--- consumer that `shared_script`s this file gets a ledger that cannot see, and
--- be corrupted by, cis_libs's own.
--- @return table
function CisOwned.new()
    return {
        -- kind -> id -> owner. The direction every hot path asks: "who owns
        -- THIS record?", answered in one lookup.
        byKind = {},
        -- owner -> { [kind] = { [id] = true } }. The direction the stop sweep
        -- asks: "what does THIS resource own?", answered in one lookup rather
        -- than by scanning every record of every kind.
        byOwner = {},
    }
end

--- Record that `owner` now holds the record `id` of `kind`.
---
--- Re-tracking an existing id is a MOVE, not a second claim: the previous owner
--- loses it. That matters because a resource that stops and restarts re-runs its
--- own registration, and without the move the restarted resource would find its
--- name still attributed to a dead owner -- and the sweep for that dead owner
--- would then delete a live record.
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

--- Forget one record, whoever owns it. Called when a record is removed the
--- ordinary way -- the owner did not stop, the record simply ended.
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

--- Every record `owner` holds, as { kind, id } pairs.
---
--- Sorted, so a caller that acts on them -- firing an exit event, deleting an
--- entity -- does so in a stable order. A sweep whose order changes between two
--- identical stops is a sweep whose bugs are unreproducible.
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

--- Does `owner` hold this record?
--- @param ledger table
--- @param kind string
--- @param id any
--- @param owner string|nil
--- @return boolean
function CisOwned.isHeldBy(ledger, kind, id, owner)
    local bucket = ledger.byKind[kind]
    return bucket ~= nil and bucket[id] == (owner or 'cis_libs')
end

--- Who owns this record?
--- @param ledger table
--- @param kind string
--- @param id any
--- @return string|nil
function CisOwned.ownerOf(ledger, kind, id)
    local bucket = ledger.byKind[kind]
    return bucket and bucket[id] or nil
end

--- How many records the ledger is holding, across every owner.
---
--- For the boot self-check and for tests. `cis_debug` printing this is how an
--- operator sees a leak they have not noticed yet.
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

--- Empty the ledger entirely. Called when cis_libs itself stops: everything it
--- held is being torn down with the resource, and a consumer restarting against
--- a ledger that still claims to own records would be refused its own names.
--- @param ledger table
function CisOwned.clear(ledger)
    ledger.byKind = {}
    ledger.byOwner = {}
end