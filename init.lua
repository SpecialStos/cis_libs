-- The whole `Cis.*` surface. A consumer adds one line to its manifest:
--
--     shared_script '@cis_libs/init.lua'
--
-- `shared_script` COPIES this file into the consumer's Lua VM. It does not
-- share anything. What the consumer gets is a proxy: a set of functions, most
-- of which forward across the exports boundary to reach the real state inside
-- cis_libs. A consumer that expects to read Config, Security, the zone grid or
-- CisCache after this line gets nothing -- those are globals in a different
-- process, and this file is the whole of what crossed.
--
-- Reading the copy tells you which realm you are in, which is the only
-- distinction this file needs to make:
--
--   IS_SELF  this copy is inside cis_libs, so cis_libs's own globals are
--            reachable directly and nothing needs to be forwarded
--   else     this copy is inside a consumer, so every read and every mutation
--            has to go out over an export and back
--
-- Hot-path reads stay in this VM. Cross-resource work goes through exports.

local RESOURCE = 'cis_libs'
local THIS = GetCurrentResourceName()
-- True when this copy of the file belongs to cis_libs itself. Every hot read
-- below branches on it: inside, the cache table is a local lookup; outside, it
-- is an export call plus a per-frame memo. See the coords() comment.
local IS_SELF = THIS == RESOURCE
local IS_SERVER = IsDuplicityVersion()

Cis = Cis or {}
Cis.resource = RESOURCE
Cis.isReady = Cis.isReady or false
Cis.isFailed = Cis.isFailed or false

local EXPORT_TABLE = exports[RESOURCE]

-- Every export call in this file goes through here, and the reason is the trap
-- that has cost this library more debugging time than anything else in it.
--
-- `exports[resource][name](...)` looks equivalent to `exports[resource]:name(...)`
-- but is not: the bracket form yields an UNBOUND method, so the exports table
-- is expected as the first argument. Calling it without self shifts every
-- argument one place left -- a zone created as (kind, name, coords) arrived as
-- (name, coords, size), silently turning the name into the coordinates.
--
-- The bracket LOOKUP is broken the same way and by the same one slot:
-- `exports[resource][name]` is a bare function that expects the exports table as
-- its first argument. Reading it and calling it with real arguments is the same
-- shift. Passing the table explicitly is exactly what the colon syntax does, and
-- it is the only correct form when the name is dynamic.
--
-- This exact mistake was in this file, in this helper. It raised nothing: a
-- caller saw a wrong value in the wrong slot and had no way to tell that the
-- value had moved.
local function exportCall(name, ...)
    return EXPORT_TABLE[name](EXPORT_TABLE, ...)
end

-- Same call, but a refusal is a value rather than a crash. The fallible exports
-- answer `false, '<reason>'`; an export called before cis_libs is ready answers
-- nothing at all, and a proxy that threw would take the caller's thread with it.
-- Four values are carried back, which is more than any caller here needs --
-- Cis.player.vehicle reads the second one (the seat), and nothing reads a third.
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

-- Realm split. A consumer calls only the half that matches where it is; the
-- other half is simply absent, and calling it is a nil-index error rather than
-- a silent no-op.
if not IS_SERVER then
    local coordFrame = -1
    local coordValue
    local coordPed = 0

    -- The only place the two call styles are visible, so it is worth reading
    -- once. Inside cis_libs the cache is a table this VM owns; inside a consumer
    -- it is not, so the value has to be fetched. Both paths land in the same
    -- two lines below, and neither one crosses.
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

    -- FREE, and memoised to one native per frame per calling VM. The memo keys on
    -- the frame AND the ped, because a respawn hands out a new ped inside a frame
    -- that is still current, and keying on the frame alone would serve the dead
    -- one's coordinates until the next tick.
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

    -- FREE. The heading is refreshed on the same watchdog tick as the ped, at
    -- the same cadence, so reading it costs a field read rather than a native.
    function Cis.player.heading()
        if IS_SELF and CisCache then
            return CisCache.heading
        end
        return GetEntityHeading(currentPed())
    end

    -- The three player.* calls above are free. The three below CROSS, and
    -- Cis.inventory.count further down is the fourth: they resolve inside
    -- cis_libs, so each is an export call, a marshal, and a return trip. That
    -- is fine at a zone creation or a keypress and ruinous in a Wait(0) loop.
    -- Subscribe instead:
    --
    --   Cis.player.on('vehicle', fn)   -- one crossing per change
    --
    -- Cache the serverId at spawn; it does not change while the player is
    -- connected, so there is nothing to refresh.

    -- CROSSES. Returns nil rather than 0 when the player is on foot; a consumer
    -- that treats 0 as a handle gets a nil-index crash somewhere else.
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

    -- CROSSES. A fresh table whenever the weapon or its ammo changes, never a
    -- mutation of the previous one: a consumer holding a reference across frames
    -- is holding a snapshot, not a live view.
    function Cis.player.weapon()
        if IS_SELF and CisCache then
            return CisCache.weapon
        end
        return tryExport('GetCachedWeapon')
    end

    -- CROSSES. Falls back to the native when the cache has not been populated,
    -- so it answers something even before the watchdog has run once.
    function Cis.player.serverId()
        if IS_SELF and CisCache then
            return CisCache.serverId
        end
        return tryExport('GetCachedServerId') or GetPlayerServerId(PlayerId())
    end

    -- The unsubscribe function is a RETURN, and a returned function does survive
    -- the boundary -- it arrives as a callable reference table, which is callable
    -- but reports type() == 'table'. The listener `cb` is an ARGUMENT, and an
    -- argument is dropped. So from a consumer this call delivers a usable
    -- teardown and a listener that never fires. Gate the listener on your own
    -- flag and drop it in onResourceStop; that works in every build.
    function Cis.player.on(key, cb)
        return exportCall('OnPlayerCache', key, cb)
    end

    -- onEnter/onExit cannot cross the boundary; pass event names instead when
    -- calling from another resource. Receives (distance) on the server.
    function Cis.player.near(coords, distance, onEnter, onExit, onEnterEvent, onExitEvent)
        return exportCall('WatchNear', coords, distance, onEnter, onExit, onEnterEvent, onExitEvent)
    end

    -- Zones cross, and refuse out loud: each returns `false, '<reason>'` on the
    -- way back, because a consumer on the other side cannot read cis_libs's
    -- console. Always capture the second value -- a bare `false` tells you
    -- nothing you did not already guess.
    --
    -- `kind` is the first argument and lands first: this is the call that the
    -- bracket-form bug used to shift, turning the zone name into its own
    -- coordinates. The function options (onEnter/onExit/inside) are ARGSUMENTS
    -- and arrive nil from a consumer, so use the onEnterEvent/onExitEvent/
    -- insideEvent twins, which are strings and do cross.
    function Cis.zones.poly(name, points, options)
        return exportCall('CreateZone', 'poly', name, points, options)
    end

    function Cis.zones.box(name, center, size, options)
        return exportCall('CreateZone', 'box', name, center, size, options)
    end

    function Cis.zones.sphere(name, center, radius, options)
        return exportCall('CreateZone', 'sphere', name, center, radius, options)
    end

    -- `false` for an unknown name, deliberately: removing a zone twice, or one
    -- that was never created, is a no-op and not an error.
    function Cis.zones.remove(name)
        return exportCall('RemoveZone', name)
    end

    function Cis.zones.contains(name, point)
        return exportCall('ZoneContains', name, point)
    end

    -- Targets cross on the same terms as zones, including the two-value refusal.
    -- `update` is a remove-and-recreate internally, so treat it as a rebuild
    -- rather than a patch on the provider's zone.
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

    -- CROSSES. Client counts are a pushed snapshot maintained inside cis_libs,
    -- so this is a table read over the boundary and nothing more -- but it is
    -- still a crossing, and it is a HINT. Never gate a server-side action on it.
    function Cis.inventory.count(item)
        return exportCall('InventoryCount', item)
    end

    -- Free of a crossing: has() is built on the local result of count() rather
    -- than re-reading through the boundary.
    function Cis.inventory.has(item, amount)
        local count = Cis.inventory.count(item)
        return (count or 0) >= (amount or 1)
    end
else
    -- Server half. Everything here crosses, with no free-read exceptions: a
    -- server-side consumer VM is a different process with its own idea of what
    -- is true, so the answers are always fetched rather than read.
    --
    -- `Cis.inventory.count` is the one name in this file that exists on both
    -- sides of the realm split with a DIFFERENT signature -- (src, item) here,
    -- (item) on the client. A consumer that shares a helper between realms has
    -- to branch on IsDuplicityVersion() rather than on the function.

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
    -- Config.Framework.Database.Timeout, returning nil. A nil from here means
    -- "timed out or driver not ready", not "no rows" -- use scalar/single for
    -- emptiness. `transaction` is oxmysql's shape only and refuses promptly
    -- anywhere else instead of burning the timeout.
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

    -- `fn` is a function being SENT, not returned, so the exports boundary
    -- drops it. From a consumer the event still gets registered and still gets
    -- source and rate-limit checks, but the handler arrives nil and every
    -- invocation raises inside the protected call. RegisterNetEvent plus your
    -- own source check is the working form today; see the known-defect list in
    -- COMPATIBILITY.md.
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

-- A function cannot be SENT across the exports boundary, so `handler` may be:
--   a function            -- only works when cis_libs itself calls this
--   'resource:exportName' -- dispatched on demand from that resource
--
-- The second form is the one that works from a consumer, and it works for the
-- opposite reason: cis_libs returns the exported function to itself, so it
-- arrives as a callable reference table rather than being dropped. That table
-- reports type() == 'table', so the dispatcher must not test for 'function'.
-- Its return value may still come back nil -- signal results by side effect or
-- by net event until that is resolved. Returns true/false; a false means the
-- handler was a dropped function and nothing was registered.
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
    --
    -- This is the shape that works end to end: the server names the callback
    -- and the CLIENT's own handler runs there, so no function ever has to
    -- cross. `cb` is likewise a consumer-side function consumed on the consumer
    -- side, so it does not cross either.
    function Cis.callback.callClient(src, name, cb, ...)
        return exportCall('CallCallbackClient', name, src, cb, ...)
    end

    function Cis.callback.awaitClient(src, name, ...)
        return exportCall('AwaitCallbackClient', name, src, ...)
    end
end

-- Returns true once registered, false when it is refused (no id, already
-- registered, or the invoking resource is not allow-listed). On the server that
-- verdict is the server's own and is returned immediately; the broadcast to
-- clients happens alongside it and is not waited on, so a client that refused
-- the same door is not reported back here.
function Cis.doors.add(data)
    return exportCall('AddDoorToSystem', data)
end

-- A REQUEST, not a command, on the client: the server re-checks job permission
-- and distance before anything is applied. On the server it is applied
-- directly. Either way the answer is not the current state -- read Cis.doors.get
-- for that, and remember it is the client's cached hint, not authority.
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

-- `kind` leads and is the discriminator the server keys its records on, so
-- ped/prop/vehicle collapse into one export with no ambiguity. Calling any of
-- these again with the same id MOVES the entity rather than respawning it, as
-- long as the model and kind are unchanged.
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

-- Debug is gated on Config.Printing.Debug and is usually silent; the other
-- three always print. That asymmetry is deliberate -- a warning suppressed by a
-- debug flag is a warning nobody ever sees. tryExport rather than exportCall, so
-- a resource that stopped before this one does not take the caller's thread
-- down over a log line.
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
