-- Ownership ledger: which resource asked for which record, and what has to happen to

CisOwned = {}

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
