-- The whole `Cis.*` surface. A consumer adds one line to its manifest:

local RESOURCE = 'cis_libs'
local THIS = GetCurrentResourceName()
-- True when this copy of the file belongs to cis_libs itself.
-- THIS is the consumer when this file is injected via @cis_libs/init.lua, so a
-- folder-name fatal here would kill every dependent resource. The identity
-- check lives in shared/identity.lua, which consumers never load.
local IS_SELF = THIS == RESOURCE
local IS_SERVER = IsDuplicityVersion()

-- A FORGED onResourceStop is ignored on the client. The same test as
-- CisRealStop in shared/owned.lua, which explains it; a consumer's VM does not
-- load that file, so the three lines are repeated here.
local function realStop(resource)
    if IS_SERVER then
        return true
    end
    local by = GetInvokingResource()
    return by == nil or by == resource
end

Cis = Cis or {}
Cis.resource = RESOURCE

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

-- THE CONSUMER-SIDE ENGINES (client/core/*.lua), loaded on first use. Declared
-- here, defined at the bottom of the file next to the Cis.require loader whose
-- cycle guard they share.
local loadCore, loadGeometry

-- `Cis.isReady` / `Cis.isFailed`. In cis_libs' own VM CisReadyState writes them
-- when the gate settles. A CONSUMER's Cis is a different table in a different
-- Lua state that nothing ever wrote, so they were plain fields stuck at false.
-- There they are read through, lazily, from the gate itself: never blocking, and
-- a settled answer is kept until cis_libs stops, so a consumer polling
-- `while not Cis.isReady do Wait(0) end` costs one export call per poll only
-- until the gate settles.
if IS_SELF then
    Cis.isReady = Cis.isReady or false
    Cis.isFailed = Cis.isFailed or false
else
    rawset(Cis, 'isReady', nil)
    rawset(Cis, 'isFailed', nil)
    local settled = nil
    local function gate()
        if settled then
            return settled
        end
        local ready, failed = tryExport('ReadyState')
        local state = { ready = ready == true, failed = failed == true }
        if state.ready or state.failed then
            settled = state
        end
        return state
    end
    if AddEventHandler then
        AddEventHandler('onResourceStop', function(resource)
            if resource == RESOURCE and realStop(resource) then
                settled = nil
            end
        end)
    end
    setmetatable(Cis, {
        __index = function(_, key)
            if key == 'isReady' then
                return gate().ready
            elseif key == 'isFailed' then
                return gate().failed
            end
            return nil
        end,
    })
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
            -- %s of a formatted number, not %d: Lua 5.4 raises on %d of 2.5,
            -- so a fractional timeout turned the timeout into a crash.
            local shown = timeout % 1 == 0 and ('%.0f'):format(timeout) or tostring(timeout)
            return nil, ('waitFor timed out after %sms'):format(shown)
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
Cis.world = Cis.world or {}
Cis.vehicle = Cis.vehicle or {}
Cis.marker = Cis.marker or {}
Cis.scaleform = Cis.scaleform or {}
Cis.dui = Cis.dui or {}
Cis.anim = Cis.anim or {}
Cis.controls = Cis.controls or {}

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

    -- ------------------------------------------------ the consumer's engines
    --
    -- WHAT RUNS WHERE. In a consumer, zones, points, keybinds, world queries,
    -- shape tests, streaming, vehicle properties, markers, scaleforms, DUI,
    -- animations and control holds run HERE, in the consumer's own VM, from the
    -- same client/core/*.lua text cis_libs runs for its exports. Each engine is
    -- loaded on the FIRST call that needs it (loadCore, at the bottom of this
    -- file), so a resource that never touches zones loads no zone code and runs
    -- no zone thread. Handlers are plain local functions: nothing is a funcref,
    -- and nothing crosses per frame.
    --
    -- The player-state reads (vehicle, seat, weapon, ids) answer from a MIRROR
    -- of cis_libs' cache, filled by one snapshot and kept current by the
    -- `cis_libs:cache` event cis_libs pushes on every change.
    --
    -- In cis_libs' own VM (IS_SELF) every one of these keeps its old route --
    -- the export or CisCache -- because that VM IS the singleton the exports
    -- serve.

    -- A logging seam for the engines. Crosses, but only on an error.
    local function consumerLog(level, message)
        local name = (level == 'error' and 'LogError') or (level == 'warn' and 'LogWarn')
            or (level == 'debug' and 'LogDebug') or 'LogInfo'
        tryExport(name, ('[%s] %s'):format(THIS, tostring(message)))
    end

    -- A loop body that raises is logged (once per 10 s per loop) and answers
    -- nil, so `Wait(tick() or default)` keeps the loop alive.
    local function consumerGuard(name, body)
        local lastLogged
        return function()
            local ok, result = pcall(body)
            if ok then
                return result
            end
            local now = GetGameTimer()
            if lastLogged == nil or now - lastLogged >= 10000 then
                lastLogged = now
                consumerLog('error', ('loop %s raised: %s'):format(name, tostring(result)))
            end
            return nil
        end
    end

    local function playerCoords()
        return Cis.player.coords()
    end

    -- name -> the instance (or the stateless module) this VM uses.
    local engines = {}

    local function engine(name)
        local e = engines[name]
        if e ~= nil then
            return e
        end
        if name == 'zones' then
            local geo = loadGeometry()
            e = loadCore('zones').new({
                grid = geo.CisGrid, geom = geo.CisZoneGeom, coords = playerCoords,
                log = consumerLog, guard = consumerGuard, autoDrive = true,
            })
        elseif name == 'points' then
            e = loadCore('points').new({
                grid = loadGeometry().CisGrid, coords = playerCoords,
                log = consumerLog, guard = consumerGuard, autoDrive = true,
            })
        elseif name == 'keybind' then
            e = loadCore('keybind').new({ log = consumerLog })
        elseif name == 'world' then
            e = loadCore('world').new({})
        elseif name == 'mirror' then
            e = loadCore('mirror').new({
                resource = RESOURCE, self = THIS, log = consumerLog,
                -- THE ONE EXPORT. Every later read is local.
                snapshot = function() return exportCall('GetCacheSnapshot') end,
            })
        elseif name == 'marker' then
            e = loadCore('marker').new({ coords = playerCoords, guard = consumerGuard, log = consumerLog })
        elseif name == 'scaleform' then
            e = loadCore('scaleform').new({ streaming = engine('streaming'), guard = consumerGuard })
        elseif name == 'dui' then
            e = loadCore('dui').new({ resource = THIS })
        elseif name == 'anim' then
            e = loadCore('anim').new({ streaming = engine('streaming') })
        elseif name == 'controls' then
            e = loadCore('controls').new({ guard = consumerGuard })
        else
            -- raycast, streaming, vehicle: pure modules, no instance.
            e = loadCore(name)
        end
        engines[name] = e
        return e
    end

    -- NATIVE STATE IS RELEASED ON THE CONSUMER'S OWN STOP. Its VM -- and every
    -- zone, point and handler in it -- goes with it, and FiveM drops its
    -- commands; what would outlive it is engine state: a scaleform movie left
    -- resident and a DUI browser left running.
    if AddEventHandler and not IS_SELF then
        AddEventHandler('onResourceStop', function(resource)
            if resource ~= THIS or not realStop(resource) then
                return
            end
            for _, name in ipairs({ 'scaleform', 'dui' }) do
                local e = engines[name]
                if e then pcall(e.releaseAll, e) end
            end
        end)
    end

    -- A mirror read: one snapshot on the first, none after.
    local function mirrored(key)
        return engine('mirror'):get(key)
    end

    -- Returns nil rather than 0 when the player is on foot; a consumer that
    -- treats 0 as a handle gets a nil-index crash somewhere else. FREE in a
    -- consumer after the first read.
    function Cis.player.vehicle()
        if IS_SELF and CisCache then
            if not CisCache.vehicle or CisCache.vehicle == 0 then
                return nil
            end
            return CisCache.vehicle, CisCache.seat
        end
        local vehicle = mirrored('vehicle')
        if not vehicle or vehicle == 0 then
            return nil
        end
        return vehicle, mirrored('seat')
    end

    -- Nil on foot, never 0: 0 is a passenger seat.
    function Cis.player.seat()
        if IS_SELF and CisCache then
            if not CisCache.vehicle or CisCache.vehicle == 0 then
                return nil
            end
            return CisCache.seat
        end
        local vehicle = mirrored('vehicle')
        if not vehicle or vehicle == 0 then
            return nil
        end
        return mirrored('seat')
    end

    -- The local index, not the server id.
    function Cis.player.playerId()
        if IS_SELF and CisCache then
            return CisCache.playerId ~= 0 and CisCache.playerId or PlayerId()
        end
        local id = mirrored('playerId')
        if id == nil or id == 0 then
            return PlayerId()
        end
        return id
    end

    -- A fresh table whenever the weapon or its ammo changes, never a mutation.
    function Cis.player.weapon()
        if IS_SELF and CisCache then
            return CisCache.weapon
        end
        return mirrored('weapon')
    end

    -- Falls back to the native when the cache has not been populated.
    function Cis.player.serverId()
        if IS_SELF and CisCache then
            return CisCache.serverId
        end
        local id = mirrored('serverId')
        if id == nil or id == 0 then
            return GetPlayerServerId(PlayerId())
        end
        return id
    end

    -- A LOCAL listener in a consumer: the unsubscribe it returns is a real
    -- function, because nothing crossed to make it.
    function Cis.player.on(key, cb)
        if IS_SELF then
            return exportCall('OnPlayerCache', key, cb)
        end
        return engine('mirror'):on(key, cb)
    end

    -- Any cached key, read from the mirror: aiming, armed, heading, ped,
    -- playerId, seat, serverId, shooting, vehicle, weapon.
    function Cis.cache(key)
        if IS_SELF and CisCache then
            return CisCache[key]
        end
        return mirrored(key)
    end

    -- ox_lib's lib.onCache: fn(value, previous) on every change of `key`.
    function Cis.onCache(key, fn)
        return Cis.player.on(key, fn)
    end

    -- onEnter/onExit cannot cross the boundary; pass event names instead when calling
    function Cis.player.near(coords, distance, onEnter, onExit, onEnterEvent, onExitEvent)
        return exportCall('WatchNear', coords, distance, onEnter, onExit, onEnterEvent, onExitEvent)
    end

    -- Shape tests run in the CALLER's VM: the poll yields the caller's thread.
    function Cis.raycast.camera(flags, ignore, distance, timeoutMs)
        if IS_SELF then
            return exportCall('RaycastCamera', flags, ignore, distance, timeoutMs)
        end
        return engine('raycast').camera(flags, ignore, distance, timeoutMs)
    end

    function Cis.raycast.fromCoords(origin, target, flags, ignore, timeoutMs)
        if IS_SELF then
            return exportCall('RaycastFromCoords', origin, target, flags, ignore, timeoutMs)
        end
        return engine('raycast').fromCoords(origin, target, flags, ignore, timeoutMs)
    end

    -- THE HANDLE IS RETURNED, with working methods in a consumer: disable,
    -- isPressed, reset, destroy. onPress/onRelease (or ox_lib's onPressed /
    -- onReleased) are plain functions. The commands and the mapping belong to
    -- the calling resource.
    function Cis.keybind.add(options)
        if IS_SELF then
            return exportCall('KeybindAdd', options)
        end
        return engine('keybind'):add(options, THIS)
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

    -- ZONES ARE THE CALLER'S. In a consumer they live in this VM: onEnter /
    -- onExit / inside are plain functions called with (zone, coords), the
    -- event-name options still fire their events, and the zones survive a
    -- cis_libs restart. `false, '<reason>'` on a refusal, as before.
    function Cis.zones.poly(name, points, options)
        if IS_SELF then
            return exportCall('CreateZone', 'poly', name, points, options)
        end
        return engine('zones'):create('poly', name, points, options, nil, THIS)
    end

    function Cis.zones.box(name, center, size, options)
        if IS_SELF then
            return exportCall('CreateZone', 'box', name, center, size, options)
        end
        return engine('zones'):create('box', name, center, size, options, THIS)
    end

    function Cis.zones.sphere(name, center, radius, options)
        if IS_SELF then
            return exportCall('CreateZone', 'sphere', name, center, radius, options)
        end
        return engine('zones'):create('sphere', name, center, radius, options, THIS)
    end

    -- `false` for an unknown name, deliberately: removing a zone twice, or one that was
    function Cis.zones.remove(name)
        if IS_SELF then
            return exportCall('RemoveZone', name)
        end
        return engine('zones'):remove(name)
    end

    -- FREE in a consumer: a containment test against this resource's own zone.
    function Cis.zones.contains(name, point)
        if IS_SELF then
            return exportCall('ZoneContains', name, point)
        end
        return engine('zones'):contains(name, point)
    end

    -- A POINT IS NOT A ZONE. `Cis.zones.box('shop', coords, 4.0)` expresses the common
    function Cis.points.add(data)
        if IS_SELF then
            return exportCall('CreatePoint', data)
        end
        return engine('points'):add(data, THIS)
    end

    function Cis.points.remove(id)
        if IS_SELF then
            return exportCall('RemovePoint', id)
        end
        return engine('points'):remove(id)
    end

    -- TWO VALUES, and the second is the distance in metres rather than a reason.
    -- In a consumer: the nearest of THIS resource's points, read locally.
    function Cis.points.getClosest()
        if IS_SELF then
            return exportCall('GetClosestPoint')
        end
        return engine('points'):getClosest(playerCoords())
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

    -- STREAMING IS THE CALLER'S. The request is this resource's own, the poll
    -- yields this resource's thread, and Cis.streaming.release gives it back.
    function Cis.streaming.model(model, timeout)
        if IS_SELF then
            return exportCall('RequestModelTimeout', model, timeout)
        end
        return engine('streaming').model(model, timeout)
    end

    -- SEVEN MORE KINDS, and the shape is the same for all of them: the asset on
    function Cis.streaming.animDict(name, timeout)
        if IS_SELF then
            return exportCall('AnimDict', name, timeout)
        end
        return engine('streaming').request('animDict', name, timeout)
    end

    function Cis.streaming.animSet(name, timeout)
        if IS_SELF then
            return exportCall('AnimSet', name, timeout)
        end
        return engine('streaming').request('animSet', name, timeout)
    end

    -- Named after the native's `Ptfx`, not `ptfx`, because the export is a PascalCase
    function Cis.streaming.ptfx(name, timeout)
        if IS_SELF then
            return exportCall('Ptfx', name, timeout)
        end
        return engine('streaming').request('ptfx', name, timeout)
    end

    function Cis.streaming.textureDict(name, timeout)
        if IS_SELF then
            return exportCall('TextureDict', name, timeout)
        end
        return engine('streaming').request('textureDict', name, timeout)
    end

    function Cis.streaming.weaponAsset(hash, timeout)
        if IS_SELF then
            return exportCall('WeaponAsset', hash, timeout)
        end
        return engine('streaming').request('weaponAsset', hash, timeout)
    end

    function Cis.streaming.scaleform(name, timeout)
        if IS_SELF then
            return exportCall('Scaleform', name, timeout)
        end
        return engine('streaming').request('scaleform', name, timeout)
    end

    -- The one kind with no wait: `RequestScriptAudioBank` answers a BOOL directly, and
    function Cis.streaming.audioBank(name, timeout)
        if IS_SELF then
            return exportCall('AudioBank', name, timeout)
        end
        return engine('streaming').request('audioBank', name, timeout)
    end

    -- Give back what a request loaded: the right release native for the kind.
    function Cis.streaming.release(kind, asset)
        return engine('streaming').release(kind, asset)
    end

    -- WORLD QUERIES, in the caller's VM: `filter(entity, coords)` is a plain
    -- function. `coords` defaults to the player's.
    function Cis.world.getClosestPed(coords, maxDistance, filter, opts)
        return engine('world'):closest('ped', coords or playerCoords(), maxDistance, filter, opts)
    end

    function Cis.world.getClosestVehicle(coords, maxDistance, filter, opts)
        return engine('world'):closest('vehicle', coords or playerCoords(), maxDistance, filter, opts)
    end

    function Cis.world.getClosestObject(coords, maxDistance, filter, opts)
        return engine('world'):closest('object', coords or playerCoords(), maxDistance, filter, opts)
    end

    function Cis.world.getClosestPlayer(coords, maxDistance, filter, opts)
        return engine('world'):closest('player', coords or playerCoords(), maxDistance, filter, opts)
    end

    function Cis.world.getNearbyPeds(coords, maxDistance, filter, opts)
        return engine('world'):nearby('ped', coords or playerCoords(), maxDistance, filter, opts)
    end

    function Cis.world.getNearbyVehicles(coords, maxDistance, filter, opts)
        return engine('world'):nearby('vehicle', coords or playerCoords(), maxDistance, filter, opts)
    end

    function Cis.world.getNearbyObjects(coords, maxDistance, filter, opts)
        return engine('world'):nearby('object', coords or playerCoords(), maxDistance, filter, opts)
    end

    function Cis.world.getNearbyPlayers(coords, maxDistance, filter, opts)
        return engine('world'):nearby('player', coords or playerCoords(), maxDistance, filter, opts)
    end

    -- ox_lib-compatible vehicle properties, read and written in the caller's VM.
    function Cis.vehicle.getProperties(vehicle)
        return engine('vehicle').getProperties(vehicle)
    end

    function Cis.vehicle.setProperties(vehicle, props, fixVehicle)
        return engine('vehicle').setProperties(vehicle, props, fixVehicle)
    end

    -- MARKERS. One thread per resource, only while a marker exists.
    function Cis.marker.add(opts)
        return engine('marker'):add(opts)
    end

    function Cis.marker.remove(id)
        return engine('marker'):remove(id)
    end

    function Cis.marker.clear()
        return engine('marker'):clear()
    end

    -- A SCALEFORM OBJECT: :call(method, ...), :draw(), :draw3d(), :startDrawing(),
    -- :dispose(). Released on dispose and on this resource's stop.
    function Cis.scaleform.new(name, timeout)
        return engine('scaleform'):create(name, timeout)
    end

    -- A DUI OBJECT: .dictName / .txtName for drawing, :setUrl, :sendMessage,
    -- :destroy. Destroyed on this resource's stop.
    function Cis.dui.new(opts)
        return engine('dui'):create(opts)
    end

    -- Request the dictionary, play, release the dictionary.
    function Cis.anim.play(ped, dict, clip, opts)
        return engine('anim'):play(ped, dict, clip, opts)
    end

    -- A refcounted hold: disabled every frame until every hold naming a control
    -- is released. Answers the hold id.
    function Cis.controls.disable(...)
        return engine('controls'):disable(...)
    end

    function Cis.controls.enable(id)
        return engine('controls'):enable(id)
    end

    function Cis.controls.isDisabled(control)
        return engine('controls'):isDisabled(control)
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

    -- A `restricted` group grants ACE only when cis_libs holds command.add_ace.
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

function Cis.cache()
    return false, 'client only'
end

function Cis.onCache()
    return false, 'client only'
end

function Cis.streaming.release()
    return false, 'client only'
end

function Cis.world.getClosestPed()
    return false, 'client only'
end

function Cis.world.getClosestVehicle()
    return false, 'client only'
end

function Cis.world.getClosestObject()
    return false, 'client only'
end

function Cis.world.getClosestPlayer()
    return false, 'client only'
end

function Cis.world.getNearbyPeds()
    return false, 'client only'
end

function Cis.world.getNearbyVehicles()
    return false, 'client only'
end

function Cis.world.getNearbyObjects()
    return false, 'client only'
end

function Cis.world.getNearbyPlayers()
    return false, 'client only'
end

function Cis.vehicle.getProperties()
    return false, 'client only'
end

function Cis.vehicle.setProperties()
    return false, 'client only'
end

function Cis.marker.add()
    return false, 'client only'
end

function Cis.marker.remove()
    return false, 'client only'
end

function Cis.marker.clear()
    return false, 'client only'
end

function Cis.scaleform.new()
    return false, 'client only'
end

function Cis.dui.new()
    return false, 'client only'
end

function Cis.anim.play()
    return false, 'client only'
end

function Cis.controls.disable()
    return false, 'client only'
end

function Cis.controls.enable()
    return false, 'client only'
end

function Cis.controls.isDisabled()
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
-- opts (server only): { remote, ace, schema, maxStringLen } -- see RegisterCallback.
function Cis.callback.register(name, handler, opts)
    if opts == nil then
        return exportCall('RegisterCallback', name, handler)
    end
    return exportCall('RegisterCallback', name, handler, opts)
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
    ringbuffer = { path = 'shared/algo/ringbuffer.lua', global = 'CisRingBuffer', deps = {} },
    set = { path = 'shared/algo/set.lua', global = 'CisSet', deps = {} },
    sparse = { path = 'shared/algo/sparse.lua', global = 'CisSparse', deps = {} },
    window = { path = 'shared/algo/window.lua', global = 'CisWindow', deps = {} },
    array = { path = 'shared/util/array.lua', global = 'CisArray', deps = {} },
    class = { path = 'shared/util/class.lua', global = 'CisClass', deps = {} },
    cron = { path = 'shared/util/cron.lua', global = 'CisCron', deps = {} },
    id = { path = 'shared/util/id.lua', global = 'CisId', deps = {} },
    json = { path = 'shared/util/json.lua', global = 'CisJson', deps = {} },
    locale = { path = 'shared/util/locale.lua', global = 'CisLocale', deps = {} },
    mathx = { path = 'shared/util/mathx.lua', global = 'CisMathX', deps = {} },
    print = { path = 'shared/util/print.lua', global = 'CisPrint', deps = {} },
    semver = { path = 'shared/util/semver.lua', global = 'CisSemver', deps = {} },
    string = { path = 'shared/util/string.lua', global = 'CisString', deps = {} },
    table = { path = 'shared/util/table.lua', global = 'CisTable', deps = {} },
    time = { path = 'shared/util/time.lua', global = 'CisTime', deps = {} },
    timer = { path = 'shared/util/timer.lua', global = 'CisTimer', deps = {} },
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
-- cache. Built-in modules are cached under their name; a consumer module under its
-- canonical '@resource/path.lua'.
local requireCache = {}

-- THE IN-PROGRESS SET, and the stack that names a cycle. A module that requires
-- itself -- directly, or through a chain that comes back round -- used to recurse
-- until the C stack ran out, and the error that finally surfaced named neither
-- module. Now the second entry raises at once with the whole chain.
local requireLoading = {}
local requireStack = {}

local function beginLoad(key)
    if requireLoading[key] then
        local chain = {}
        local from = 1
        for i = 1, #requireStack do
            if requireStack[i] == key then from = i break end
        end
        for i = from, #requireStack do chain[#chain + 1] = requireStack[i] end
        chain[#chain + 1] = key
        error(('Cis.require: circular dependency %s'):format(table.concat(chain, ' -> ')), 3)
    end
    requireLoading[key] = true
    requireStack[#requireStack + 1] = key
end

local function endLoad(key)
    requireLoading[key] = nil
    for i = #requireStack, 1, -1 do
        if requireStack[i] == key then
            table.remove(requireStack, i)
            break
        end
    end
end

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

-- A CONSUMER'S OWN MODULE: '@resource/path/to/mod', or a path relative to the
-- resource calling Cis.require ('path.to.mod', 'path/to/mod', './mod'). Dots are
-- separators unless the name already uses '/', so 'client.utils' and
-- 'client/utils' are the same file, client/utils.lua. A plain name with no
-- separator is NOT a path -- it is a built-in name or a typo, and a typo must be
-- told the valid names rather than go looking for a file.
--
-- Answers resource, path or nil, reason.
local function resolveModulePath(name)
    local resource, rest
    if name:sub(1, 1) == '@' then
        resource, rest = name:match('^@([^/]+)/(.+)$')
        if not resource then
            return nil, ('%q names no file: use @resource/path/to/module'):format(name)
        end
    else
        resource, rest = THIS, name
        if rest:sub(1, 2) == './' then
            rest = rest:sub(3)
        elseif not rest:find('[%./]') then
            return nil, nil
        end
    end
    rest = rest:gsub('%.lua$', '')
    if not rest:find('/', 1, true) then
        rest = rest:gsub('%.', '/')
    end
    -- Inside the resource, always. No absolute path, no parent step, no empty
    -- segment, no backslash: the loader reads files, and a name is not allowed to
    -- become a walk through somebody else's folder.
    if rest == '' or rest:sub(1, 1) == '/' or rest:find('\\', 1, true) then
        return nil, ('%q is not a path inside a resource'):format(name)
    end
    for segment in (rest .. '/'):gmatch('(.-)/') do
        if segment == '' or segment == '.' or segment == '..' then
            return nil, ('%q is not a path inside a resource (empty, . or .. segment)'):format(name)
        end
    end
    return resource, rest .. '.lua'
end

-- Load one consumer module. A sandboxed environment of its own: reads fall
-- through to the resource's globals, and writes land in the module's private
-- table instead of the resource's -- the same isolation ox_lib's lib.require
-- gives, so two modules cannot clobber each other's helpers by accident.
local function requireFile(name, resource, path)
    local key = ('@%s/%s'):format(resource, path)
    local cached = requireCache[key]
    if cached ~= nil then
        return cached
    end
    beginLoad(key)
    local ok, result = pcall(function()
        local src = LoadResourceFile(resource, path)
        if type(src) ~= 'string' then
            error(('Cis.require: %s: %s was not found in resource %s'):format(name, path, resource), 0)
        end
        -- _ENV, not _G: the CALLING resource's globals, which is what its own
        -- files expect to see.
        local env = setmetatable({}, { __index = _ENV })
        -- TEXT ONLY. A precompiled chunk can do things source cannot, and nothing a
        -- resource ships for this loader has a reason to be bytecode.
        local chunk, compileErr = load(src, ('@@%s/%s'):format(resource, path), 't', env)
        if not chunk then
            error(('Cis.require: %s failed to compile: %s'):format(key, tostring(compileErr)), 0)
        end
        local value = chunk(name, key)
        -- Lua's own require stores true for a module that returns nothing, so a
        -- second require answers instead of running the file again.
        if value == nil then
            value = true
        end
        return value
    end)
    endLoad(key)
    if not ok then
        error(result, 2)
    end
    requireCache[key] = result
    return result
end

-- A module, loaded on demand, with no global left behind.
function Cis.require(name)
    if type(name) ~= 'string' then
        error(('Cis.require: module name must be a string, got %s. Valid names: %s')
            :format(type(name), table.concat(REQUIRE_NAMES, ', ')), 2)
    end
    local spec = REQUIRE_MODULES[name]
    if not spec then
        local resource, path = resolveModulePath(name)
        if resource then
            return requireFile(name, resource, path)
        end
        if path then
            error('Cis.require: ' .. path, 2)
        end
        error(('Cis.require: no module named %q. Valid names: %s. A module of your own '
            .. 'is a path: Cis.require(\'folder.file\') or Cis.require(\'@resource/folder/file\')')
            :format(name, table.concat(REQUIRE_NAMES, ', ')), 2)
    end
    if requireCache[name] then
        return requireCache[name]
    end

    beginLoad(name)
    local ok, result = pcall(function()
        local src = LoadResourceFile('cis_libs', spec.path)
        if not src then
            error(('Cis.require: %s could not be read from the resource. Is it listed '
                .. 'in fxmanifest.lua files {}?'):format(spec.path), 0)
        end
        local chunk, compileErr = load(src, '@cis_libs/' .. spec.path, 't', sandboxFor(spec))
        if not chunk then
            error(('Cis.require: %s failed to compile: %s'):format(spec.path, tostring(compileErr)), 0)
        end
        -- THE MARKER. The module's own tail reads `...`, and this argument is the only
        local loaded, value = pcall(chunk, 'cis_require')
        if not loaded then
            error(('Cis.require: %s raised while loading: %s'):format(spec.path, tostring(value)), 0)
        end
        if type(value) ~= 'table' then
            error(('Cis.require: %s did not return a table (got %s). A module must end '
                .. 'with `return M`.'):format(spec.path, tostring(value)), 0)
        end
        return value
    end)
    endLoad(name)
    if not ok then
        error(result, 2)
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
        -- A COPY. Handing out spec.deps itself let a caller edit the loader's own
        -- dependency map through the answer to a question.
        deps = { table.unpack(spec.deps) },
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

-- WHICH OF THE BUILT-IN MODULE GLOBALS EXIST ON THIS REALM, and what has been required.
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

-- ============================================ the consumer-side engines
--
-- client/core/*.lua, loaded into THIS VM on first use -- the same machinery as
-- Cis.require: a closed allow-list of paths, LoadResourceFile from cis_libs,
-- text-only `load`, the shared cycle guard, one instance per VM. The engines
-- cis_libs also runs are client_scripts (it publishes them under CisCore, and
-- its own VM reuses those); the consumer-only ones are listed in `files {}`.
--
-- A WRITE TO A GLOBAL RAISES, as for a built-in module: an engine returns its
-- table, and its tail publishes CisCore only when it is NOT loaded this way.
local CORE_PATHS = {
    zones = 'client/core/zones.lua',
    points = 'client/core/points.lua',
    keybind = 'client/core/keybind.lua',
    world = 'client/core/world.lua',
    raycast = 'client/core/raycast.lua',
    streaming = 'client/core/streaming.lua',
    vehicle = 'client/core/vehicle.lua',
    mirror = 'client/core/mirror.lua',
    marker = 'client/core/marker.lua',
    scaleform = 'client/core/scaleform.lua',
    dui = 'client/core/dui.lua',
    anim = 'client/core/anim.lua',
    controls = 'client/core/controls.lua',
}

local coreCache = {}
local geometry

-- One file of cis_libs, compiled into `chunkEnv`. TEXT ONLY, like every other
-- chunk this file compiles.
local function compileCore(path, chunkEnv)
    local src = LoadResourceFile(RESOURCE, path)
    if type(src) ~= 'string' then
        error(('Cis: %s could not be read from %s. Is it listed in its fxmanifest.lua?')
            :format(path, RESOURCE), 0)
    end
    local chunk, err = load(src, ('@@%s/%s'):format(RESOURCE, path), 't', chunkEnv)
    if not chunk then
        error(('Cis: %s failed to compile: %s'):format(path, tostring(err)), 0)
    end
    return chunk
end

loadCore = function(name)
    local cached = coreCache[name]
    if cached ~= nil then
        return cached
    end
    local path = CORE_PATHS[name]
    if not path then
        error(('Cis: no engine named %q'):format(tostring(name)), 2)
    end
    -- cis_libs' own VM already ran the client_script copy: reuse it.
    local published = IS_SELF and rawget(_G, 'CisCore')
    if published and published[name] then
        coreCache[name] = published[name]
        return published[name]
    end
    local key = 'core:' .. name
    beginLoad(key)
    local ok, result = pcall(function()
        local sandbox = setmetatable({}, {
            __index = _ENV,
            __newindex = function(_, global)
                error(('Cis: engine %s assigned the global %q; an engine returns its table')
                    :format(name, tostring(global)), 2)
            end,
        })
        local value = compileCore(path, sandbox)('cis_require')
        if type(value) ~= 'table' then
            error(('Cis: %s did not return a table'):format(path), 0)
        end
        return value
    end)
    endLoad(key)
    if not ok then
        error(result, 2)
    end
    coreCache[name] = result
    return result
end

-- CisGrid and CisZoneGeom for this VM. Both files are shared_scripts that DEFINE
-- those globals; loaded here, their writes land in a private table, so a
-- consumer gets the exact containment math cis_libs and the server use without
-- either name appearing among its own globals.
loadGeometry = function()
    if geometry then
        return geometry
    end
    if IS_SELF and rawget(_G, 'CisGrid') and rawget(_G, 'CisZoneGeom') then
        geometry = { CisGrid = CisGrid, CisZoneGeom = CisZoneGeom }
        return geometry
    end
    local geoEnv = setmetatable({}, { __index = _ENV })
    compileCore('shared/grid.lua', geoEnv)()
    compileCore('shared/zonegeom.lua', geoEnv)()
    geometry = { CisGrid = rawget(geoEnv, 'CisGrid'), CisZoneGeom = rawget(geoEnv, 'CisZoneGeom') }
    return geometry
end
