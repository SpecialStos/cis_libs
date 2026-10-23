-- Vetoable hooks. First refusal wins. An error is a veto (fail closed).
-- A function passed from a consumer crosses the exports boundary as a callable
-- reference table, which is accepted (CisCallable); so is a 'resource:Export'
-- string. Either way the hook is OWNED by the resource that registered it and
-- removed when that resource stops.

CisHooks = {
    byName = {},
}

local nextId = 0

local function ownerOf()
    if type(GetInvokingResource) == 'function' then
        local ok, name = pcall(GetInvokingResource)
        if ok and type(name) == 'string' and name ~= '' then
            return name
        end
    end
    return GetCurrentResourceName and GetCurrentResourceName() or 'cis_libs'
end

-- A list is never changed in place: on, remove and releaseOwner store a new one.
-- run walks the list it read, so a hook that removes itself, or registers
-- another, mid-run cannot shift or re-sort the walk under it.
local function without(list, drop)
    local out = {}
    for i = 1, #list do
        if not drop(list[i]) then
            out[#out + 1] = list[i]
        end
    end
    return out
end

local function store(name, list)
    CisHooks.byName[name] = #list > 0 and list or nil
end

function CisHooks.on(name, fn, opts)
    if type(name) ~= 'string' or name == '' then
        return false, 'hook name must be a non-empty string'
    end
    if not CisCallable(fn) then
        return false, ('hook fn must be a function, got %s'):format(type(fn))
    end
    opts = opts or {}
    local priority = tonumber(opts.priority) or 0
    nextId = nextId + 1
    local rec = {
        id = nextId,
        name = name,
        fn = fn,
        priority = priority,
        owner = ownerOf(),
    }
    local list = without(CisHooks.byName[name] or {}, function() return false end)
    list[#list + 1] = rec
    table.sort(list, function(a, b)
        if a.priority ~= b.priority then
            return a.priority > b.priority
        end
        return a.id < b.id
    end)
    store(name, list)
    return rec.id
end

function CisHooks.run(name, payload)
    local list = CisHooks.byName[name]
    if not list or #list == 0 then
        return true
    end
    for i = 1, #list do
        local rec = list[i]
        local ok, allowed, reason = pcall(rec.fn, payload)
        if not ok then
            if Logging and Logging.Warn then
                Logging.Warn(('cis_libs: hook %q from %s raised: %s')
                    :format(name, tostring(rec.owner), tostring(allowed)))
            end
            return false, ('hook %s raised'):format(tostring(rec.owner)), rec.owner
        end
        if allowed == false then
            return false, reason or 'denied', rec.owner
        end
    end
    return true
end

-- ONLY THE OWNER, or cis_libs. Ids count up from 1, so without this
-- `for i = 1, 500 do HookRemove(i) end` stripped every resource's vetoes.
function CisHooks.remove(id)
    if type(id) ~= 'number' then
        return false, 'hook id must be a number'
    end
    local caller = ownerOf()
    local lib = type(GetCurrentResourceName) == 'function' and GetCurrentResourceName() or 'cis_libs'
    for name, list in pairs(CisHooks.byName) do
        for i = 1, #list do
            local rec = list[i]
            if rec.id == id then
                if caller ~= rec.owner and caller ~= lib then
                    return false, ('hook %d belongs to %s, not %s'):format(id, tostring(rec.owner), caller)
                end
                store(name, without(list, function(r) return r == rec end))
                return true
            end
        end
    end
    return false, 'no such hook'
end

if type(AddEventHandler) == 'function' then
    AddEventHandler('onResourceStop', function(resource)
        -- A forged stop from another client script is ignored (shared/owned.lua).
        if not CisRealStop(resource) then
            return
        end
        if type(GetCurrentResourceName) == 'function' and resource == GetCurrentResourceName() then
            return
        end
        CisHooks.releaseOwner(resource)
    end)
end

pcall(function()
exports('HookOn', function(name, fn, opts)
    if CisCallable(fn) then
        return CisHooks.on(name, fn, opts)
    end
    if type(fn) == 'string' then
        local resource, exportName = fn:match('^([^:]+):(.+)$')
        if not resource then
            return false, 'hook provider must be resource:Export'
        end
        return CisHooks.on(name, function(payload)
            local res = exports[resource]
            local target = res and res[exportName]
            if not target then
                return false, 'hook export gone'
            end
            return target(res, payload)
        end, opts)
    end
    return false, ('hook fn must be a function or resource:Export, got %s'):format(type(fn))
end)
end)

pcall(function()
exports('HookRun', function(name, payload)
    return CisHooks.run(name, payload)
end)
end)

pcall(function()
exports('HookRemove', function(id)
    return CisHooks.remove(id)
end)
end)

function CisHooks.releaseOwner(resource)
    local n = 0
    local names = {}
    for name in pairs(CisHooks.byName) do names[#names + 1] = name end
    for _, name in ipairs(names) do
        local list = CisHooks.byName[name]
        local kept = without(list, function(r) return r.owner == resource end)
        n = n + (#list - #kept)
        store(name, kept)
    end
    return n
end
