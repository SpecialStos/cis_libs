-- Consumer import. Other resources add: shared_script '@cis_libs/init.lua'
-- Hot-path reads stay in this VM. Cross-resource work goes through exports.

local RESOURCE = 'cis_libs'
local THIS = GetCurrentResourceName()
local IS_SELF = THIS == RESOURCE
local IS_SERVER = IsDuplicityVersion()

Cis = Cis or {}
Cis.resource = RESOURCE
Cis.isReady = Cis.isReady or false
Cis.isFailed = Cis.isFailed or false

local EXPORT_TABLE = exports[RESOURCE]

-- `exports[resource][name](...)` looks equivalent to `exports[resource]:name(...)`
-- but is not: the bracket form yields an UNBOUND method, so the exports table
-- is expected as the first argument. Calling it without self shifts every
-- argument one place left -- a zone created as (kind, name, coords) arrived as
-- (name, coords, size), silently turning the name into the coordinates.
--
-- Passing the table explicitly is exactly what the colon syntax does.
local function exportCall(name, ...)
    return EXPORT_TABLE[name](EXPORT_TABLE, ...)
end

local function tryExport(name, ...)
    local ok, a, b, c, d = pcall(exportCall, name, ...)
    if not ok then
        return nil
    end
    return a, b, c, d
end

function Cis.ready(cb, timeout)
    if type(cb) == 'function' then
        if IS_SELF and CisReadyState then
            CisReadyState.onReady(cb)
            return
        end
        CreateThread(function()
            local ok = Cis.wait(timeout or 15000)
            cb(ok)
        end)
        return
    end
    return Cis.wait(cb or 15000)
end

function Cis.wait(timeout)
    if IS_SELF and CisReadyState then
        return CisReadyState.wait(timeout)
    end
    if GetResourceState(RESOURCE) ~= 'started' then
        local deadline = GetGameTimer() + (timeout or 15000)
        while GetResourceState(RESOURCE) ~= 'started' and GetGameTimer() < deadline do
            Wait(50)
        end
    end
    local ok = tryExport('WaitReady', timeout or 15000)
    return ok == true
end

Cis.player = Cis.player or {}
Cis.callback = Cis.callback or {}
Cis.framework = Cis.framework or {}
Cis.inventory = Cis.inventory or {}
Cis.zones = Cis.zones or {}
Cis.target = Cis.target or {}
Cis.doors = Cis.doors or {}
Cis.sync = Cis.sync or {}
Cis.db = Cis.db or {}
Cis.log = Cis.log or {}
Cis.net = Cis.net or {}
Cis.security = Cis.security or {}
Cis.streaming = Cis.streaming or {}

if not IS_SERVER then
    local coordFrame = -1
    local coordValue
    local coordPed = 0

    local function currentPed()
        if IS_SELF and CisCache and CisCache.ped and CisCache.ped ~= 0 then
            return CisCache.ped
        end
        return PlayerPedId()
    end

    function Cis.player.ped()
        return currentPed()
    end

    function Cis.player.coords()
        local frame = GetFrameCount()
        local ped = currentPed()
        if coordFrame == frame and coordPed == ped and coordValue then
            return coordValue
        end
        coordFrame = frame
        coordPed = ped
        coordValue = GetEntityCoords(ped)
        return coordValue
    end

    function Cis.player.heading()
        if IS_SELF and CisCache then
            return CisCache.heading
        end
        return GetEntityHeading(currentPed())
    end

    function Cis.player.vehicle()
        if IS_SELF and CisCache then
            if not CisCache.vehicle or CisCache.vehicle == 0 then
                return nil
            end
            return CisCache.vehicle, CisCache.seat
        end
        local vehicle, seat = tryExport('GetCachedVehicle')
        if not vehicle or vehicle == 0 then
            return nil
        end
        return vehicle, seat
    end

    function Cis.player.weapon()
        if IS_SELF and CisCache then
            return CisCache.weapon
        end
        return tryExport('GetCachedWeapon')
    end

    function Cis.player.serverId()
        if IS_SELF and CisCache then
            return CisCache.serverId
        end
        return tryExport('GetCachedServerId') or GetPlayerServerId(PlayerId())
    end

    function Cis.player.on(key, cb)
        return exportCall('OnPlayerCache', key, cb)
    end

    -- onEnter/onExit cannot cross the boundary; pass event names instead when
    -- calling from another resource. Receives (distance) on the server.
    function Cis.player.near(coords, distance, onEnter, onExit, onEnterEvent, onExitEvent)
        return exportCall('WatchNear', coords, distance, onEnter, onExit, onEnterEvent, onExitEvent)
    end

    function Cis.zones.poly(name, points, options)
        return exportCall('CreateZone', 'poly', name, points, options)
    end

    function Cis.zones.box(name, center, size, options)
        return exportCall('CreateZone', 'box', name, center, size, options)
    end

    function Cis.zones.sphere(name, center, radius, options)
        return exportCall('CreateZone', 'sphere', name, center, radius, options)
    end

    function Cis.zones.remove(name)
        return exportCall('RemoveZone', name)
    end

    function Cis.zones.contains(name, point)
        return exportCall('ZoneContains', name, point)
    end

    function Cis.target.add(zoneType, name, coords, size, options)
        return exportCall('CreateTarget', zoneType, name, coords, size, options)
    end

    function Cis.target.remove(name, isPed)
        return exportCall('RemoveTarget', name, isPed)
    end

    function Cis.target.update(name, options)
        return exportCall('UpdateTarget', name, options)
    end

    function Cis.target.exists(name)
        return exportCall('TargetExists', name)
    end

    function Cis.streaming.model(model, timeout)
        return exportCall('RequestModelTimeout', model, timeout)
    end

    function Cis.inventory.count(item)
        return exportCall('InventoryCount', item)
    end

    function Cis.inventory.has(item, amount)
        local count = Cis.inventory.count(item)
        return (count or 0) >= (amount or 1)
    end
else
    function Cis.framework.player(src)
        return exportCall('GetNormalizedPlayer', src)
    end

    function Cis.inventory.add(src, item, amount, metadata)
        return exportCall('InventoryAdd', src, item, amount, metadata)
    end

    function Cis.inventory.remove(src, item, amount)
        return exportCall('InventoryRemove', src, item, amount)
    end

    function Cis.inventory.count(src, item)
        return exportCall('InventoryCount', src, item)
    end

    function Cis.inventory.has(src, item, amount)
        local count = Cis.inventory.count(src, item)
        return (count or 0) >= (amount or 1)
    end

    function Cis.db.query(sql, params)
        return exportCall('DbQuery', sql, params)
    end

    function Cis.db.single(sql, params)
        return exportCall('DbSingle', sql, params)
    end

    function Cis.db.scalar(sql, params)
        return exportCall('DbScalar', sql, params)
    end

    function Cis.db.insert(sql, params)
        return exportCall('DbInsert', sql, params)
    end

    function Cis.db.update(sql, params)
        return exportCall('DbUpdate', sql, params)
    end

    function Cis.db.transaction(queries)
        return exportCall('DbTransaction', queries)
    end

    function Cis.security.report(src, reason)
        return exportCall('SecurityReport', src, reason)
    end

    function Cis.net.on(name, fn)
        return exportCall('SecureNetOn', name, fn)
    end
end

function Cis.framework.notify(srcOrNil, message, kind)
    if IS_SERVER then
        return exportCall('Notify', srcOrNil, message, kind)
    end
    if message == nil then
        return exportCall('Notify', srcOrNil, kind)
    end
    return exportCall('Notify', message, kind)
end

-- A function does not survive the exports boundary, so `handler` may be:
--   a function            -- only works when cis_libs itself calls this
--   'resource:exportName' -- dispatched on demand from that resource
function Cis.callback.register(name, handler)
    return exportCall('RegisterCallback', name, handler)
end

function Cis.callback.await(name, ...)
    return exportCall('AwaitCallback', name, ...)
end

function Cis.callback.call(name, cb, ...)
    return exportCall('CallCallback', name, cb, ...)
end

if IS_SERVER then
    -- Explicit server-to-client callback. Kept apart from Cis.callback.call so
    -- a numeric first argument is always treated as data.
    function Cis.callback.callClient(src, name, cb, ...)
        return exportCall('CallCallbackClient', name, src, cb, ...)
    end

    function Cis.callback.awaitClient(src, name, ...)
        return exportCall('AwaitCallbackClient', name, src, ...)
    end
end

function Cis.doors.add(data)
    return exportCall('AddDoorToSystem', data)
end

function Cis.doors.setState(id, locked)
    if IS_SERVER then
        if locked then
            return exportCall('LockDoors', id)
        end
        return exportCall('UnlockDoors', id)
    end
    if locked then
        return exportCall('RequestLockDoors', id)
    end
    return exportCall('RequestUnlockDoors', id)
end

function Cis.doors.get(id)
    return exportCall('GetDoorState', id)
end

function Cis.sync.ped(data)
    return exportCall('SyncCreate', 'ped', data)
end

function Cis.sync.prop(data)
    return exportCall('SyncCreate', 'prop', data)
end

function Cis.sync.vehicle(data)
    return exportCall('SyncCreate', 'vehicle', data)
end

function Cis.sync.remove(id)
    return exportCall('SyncRemove', id)
end

function Cis.log.debug(message)
    tryExport('LogDebug', message)
end

function Cis.log.info(message)
    tryExport('LogInfo', message)
end

function Cis.log.warn(message)
    tryExport('LogWarn', message)
end

function Cis.log.error(message)
    tryExport('LogError', message)
end
