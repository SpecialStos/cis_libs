-- The whole `Cis.*` surface. A consumer adds one line to its manifest:

local RESOURCE = 'cis_libs'
local THIS = GetCurrentResourceName()
-- True when this copy of the file belongs to cis_libs itself.
local IS_SELF = THIS == RESOURCE
local IS_SERVER = IsDuplicityVersion()

Cis = Cis or {}
Cis.resource = RESOURCE
Cis.isReady = Cis.isReady or false
Cis.isFailed = Cis.isFailed or false

local EXPORT_TABLE = exports[RESOURCE]

-- Every export call in this file goes through here, and the reason is the trap that has
local function exportCall(name, ...)
    return EXPORT_TABLE[name](EXPORT_TABLE, ...)
end

-- Same call, but a refusal is a value rather than a crash.
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

-- Pure, and deliberately NOT an export: it runs here, in the consumer's own Lua state,
function Cis.waitFor(fn, msg, timeoutMs)
    if type(fn) ~= 'function' then
        return nil, ('waitFor needs a function; got %s'):format(type(fn))
    end
    -- Default 10000.
    local timeout = tonumber(timeoutMs)
    if timeout == nil then
        timeout = 10000
    elseif timeout ~= timeout or timeout == math.huge or timeout == -math.huge then
        return nil, 'waitFor timeoutMs is not a finite number'
    end
    local deadline = GetGameTimer() + timeout
    while true do
        local value = fn()
        -- false is "not yet", not success.
        if value ~= nil and value ~= false then
            return value
        end
        if GetGameTimer() >= deadline then
            return nil, ('waitFor timed out after %dms'):format(timeout)
                .. (msg and (' (' .. tostring(msg) .. ')') or '')
        end
        Wait(0)
    end
end

function Cis.wait(timeout)
    timeout = timeout or 15000
    if IS_SELF and CisReadyState then
        return CisReadyState.wait(timeout)
    end
    -- ONE DEADLINE FOR THE WHOLE CALL ().
    local deadline = GetGameTimer() + timeout
    if GetResourceState(RESOURCE) ~= 'started' then
        while GetResourceState(RESOURCE) ~= 'started' and GetGameTimer() < deadline do
            Wait(50)
        end
    end
    local remaining = deadline - GetGameTimer()
    if remaining <= 0 then
        -- The wait is over. Answering `false` is the honest result: whatever the caller
        return false
    end
    local ok = tryExport('WaitReady', remaining)
    return ok == true
end

Cis.player = Cis.player or {}
Cis.callback = Cis.callback or {}
Cis.framework = Cis.framework or {}
Cis.inventory = Cis.inventory or {}
Cis.zones = Cis.zones or {}
Cis.zones.server = Cis.zones.server or {}
Cis.hooks = Cis.hooks or {}
Cis.points = Cis.points or {}
Cis.target = Cis.target or {}
Cis.doors = Cis.doors or {}
Cis.sync = Cis.sync or {}
Cis.db = Cis.db or {}
Cis.log = Cis.log or {}
Cis.net = Cis.net or {}
Cis.security = Cis.security or {}
Cis.streaming = Cis.streaming or {}
Cis.raycast = Cis.raycast or {}
Cis.keybind = Cis.keybind or {}
Cis.statebag = Cis.statebag or {}
Cis.command = Cis.command or {}
Cis.ui = Cis.ui or {}
Cis.ui.textUI = Cis.ui.textUI or {}

-- Realm split. A consumer calls only the half that matches where it is; the other half
if not IS_SERVER then
    local coordFrame = -1
    local coordValue
    local coordPed = 0

    -- The only place the two call styles are visible, so it is worth reading once.
    local function currentPed()
        if IS_SELF and CisCache and CisCache.ped and CisCache.ped ~= 0 then
            return CisCache.ped
        end
        return PlayerPedId()
    end

    -- FREE. No boundary, no matter which copy is running.
    function Cis.player.ped()
        return currentPed()
    end

    -- FREE, and memoised to one native per frame per calling VM.
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

    -- FREE. The heading is refreshed on the same watchdog tick as the ped, at the same
    function Cis.player.heading()
        if IS_SELF and CisCache then
            return CisCache.heading
        end
        return GetEntityHeading(currentPed())
    end

    -- The three player.* calls above are free.

    -- CROSSES. Returns nil rather than 0 when the player is on foot; a consumer that
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

    -- Nil on foot, never 0: 0 is a passenger seat.
    function Cis.player.seat()
        if IS_SELF and CisCache then
            if not CisCache.vehicle or CisCache.vehicle == 0 then
                return nil
            end
            return CisCache.seat
        end
        return tryExport('GetCachedSeat')
    end

    -- The local index, not the server id.
    function Cis.player.playerId()
        if IS_SELF and CisCache then
            return CisCache.playerId ~= 0 and CisCache.playerId or PlayerId()
        end
        return tryExport('GetCachedPlayerId') or PlayerId()
    end

    -- CROSSES. A fresh table whenever the weapon or its ammo changes, never a mutation
    function Cis.player.weapon()
        if IS_SELF and CisCache then
            return CisCache.weapon
        end
        return tryExport('GetCachedWeapon')
    end

    -- CROSSES. Falls back to the native when the cache has not been populated, so it
    function Cis.player.serverId()
        if IS_SELF and CisCache then
            return CisCache.serverId
        end
        return tryExport('GetCachedServerId') or GetPlayerServerId(PlayerId())
    end

    -- The unsubscribe function is a RETURN, and a returned function does survive the
    function Cis.player.on(key, cb)
        return exportCall('OnPlayerCache', key, cb)
    end

    -- onEnter/onExit cannot cross the boundary; pass event names instead when calling
    function Cis.player.near(coords, distance, onEnter, onExit, onEnterEvent, onExitEvent)
        return exportCall('WatchNear', coords, distance, onEnter, onExit, onEnterEvent, onExitEvent)
    end

    -- Zones cross, and refuse out loud: each returns `false, '<reason>'` on the way
    function Cis.raycast.camera(flags, ignore, distance, timeoutMs)
        return exportCall('RaycastCamera', flags, ignore, distance, timeoutMs)
    end

    function Cis.raycast.fromCoords(origin, target, flags, ignore, timeoutMs)
        return exportCall('RaycastFromCoords', origin, target, flags, ignore, timeoutMs)
    end

    -- THE HANDLE IS RETURNED, not the boolean, because `disable` and `isPressed` need
    function Cis.keybind.add(options)
        return exportCall('KeybindAdd', options)
    end

    -- Local UI, not the framework notification.
    function Cis.ui.notify(message, kind)
        return exportCall('UiNotify', message, kind)
    end

    function Cis.ui.textUI.show(text, opts)
        return exportCall('UiTextUIShow', text, opts)
    end

    function Cis.ui.textUI.hide()
        return exportCall('UiTextUIHide')
    end

    function Cis.ui.textUI.isOpen()
        return exportCall('UiTextUIIsOpen')
    end

    function Cis.ui.progress(opts)
        return exportCall('UiProgress', opts)
    end

    function Cis.ui.confirm(opts)
        return exportCall('UiConfirm', opts)
    end

    function Cis.ui.input(opts)
        return exportCall('UiInput', opts)
    end

    -- A COOKIE, not a boolean. `AddStateBagChangeHandler` answers one, and a watcher
    function Cis.statebag.onEntity(key, handler, timeoutMs)
        return exportCall('StatebagOnEntity', key, handler, timeoutMs)
    end

    function Cis.statebag.onPlayer(key, handler, timeoutMs)
        return exportCall('StatebagOnPlayer', key, handler, timeoutMs)
    end

    function Cis.statebag.remove(cookie)
        return exportCall('RemoveStatebagHandler', cookie)
    end

    function Cis.command.add()
        return false, 'server only'
    end

    function Cis.command.list()
        return false, 'server only'
    end

    function Cis.command.remove()
        return false, 'server only'
    end

    function Cis.zones.server.box()
        return false, 'server only'
    end

    function Cis.zones.server.sphere()
        return false, 'server only'
    end

    function Cis.zones.server.poly()
        return false, 'server only'
    end

    function Cis.zones.server.contains()
        return false, 'server only'
    end

    function Cis.zones.server.players()
        return false, 'server only'
    end

    function Cis.zones.server.remove()
        return false, 'server only'
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

    -- `false` for an unknown name, deliberately: removing a zone twice, or one that was
    function Cis.zones.remove(name)
        return exportCall('RemoveZone', name)
    end

    function Cis.zones.contains(name, point)
        return exportCall('ZoneContains', name, point)
    end

    -- A POINT IS NOT A ZONE. `Cis.zones.box('shop', coords, 4.0)` expresses the common
    function Cis.points.add(data)
        return exportCall('CreatePoint', data)
    end

    function Cis.points.remove(id)
        return exportCall('RemovePoint', id)
    end

    -- TWO VALUES, and the second is the distance in metres rather than a reason.
    function Cis.points.getClosest()
        return exportCall('GetClosestPoint')
    end

    -- Targets cross on the same terms as zones, including the two-value refusal.
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

    -- SEVEN MORE KINDS, and the shape is the same for all of them: the asset on
    function Cis.streaming.animDict(name, timeout)
        return exportCall('AnimDict', name, timeout)
    end

    function Cis.streaming.animSet(name, timeout)
        return exportCall('AnimSet', name, timeout)
    end

    -- Named after the native's `Ptfx`, not `ptfx`, because the export is a PascalCase
    function Cis.streaming.ptfx(name, timeout)
        return exportCall('Ptfx', name, timeout)
    end

    function Cis.streaming.textureDict(name, timeout)
        return exportCall('TextureDict', name, timeout)
    end

    function Cis.streaming.weaponAsset(hash, timeout)
        return exportCall('WeaponAsset', hash, timeout)
    end

    function Cis.streaming.scaleform(name, timeout)
        return exportCall('Scaleform', name, timeout)
    end

    -- The one kind with no wait: `RequestScriptAudioBank` answers a BOOL directly, and
    function Cis.streaming.audioBank(name, timeout)
        return exportCall('AudioBank', name, timeout)
    end

    -- CROSSES. Client counts are a pushed snapshot maintained inside cis_libs, so this
    function Cis.inventory.count(item)
        return exportCall('InventoryCount', item)
    end

    -- Free of a crossing: has() is built on the local result of count() rather than
    function Cis.inventory.has(item, amount)
        local count = Cis.inventory.count(item)
        return (count or 0) >= (amount or 1)
    end
else
    -- Server half. Everything here crosses, with no free-read exceptions: a server-side

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

    -- Every one of these yields on the far side and gives up at
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

    -- cis_libs NEVER CALLS add_ace.
    function Cis.command.add(name, options, handler)
        return exportCall('CommandAdd', name, options, handler)
    end

    function Cis.command.list()
        return exportCall('CommandList')
    end

    function Cis.command.remove(name)
        return exportCall('CommandRemove', name)
    end

    function Cis.zones.server.box(center, size, opts)
        return exportCall('ServerZoneBox', center, size, opts)
    end

    function Cis.zones.server.sphere(center, radius, opts)
        return exportCall('ServerZoneSphere', center, radius, opts)
    end

    function Cis.zones.server.poly(points, opts)
        return exportCall('ServerZonePoly', points, opts)
    end

    function Cis.zones.server.contains(id, coords)
        return exportCall('ServerZoneContains', id, coords)
    end

    function Cis.zones.server.players(id)
        return exportCall('ServerZonePlayers', id)
    end

    function Cis.zones.server.remove(id)
        return exportCall('ServerZoneRemove', id)
    end

    function Cis.statebag.onEntity(key, handler, timeoutMs)
        return exportCall('StatebagOnEntity', key, handler, timeoutMs)
    end

    function Cis.statebag.onPlayer(key, handler, timeoutMs)
        return exportCall('StatebagOnPlayer', key, handler, timeoutMs)
    end

    function Cis.statebag.remove(cookie)
        return exportCall('RemoveStatebagHandler', cookie)
    end

    function Cis.security.report(src, reason)
        return exportCall('SecurityReport', src, reason)
    end

    -- `fn` is a function being SENT, not returned, so the exports boundary drops it.
    function Cis.net.on(name, fn, opts)
        return exportCall('SecureNetOn', name, fn, opts)
    end
end

-- Every function inside `if not IS_SERVER` that has NO counterpart in the `else` half
if IS_SERVER then
function Cis.player.ped()
    return false, 'client only'
end

function Cis.player.coords()
    return false, 'client only'
end

function Cis.player.heading()
    return false, 'client only'
end

function Cis.player.vehicle()
    return false, 'client only'
end

function Cis.player.seat()
    return false, 'client only'
end

function Cis.player.playerId()
    return false, 'client only'
end

function Cis.player.weapon()
    return false, 'client only'
end

function Cis.player.serverId()
    return false, 'client only'
end

function Cis.player.on()
    return false, 'client only'
end

function Cis.player.near()
    return false, 'client only'
end

function Cis.zones.poly()
    return false, 'client only'
end

function Cis.zones.box()
    return false, 'client only'
end

function Cis.zones.sphere()
    return false, 'client only'
end

function Cis.zones.remove()
    return false, 'client only'
end

function Cis.zones.contains()
    return false, 'client only'
end

function Cis.points.add()
    return false, 'client only'
end

function Cis.points.remove()
    return false, 'client only'
end

function Cis.points.getClosest()
    return false, 'client only'
end

function Cis.target.add()
    return false, 'client only'
end

function Cis.target.remove()
    return false, 'client only'
end

function Cis.target.update()
    return false, 'client only'
end

function Cis.target.exists()
    return false, 'client only'
end

function Cis.streaming.model()
    return false, 'client only'
end

function Cis.streaming.animDict()
    return false, 'client only'
end

function Cis.streaming.animSet()
    return false, 'client only'
end

function Cis.streaming.ptfx()
    return false, 'client only'
end

function Cis.streaming.textureDict()
    return false, 'client only'
end

function Cis.streaming.weaponAsset()
    return false, 'client only'
end

function Cis.streaming.scaleform()
    return false, 'client only'
end

function Cis.streaming.audioBank()
    return false, 'client only'
end

function Cis.raycast.camera()
    return false, 'client only'
end

function Cis.raycast.fromCoords()
    return false, 'client only'
end

function Cis.keybind.add()
    return false, 'client only'
end

function Cis.ui.notify()
    return false, 'client only'
end

function Cis.ui.textUI.show()
    return false, 'client only'
end

function Cis.ui.textUI.hide()
    return false, 'client only'
end

function Cis.ui.textUI.isOpen()
    return false, 'client only'
end

function Cis.ui.progress()
    return false, 'client only'
end

function Cis.ui.confirm()
    return false, 'client only'
end

function Cis.ui.input()
    return false, 'client only'
end
end

-- [D1] Client `notify(message, kind)`.
function Cis.hooks.on(name, fn, opts)
    return exportCall('HookOn', name, fn, opts)
end

function Cis.hooks.run(name, payload)
    return exportCall('HookRun', name, payload)
end

function Cis.hooks.remove(id)
    return exportCall('HookRemove', id)
end

function Cis.framework.notify(srcOrNil, message, kind)
    if IS_SERVER then
        return exportCall('Notify', srcOrNil, message, kind)
    end
    if message == nil then
        -- One argument: it IS the message.
        return exportCall('Notify', srcOrNil, kind)
    end
    -- Two or more: (message, kind), in that order.
    return exportCall('Notify', srcOrNil, message)
end

-- A function cannot be SENT across the exports boundary, so `handler` may be: a
function Cis.callback.register(name, handler)
    return exportCall('RegisterCallback', name, handler)
end

-- The inner await, so `call` below and `await` above share ONE implementation.
local function awaitInside(name, ...)
    return exportCall('AwaitCallback', name, ...)
end

function Cis.callback.await(name, ...)
    return awaitInside(name, ...)
end

-- The non-raising await ().
function Cis.callback.tryAwait(name, ...)
    return exportCall('TryAwaitCallback', name, ...)
end

-- `cb` IS A FUNCTION, and a function cannot cross the exports boundary, so
function Cis.callback.call(name, cb, ...)
    local args = table.pack(...)
    CreateThread(function()
        local results = table.pack(pcall(awaitInside, name, table.unpack(args, 1, args.n)))
        if not cb then
            return
        end
        if not results[1] then
            -- The refusal is reported the same way the server export reports a failed
            cb(false, tostring(results[2]))
            return
        end
        -- EVERY VALUE, UNPACKED WITH ITS COUNT.
        cb(table.unpack(results, 1, results.n))
    end)
end

if IS_SERVER then
    -- Explicit server-to-client callback.
    function Cis.callback.callClient(src, name, cb, ...)
        return exportCall('CallCallbackClient', name, src, cb, ...)
    end

    function Cis.callback.awaitClient(src, name, ...)
        return exportCall('AwaitCallbackClient', name, src, ...)
    end
end

-- Returns true once registered, false when it is refused (no id, already registered, or
function Cis.doors.add(data)
    return exportCall('AddDoorToSystem', data)
end

-- A REQUEST, not a command, on the client: the server re-checks job permission and
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

-- TWO REALMS, AND THE WRONG ONE IS A REFUSAL RATHER THAN A RAISE.
local function serverOnly()
    return false, 'server only'
end

-- `kind` leads and is the discriminator the server keys its records on, so
function Cis.sync.ped(data)
    if not IS_SERVER then return serverOnly() end
    return exportCall('SyncCreate', 'ped', data)
end

function Cis.sync.prop(data)
    if not IS_SERVER then return serverOnly() end
    return exportCall('SyncCreate', 'prop', data)
end

function Cis.sync.vehicle(data)
    if not IS_SERVER then return serverOnly() end
    return exportCall('SyncCreate', 'vehicle', data)
end

function Cis.sync.remove(id)
    if not IS_SERVER then return serverOnly() end
    return exportCall('SyncRemove', id)
end

-- WHAT THIS RESOURCE HAS IN THE WORLD, and a way to take it all down.
function Cis.sync.list()
    if not IS_SERVER then return serverOnly() end
    return exportCall('SyncList')
end

-- Answers how many records it took.
function Cis.sync.clear()
    if not IS_SERVER then return serverOnly() end
    return exportCall('SyncClear')
end

-- The read and the notification side.
function Cis.sync.entity(key)
    if IS_SERVER then return serverOnly() end
    return exportCall('GetSyncedEntity', key)
end

-- Both run under pcall inside the library: a consumer hook that raises must not take
function Cis.sync.onSpawn(fn)
    if IS_SERVER then return serverOnly() end
    return exportCall('AddSyncSpawnHandler', fn)
end

function Cis.sync.onDespawn(fn)
    if IS_SERVER then return serverOnly() end
    return exportCall('AddSyncDespawnHandler', fn)
end

-- Debug is gated on Config.Printing.Debug and is usually silent; the other three always
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

-- Every module in shared/algo and shared/util used to be listed in shared_scripts,
local REQUIRE_MODULES = {
    curve = { path = 'shared/algo/curve.lua', global = 'CisCurve', deps = {} },
    heap = { path = 'shared/algo/heap.lua', global = 'CisHeap', deps = {} },
    interp = { path = 'shared/algo/interp.lua', global = 'CisInterp', deps = {} },
    lru = { path = 'shared/algo/lru.lua', global = 'CisLRU', deps = {} },
    random = { path = 'shared/algo/random.lua', global = 'CisRandom', deps = {} },
    rate = { path = 'shared/algo/rate.lua', global = 'CisRate', deps = {} },
    sparse = { path = 'shared/algo/sparse.lua', global = 'CisSparse', deps = {} },
    window = { path = 'shared/algo/window.lua', global = 'CisWindow', deps = {} },
    id = { path = 'shared/util/id.lua', global = 'CisId', deps = {} },
    json = { path = 'shared/util/json.lua', global = 'CisJson', deps = {} },
    semver = { path = 'shared/util/semver.lua', global = 'CisSemver', deps = {} },
    string = { path = 'shared/util/string.lua', global = 'CisString', deps = {} },
    table = { path = 'shared/util/table.lua', global = 'CisTable', deps = {} },
    time = { path = 'shared/util/time.lua', global = 'CisTime', deps = {} },
    validate = { path = 'shared/util/validate.lua', global = 'CisValidate', deps = {} },
}

-- THE VALID NAMES, ONCE. The refusal has to be actionable -- the caller is holding a
local REQUIRE_NAMES = (function()
    local out = {}
    for name in pairs(REQUIRE_MODULES) do out[#out + 1] = name end
    table.sort(out)
    return out
end)()

-- PER VM, not per resource. Two resources calling Cis.require in the same VM share one
local requireCache = {}

local function sandboxFor(spec)
    -- The environment IS the dependency map.
    local env = {}
    for _, dep in ipairs(spec.deps) do
        local depSpec = REQUIRE_MODULES[dep]
        if not depSpec then
            -- A DEPENDENCY THAT IS NOT IN THE ALLOW-LIST is a wiring bug in this file,
            error(('Cis.require: %s depends on %q, which is not a module'):format(
                tostring(spec.path), tostring(dep)))
        end
        env[depSpec.global] = Cis.require(dep)
    end
    return setmetatable(env, {
        __index = _G,
        -- A WRITE RAISES. Reads are unrestricted, because a module legitimately needs
        __newindex = function(_, key)
            error(('Cis.require: a module assigned the global %q; a module returns '
                .. 'its table and writes nothing'):format(tostring(key)), 2)
        end,
    })
end

-- A module, loaded on demand, with no global left behind.
function Cis.require(name)
    if type(name) ~= 'string' then
        error(('Cis.require: module name must be a string, got %s. Valid names: %s')
            :format(type(name), table.concat(REQUIRE_NAMES, ', ')), 2)
    end
    local spec = REQUIRE_MODULES[name]
    if not spec then
        error(('Cis.require: no module named %q. Valid names: %s'):format(
            name, table.concat(REQUIRE_NAMES, ', ')), 2)
    end
    if requireCache[name] then
        return requireCache[name]
    end

    local src = LoadResourceFile('cis_libs', spec.path)
    if not src then
        error(('Cis.require: %s could not be read from the resource. Is it listed '
            .. 'in fxmanifest.lua files {}?'):format(spec.path), 2)
    end
    local chunk, compileErr = load(src, '@cis_libs/' .. spec.path, 't', sandboxFor(spec))
    if not chunk then
        error(('Cis.require: %s failed to compile: %s'):format(spec.path, tostring(compileErr)), 2)
    end
    -- THE MARKER. The module's own tail reads `...`, and this argument is the only
    local ok, result = pcall(chunk, 'cis_require')
    if not ok then
        error(('Cis.require: %s raised while loading: %s'):format(spec.path, tostring(result)), 2)
    end
    if type(result) ~= 'table' then
        error(('Cis.require: %s did not return a table (got %s). A module must end '
            .. 'with `return M`.'):format(spec.path, tostring(result)), 2)
    end
    requireCache[name] = result
    return result
end

-- The valid names, for a caller that wants to check before it calls rather than catch.
function Cis.requireList()
    local out = {}
    for i = 1, #REQUIRE_NAMES do out[i] = REQUIRE_NAMES[i] end
    return out
end

-- What a CONSUMER can be told about a module, because a consumer cannot be handed one.
function Cis.moduleInfo(name, opts)
    local wantLoad = type(opts) == 'table' and opts.load == true
    if type(name) ~= 'string' then
        return { ok = false, why = 'module name must be a string, got ' .. type(name) }
    end
    local spec = REQUIRE_MODULES[name]
    if not spec then
        return { ok = false, name = name, why = 'no module named ' .. name,
            valid = Cis.requireList() }
    end

    local out = {
        ok = true,
        name = name,
        path = spec.path,
        global = spec.global,
        deps = spec.deps,
        -- "Installed here" means the LEGACY GLOBAL exists on this realm, which is
        globalPresent = spec.global ~= nil and rawget(_G, spec.global) ~= nil,
    }

    if wantLoad then
        local ok, mod = pcall(Cis.require, name)
        if not ok then
            return { ok = false, name = name, path = spec.path, why = tostring(mod) }
        end
        -- Sorted, so two calls in the same state answer in the same order -- pairs()
        local fns = {}
        for k, v in pairs(mod) do
            if type(v) == 'function' then fns[#fns + 1] = tostring(k) end
        end
        table.sort(fns)
        out.functions = fns
        out.loaded = true
        -- Re-checked AFTER the load, because that is the assertion that matters:
        out.globalPresentAfterLoad = spec.global ~= nil and rawget(_G, spec.global) ~= nil
    end
    return out
end

-- WHICH OF THE FIFTEEN GLOBALS EXIST ON THIS REALM, and what has been required.
function Cis.moduleProbe()
    local present, loaded = {}, {}
    for _, name in ipairs(REQUIRE_NAMES) do
        local spec = REQUIRE_MODULES[name]
        if spec.global ~= nil and rawget(_G, spec.global) ~= nil then
            present[#present + 1] = spec.global
        end
        if requireCache[name] ~= nil then
            loaded[#loaded + 1] = name
        end
    end
    table.sort(present)
    table.sort(loaded)
    return { present = present, loaded = loaded, known = #REQUIRE_NAMES }
end
