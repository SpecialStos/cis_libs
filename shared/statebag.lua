-- State bag watchers that hand you the ENTITY, not the bag name.

local ENTITY_WAIT_MS = 2000
local WAIT_STEP_MS = 50

local function entityFromBag(bagName)
    local id = bagName and bagName:match('^entity:(%d+)$')
    return id and tonumber(id) or nil
end

local function playerFromBag(bagName)
    local id = bagName and bagName:match('^player:(%d+)$')
    return id and tonumber(id) or nil
end

-- Wait for an entity to exist, on the client only.
local function awaitEntity(id, timeoutMs)
    -- Server: the entity exists there or it does not.
    if IsDuplicityVersion() then
        return id
    end
    local deadline = GetGameTimer() + (timeoutMs or ENTITY_WAIT_MS)
    while true do
        if DoesEntityExist(id) then return id end
        if GetGameTimer() >= deadline then
            return nil, ('entity %d did not exist after %dms; the bag replicated for something this client never streamed')
                :format(id, timeoutMs or ENTITY_WAIT_MS)
        end
        Wait(WAIT_STEP_MS)
    end
end

local function watch(key, handler, resolve, timeoutMs)
    if type(key) ~= 'string' or key == '' then
        return nil, ('key must be a non-empty string; the "*" wildcard is allowed: got %s'):format(tostring(key))
    end
    if type(handler) ~= 'function' then
        return nil, ('handler must be a function; got %s. A function passed from a CONSUMER is dropped across the exports boundary, so register this from cis_libs or use a net event instead'):format(type(handler))
    end

    local cookie = AddStateBagChangeHandler(key, '', function(bagName, _key, value, reserved, replicated)
        local resolved = resolve(bagName)
        if not resolved then
            return
        end
        local entity, why = awaitEntity(resolved, timeoutMs)
        if not entity then
            if CisLog then
                CisLog('warn', ('cis_libs: statebag %s on %s: %s'):format(key, tostring(bagName), tostring(why)))
            end
            return
        end
        -- `reserved` is the "this was deleted" flag.
        local ok, err = pcall(handler, entity, value, replicated, reserved == true)
        if not ok and CisLog then
            CisLog('error', ('cis_libs: statebag %s handler raised: %s'):format(key, tostring(err)))
        end
    end)
    return cookie
end

function CisStatebagOnEntity(key, handler, timeoutMs)
    return watch(key, handler, entityFromBag, timeoutMs)
end

function CisStatebagOnPlayer(key, handler, timeoutMs)
    return watch(key, handler, playerFromBag, timeoutMs)
end

exports('StatebagOnEntity', CisStatebagOnEntity)
exports('StatebagOnPlayer', CisStatebagOnPlayer)
exports('RemoveStatebagHandler', function(cookie)
    if type(cookie) ~= 'number' then
        return false, ('cookie must be the number the watcher returned; got %s'):format(type(cookie))
    end
    RemoveStateBagChangeHandler(cookie)
    return true
end)
