-- Vetoable hooks. First refusal wins. An error is a veto (fail closed).
-- Functions cannot cross the exports boundary, so on() from a consumer
-- must pass a 'resource:Export' string, same as Cis.net.on.

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

function CisHooks.on(name, fn, opts)
    if type(name) ~= 'string' or name == '' then
        return nil, 'hook name must be a non-empty string'
    end
    if type(fn) ~= 'function' then
        return nil, ('hook fn must be a function, got %s'):format(type(fn))
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
    local list = CisHooks.byName[name]
    if not list then
        list = {}
        CisHooks.byName[name] = list
    end
    list[#list + 1] = rec
    table.sort(list, function(a, b)
        if a.priority ~= b.priority then
            return a.priority > b.priority
        end
        return a.id < b.id
    end)
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

function CisHooks.remove(id)
    if type(id) ~= 'number' then
        return false, 'hook id must be a number'
    end
    for name, list in pairs(CisHooks.byName) do
        for i = #list, 1, -1 do
            if list[i].id == id then
                table.remove(list, i)
                if #list == 0 then
                    CisHooks.byName[name] = nil
                end
                return true
            end
        end
    end
    return false, 'no such hook'
end

if type(AddEventHandler) == 'function' then
    AddEventHandler('onResourceStop', function(resource)
        if type(GetCurrentResourceName) == 'function' and resource == GetCurrentResourceName() then
            return
        end
        CisHooks.releaseOwner(resource)
    end)
end

pcall(function()
exports('HookOn', function(name, fn, opts)
    if type(fn) == 'function' then
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
    for name, list in pairs(CisHooks.byName) do
        for i = #list, 1, -1 do
            if list[i].owner == resource then
                table.remove(list, i)
                n = n + 1
            end
        end
        if #list == 0 then
            CisHooks.byName[name] = nil
        end
    end
    return n
end
