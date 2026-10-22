-- Player cache. One cheap pass every 100-250 ms; change events for every key.
--
-- This is the singleton every other client module reads instead of calling
-- natives, and the reason `Cis.player.vehicle()` and friends are a boundary
-- crossing for a consumer: this table exists in exactly
-- one VM. A `shared_script` of this file is not a second view of these values,
-- it is a second cache with a second watchdog thread polling the same ped.
--
-- THE PASS IS THE SOURCE OF TRUTH, AND IT IS CHEAP. About a dozen natives, no
-- seat scan unless the cached seat stopped being true, and weapon attachments
-- only when the weapon itself changes. That is what lets it run at 4-10 Hz:
-- at the old 1 Hz a seat shuffle was a second stale and `IsPedShooting`, which
-- is true for a frame or two per shot, was never seen at all.
--
-- Coordinates are NOT cached or emitted here. `Cis.player.coords()` is already
-- memoised to one native per frame, which is fresher than any poll.

CisCache = {
    ped = 0,
    playerId = 0,
    serverId = 0,
    heading = 0.0,
    vehicle = 0,
    seat = nil,
    weapon = nil,
    armed = false,
    aiming = false,
    shooting = false,
}

-- The keys a listener may subscribe to. A typo is refused rather than accepted
-- into a list that never fires.
local KEYS = {
    ped = true,
    heading = true,
    vehicle = true,
    seat = true,
    weapon = true,
    armed = true,
    aiming = true,
    shooting = true,
}

-- key -> array of { id, cb }. Replaced, never edited in place, when a listener
-- leaves: an emit already walking the old array is not disturbed by a listener
-- that unsubscribes from inside its own callback.
local listeners = {}
local listenerKey = {}
local listenerSeq = 0
-- who asked for which listener, so a consumer's stop takes its listeners (and
-- their dead funcrefs) with it.
local listenerOwned = CisOwned.new()

local nearWatchers = {}
local nearSeq = 0
-- who asked for which near watcher. See shared/owned.lua.
local nearOwned = CisOwned.new()
local UNARMED = `WEAPON_UNARMED`

-- THE PASS INTERVAL. `Config.UpdateInterval.Player` defaults to 1000 ms in
-- shared/defaults.lua, which is a fallback-poll number from when events did the
-- work; the pass now IS the work, so the value is clamped into the range where
-- a seat change, an aim and a shot are actually observed.
local PASS_DEFAULT_MS = 200
local PASS_MIN_MS = 100
local PASS_MAX_MS = 250

local function passInterval()
    local intervals = Config and Config.UpdateInterval
    local wanted = type(intervals) == 'table' and tonumber(intervals.Player) or nil
    if not wanted or wanted ~= wanted then
        return PASS_DEFAULT_MS
    end
    return math.max(PASS_MIN_MS, math.min(PASS_MAX_MS, wanted))
end

-- THE PUSH TO EVERY CONSUMER'S MIRROR (client/core/mirror.lua). A LOCAL client
-- event, so it reaches every resource on this client and no server. One event
-- per changed key per pass -- a standing player produces none -- and a consumer
-- reading `Cis.player.vehicle()` then reads its own table instead of crossing
-- into this VM on every call. `seat` rides on the 'vehicle' push so the two land
-- together on the far side too; `silent` refreshes a value without announcing a
-- change (the same weapon with new ammo, which fires no listener here either).
local function push(key, value, seat, silent)
    TriggerEvent('cis_libs:cache', key, value, seat, silent)
end

-- HEADING IS PUSHED ONLY TO A CONSUMER THAT LISTENS FOR IT. It changes several
-- times a second while the player moves, and every push is a TriggerEvent
-- dispatched into every client resource's runtime. A consumer mirror asks for
-- it (FollowCacheHeading) when its first heading listener is added; a read of
-- the heading uses the native and needs none of this.
local headingFollowers = CisOwned.new()

local function headingFollowed()
    return next(headingFollowers.byKind) ~= nil
end

local function emit(key, current, previous)
    local list = listeners[key]
    if not list then
        return
    end
    for i = 1, #list do
        local ok, err = pcall(list[i].cb, current, previous)
        if not ok then
            CisLog('error', 'cache listener: ' .. tostring(err))
        end
    end
end

-- publishGlobals exists for the compatibility shims (GetGlobals) and for
-- consumers that were written against the old global shape.
local function publishGlobals()
    Globals = Globals or {}
    Globals.ServerInfo = Globals.ServerInfo or {
        GameBuild = GetGameBuildNumber(),
        Framework = Config and Config.Framework,
        Debug = Config and Config.Printing and Config.Printing.Debug,
    }
    local ped = CisCache.ped ~= 0 and CisCache.ped or PlayerPedId()
    local coords = GetEntityCoords(ped)
    local player = Globals.Player
    if not player then
        player = {}
        Globals.Player = player
    end
    player.Ped = ped
    player.PedId = CisCache.playerId
    player.ServerId = CisCache.serverId
    player.Coords = coords
    player.Heading = CisCache.heading
    player.Coords4 = vec4(coords.x, coords.y, coords.z, CisCache.heading)
    player.IsArmed = CisCache.armed
    player.IsShooting = CisCache.shooting
    player.IsAiming = CisCache.aiming
    player.IsInVehicle = CisCache.vehicle ~= 0
    player.Weapon = CisCache.weapon
    local vehicle = Globals.Vehicle
    if not vehicle then
        vehicle = {
            Properties = {},
            LastPropertiesAt = 0,
        }
        Globals.Vehicle = vehicle
    end
    vehicle.Current = CisCache.vehicle
    vehicle.Last = CisCache.vehicle
    vehicle.Seat = CisCache.seat
end

-- setField returns whether anything changed, and a listener only fires on a
-- change: an unchanged value produces no work at all.
local function setField(key, value)
    local previous = CisCache[key]
    if previous == value then
        return false
    end
    CisCache[key] = value
    emit(key, value, previous)
    if key ~= 'heading' or headingFollowed() then
        push(key, value)
    end
    return true
end

-- VEHICLE AND SEAT LAND TOGETHER. Both are written before EITHER listener runs,
-- so a 'vehicle' listener reading CisCache.seat sees the new seat, and a 'seat'
-- listener reading CisCache.vehicle sees the new vehicle. Emitting the vehicle
-- first with the old seat still cached is how a driver-only listener ran for a
-- passenger.
local function setVehicleSeat(vehicle, seat)
    local prevVehicle, prevSeat = CisCache.vehicle, CisCache.seat
    CisCache.vehicle = vehicle
    CisCache.seat = seat
    if prevVehicle ~= vehicle then
        emit('vehicle', vehicle, prevVehicle)
    end
    if prevSeat ~= seat then
        emit('seat', seat, prevSeat)
    end
    if prevVehicle ~= vehicle or prevSeat ~= seat then
        push('vehicle', vehicle, seat)
    end
end

local function weaponPayload(ped, hash)
    if not hash or hash == 0 or hash == UNARMED then
        return nil
    end
    return {
        hash = hash,
        ammo = GetAmmoInPedWeapon(ped, hash),
        ammoType = GetPedAmmoTypeFromWeapon(ped, hash),
        attachments = GetWeaponAttachments(ped, hash),
    }
end

local function refreshPed()
    local playerId = PlayerId()
    local ped = PlayerPedId()
    if playerId ~= CisCache.playerId or CisCache.serverId == 0 then
        local serverId = GetPlayerServerId(playerId)
        local changed = playerId ~= CisCache.playerId or serverId ~= CisCache.serverId
        CisCache.playerId = playerId
        CisCache.serverId = serverId
        if changed then
            push('playerId', playerId)
            push('serverId', serverId)
        end
    end
    setField('ped', ped)
    setField('heading', GetEntityHeading(ped))
    return ped
end

local function seatIndexOf(ped, vehicle)
    if GetPedInVehicleSeat(vehicle, -1) == ped then
        return -1
    end
    local maxPassengers = GetVehicleMaxNumberOfPassengers(vehicle)
    for i = 0, maxPassengers - 1 do
        if GetPedInVehicleSeat(vehicle, i) == ped then
            return i
        end
    end
    return nil
end

local function refreshVehicle(ped)
    ped = ped or CisCache.ped
    if ped == 0 or not IsPedInAnyVehicle(ped, false) then
        setVehicleSeat(0, nil)
        return
    end
    local vehicle = GetVehiclePedIsIn(ped, false)
    if vehicle == 0 then
        setVehicleSeat(0, nil)
        return
    end
    -- THE SEAT IS RE-VERIFIED EVERY PASS. It used to be re-derived only when the
    -- cached value was missing, so a shuffle or a warp to another seat left the
    -- old seat cached for as long as the player stayed in the vehicle. Verifying
    -- the cached seat is ONE native; the scan runs only when it stopped being
    -- true.
    local seat = CisCache.seat
    if vehicle ~= CisCache.vehicle or type(seat) ~= 'number'
        or GetPedInVehicleSeat(vehicle, seat) ~= ped then
        seat = seatIndexOf(ped, vehicle)
    end
    setVehicleSeat(vehicle, seat)
end

-- ATTACHMENTS ARE RE-READ ON THE SAME WEAPON, at most this often. A suppressor
-- fitted while the weapon is held changes nothing the hash check sees, and the
-- cache answered the old attachments until the player switched weapons. One
-- HasPedGotWeaponComponent per component the weapon takes, once a second.
local ATTACHMENT_MS = 1000
local attachmentsReadAt = 0

local function sameList(a, b)
    if #a ~= #b then
        return false
    end
    for i = 1, #a do
        if a[i] ~= b[i] then
            return false
        end
    end
    return true
end

local function refreshWeapon(ped)
    ped = ped or CisCache.ped
    local armed = IsPedArmed(ped, 7)
    setField('armed', armed)
    if not armed then
        setField('weapon', nil)
        return
    end
    local hash = GetSelectedPedWeapon(ped)
    local current = CisCache.weapon
    if current and current.hash == hash then
        local now = GetGameTimer()
        if now - attachmentsReadAt >= ATTACHMENT_MS then
            attachmentsReadAt = now
            local attachments = GetWeaponAttachments(ped, hash)
            if not sameList(attachments, current.attachments or {}) then
                -- A different weapon as far as a listener is concerned.
                setField('weapon', {
                    hash = hash,
                    ammo = GetAmmoInPedWeapon(ped, hash),
                    ammoType = current.ammoType,
                    attachments = attachments,
                })
                return
            end
        end
        local ammo = GetAmmoInPedWeapon(ped, hash)
        if current.ammo ~= ammo then
            -- Replace rather than mutate: consumers hold a reference to the
            -- table they were handed, and the weapon did not change, so no
            -- listener fires.
            CisCache.weapon = {
                hash = hash,
                ammo = ammo,
                ammoType = current.ammoType,
                attachments = current.attachments,
            }
            push('weapon', CisCache.weapon, nil, true)
        end
        return
    end
    attachmentsReadAt = GetGameTimer()
    setField('weapon', weaponPayload(ped, hash))
end

-- `IsPlayerFreeAiming` and `GetPedConfigFlag` both answer a BOOLEAN in Lua.
--
-- Both were compared to 1, which is `true == 1` and therefore false for every
-- player at every moment. `CisCache.aiming` was never true, so every consumer
-- subscribed to it heard nothing, on a stock server, for the life of the
-- process -- with no error anywhere, because the code ran exactly as written.
local function aimingNow()
    local cfg = Config and Config.AimingCheckType or 'default'
    if cfg == 'configFlag' then
        return GetPedConfigFlag(CisCache.ped, 78) and true or false
    end
    return IsPlayerFreeAiming(CisCache.playerId) and true or false
end

-- THE GAME EVENT ONLY TRIGGERS A RE-READ. It never writes a value of its own.
--
-- `gameEventTriggered` is an ordinary local event name: any client resource can
-- TriggerEvent it with any arguments. The handler used to take the vehicle and
-- seat from those arguments -- for ANY player entering ANY vehicle, not just
-- this one -- and a separate handler listened on a bare
-- 'CEventNetworkPlayerEnteredVehicle' event that the game never raises and any
-- resource could raise to rewrite the cache. Now an event for the local player
-- asks the natives, which no resource can forge.
AddEventHandler('gameEventTriggered', function(name, args)
    if name ~= 'CEventNetworkPlayerEnteredVehicle' and name ~= 'CEventNetworkPlayerLeftVehicle' then
        return
    end
    if type(args) ~= 'table' or args[1] ~= PlayerId() then
        return
    end
    refreshVehicle(refreshPed())
end)

-- NEVER GIVE UP ON READINESS. initialize.lua marks the library ready at the same
-- 15 s these loops used to wait, so a waiter could lose that race, get `false`,
-- and return -- ending the cache for the session. A failed boot still runs on
-- the built-in defaults.
local function awaitReady()
    while not CisReadyState.wait(15000) do
        if CisReadyState.failed then
            return
        end
    end
end

-- One pass. Roughly a dozen natives: PlayerId, PlayerPedId, GetEntityHeading,
-- IsPedInAnyVehicle (+ GetVehiclePedIsIn and one GetPedInVehicleSeat in a
-- vehicle), IsPedArmed, GetSelectedPedWeapon, GetAmmoInPedWeapon,
-- IsPlayerFreeAiming, IsPedShooting, GetEntityCoords for the globals mirror.
local function cachePass()
    local ped = refreshPed()
    refreshVehicle(ped)
    refreshWeapon(ped)
    setField('aiming', aimingNow())
    setField('shooting', IsPedShooting(ped) and true or false)
    publishGlobals()
    -- Interval RETURNED, not waited on: a Wait inside the guard's pcall would
    -- swallow the yield that unwinds this loop. Re-read every pass, so a config
    -- re-push lands without a restart.
    return passInterval()
end

CreateThread(function()
    awaitReady()
    -- GUARDED (3.10). One raise in here used to end this loop for good.
    local tick = CisLoopGuard.Body('client.cache.pass', cachePass)
    while true do
        Wait(tick() or PASS_DEFAULT_MS)
    end
end)

-- Proximity watchers. ON DEMAND: the thread starts with the first watcher and
-- ends with the last, so a client with no watcher has no thread to wake (it
-- woke twice a second for nothing).
local nearDriving = false
local function driveNear()
    if nearDriving then
        return
    end
    nearDriving = true
    CreateThread(function()
        awaitReady()
        local lastCoords
        local lastCheck = 0
        -- GUARDED (3.10): this loop carries `lastCoords` and `lastCheck` across
        -- ticks, so a raise used to leave them stale AND end the loop.
        local tickNear = CisLoopGuard.Body('client.cache.near', function()
            if next(nearWatchers) == nil then
                return 500
            end
            local now = GetGameTimer()
            local coords = Cis.player.coords()
            local moved = not lastCoords or #(coords - lastCoords) >= 8.0
            if moved or (now - lastCheck) >= 500 then
                lastCoords = coords
                lastCheck = now
                for _, watcher in pairs(nearWatchers) do
                    local dist = #(coords - watcher.coords)
                    local inside = dist <= watcher.distance
                    if inside and not watcher.inside then
                        watcher.inside = true
                        if CisCallable(watcher.onEnter) then
                            pcall(watcher.onEnter, dist)
                        elseif watcher.onEnterEvent then
                            pcall(TriggerServerEvent, watcher.onEnterEvent, dist)
                        end
                    elseif not inside and watcher.inside then
                        watcher.inside = false
                        if CisCallable(watcher.onExit) then
                            pcall(watcher.onExit, dist)
                        elseif watcher.onExitEvent then
                            pcall(TriggerServerEvent, watcher.onExitEvent, dist)
                        end
                    end
                end
            end
            return 200
        end)
        while next(nearWatchers) ~= nil do
            Wait(tickNear() or 200)
        end
        nearDriving = false
    end)
end

local function dropListener(id)
    local key = listenerKey[id]
    if not key then
        return false
    end
    listenerKey[id] = nil
    CisOwned.forget(listenerOwned, 'listener', id)
    local old = listeners[key] or {}
    local list = {}
    for i = 1, #old do
        if old[i].id ~= id then
            list[#list + 1] = old[i]
        end
    end
    listeners[key] = list
    return true
end

--- Subscribe to one cache key.
--- @return function|nil, integer|string  the in-realm unsubscribe and the id, or nil and a reason
function CisCache.on(key, cb)
    if not KEYS[key] then
        return nil, ('unknown cache key %s; valid keys are aiming, armed, heading, ped, seat, shooting, vehicle and weapon')
            :format(tostring(key))
    end
    -- CisCallable: a consumer's listener arrives as a funcref table.
    if not CisCallable(cb) then
        return nil, ('a listener must be a function, got %s'):format(type(cb))
    end
    listenerSeq = listenerSeq + 1
    local id = listenerSeq
    local old = listeners[key] or {}
    local list = {}
    for i = 1, #old do
        list[i] = old[i]
    end
    list[#list + 1] = { id = id, cb = cb }
    listeners[key] = list
    listenerKey[id] = key
    CisOwned.track(listenerOwned, GetInvokingResource() or 'cis_libs', 'listener', id)
    -- The unsubscribe works in this realm only; a function RETURNED across the
    -- exports boundary arrives as something the consumer cannot call. The id is
    -- the handle that crosses: RemovePlayerCacheListener(id).
    return function()
        dropListener(id)
    end, id
end

--- Stop a listener by the id `on` returned. Only its owner, or cis_libs.
function CisCache.off(id)
    if type(id) ~= 'number' or not listenerKey[id] then
        return false, ('no cache listener with id %s'):format(tostring(id))
    end
    local caller = GetInvokingResource() or 'cis_libs'
    local owner = CisOwned.ownerOf(listenerOwned, 'listener', id)
    if caller ~= 'cis_libs' and caller ~= owner then
        return false, ('cache listener %s belongs to %s, not %s'):format(tostring(id), tostring(owner), caller)
    end
    return dropListener(id)
end

-- The enter/exit callbacks cannot be sent across the exports boundary, so a
-- caller that is not cis_libs must use the event forms instead:
--   onEnterEvent / onExitEvent, receiving (distance) as a server event.
-- STOP A WATCHER BY ITS ID. The half of the pair that survives the exports
-- boundary; see the RemoveNearWatcher export for why the returned unsubscribe
-- cannot be used from outside this realm.
function CisCache.removeNearWatcher(id)
    if type(id) ~= 'number' then
        return false, ('a watcher id is a number, got %s'):format(type(id))
    end
    local watcher = nearWatchers[id]
    if not watcher then
        return false, ('no watcher with id %s'):format(tostring(id))
    end
    -- Only its owner, or cis_libs, as for CisCache.off. Ids are sequential, so
    -- without this `for i = 1, 1e3 do RemoveNearWatcher(i) end` removed everyone's.
    local caller = GetInvokingResource() or 'cis_libs'
    local owner = CisOwned.ownerOf(nearOwned, 'nearWatcher', id)
    if caller ~= 'cis_libs' and caller ~= owner then
        return false, ('watcher %s belongs to %s, not %s'):format(tostring(id), tostring(owner), caller)
    end
    nearWatchers[id] = nil
    -- Same reason unsubscribe() forgets it: a watcher already removed by its
    -- owner must not also be counted by the stop sweep, or it reports a count
    -- that never happened.
    CisOwned.forget(nearOwned, 'nearWatcher', id)
    return true
end

function CisCache.watchNear(coords, distance, onEnter, onExit, onEnterEvent, onExitEvent)
    if coords == nil then
        -- The exports boundary can drop a value entirely; indexing nil would
        -- throw inside the caller's export call.
        return nil, 'coords arrived as nil (the exports boundary dropped them)'
    end
    nearSeq = nearSeq + 1
    local id = nearSeq
    nearWatchers[id] = {
        coords = vector3(coords.x, coords.y, coords.z),
        distance = distance or 2.0,
        onEnter = onEnter,
        onExit = onExit,
        onEnterEvent = onEnterEvent,
        onExitEvent = onExitEvent,
        inside = false,
    }
    local function unsubscribe()
        nearWatchers[id] = nil
        -- a watcher the caller has unsubscribed is one the ledger must
        -- stop owing, or the stop sweep will "release" it later and report a
        -- count that never happened.
        CisOwned.forget(nearOwned, 'nearWatcher', id)
    end
    -- a watcher outlives the resource that asked for it until the process
    -- restarts, and an abandoned watcher still costs a distance check every tick
    -- for as long as it lives.
    CisOwned.track(nearOwned, GetInvokingResource() or 'cis_libs', 'nearWatcher', id)
    driveNear()
    return unsubscribe, id
end

-- THE MIRROR'S ONE SNAPSHOT. Every key a consumer's mirror follows, in one call,
-- taken once per consumer (and again after a cis_libs restart). A fresh table:
-- a consumer receives a copy across the boundary anyway, and handing out
-- CisCache itself here would hand cis_libs' own record to anything in-VM.
exports('GetCacheSnapshot', function()
    return {
        ped = CisCache.ped,
        playerId = CisCache.playerId,
        serverId = CisCache.serverId,
        heading = CisCache.heading,
        vehicle = CisCache.vehicle,
        seat = CisCache.seat,
        weapon = CisCache.weapon,
        armed = CisCache.armed,
        aiming = CisCache.aiming,
        shooting = CisCache.shooting,
    }
end)

-- A consumer mirror with a heading listener. Released when that consumer stops.
exports('FollowCacheHeading', function()
    local owner = GetInvokingResource() or 'cis_libs'
    CisOwned.track(headingFollowers, owner, 'heading', owner)
    return true
end)

exports('GetCachedPed', function()
    return CisCache.ped ~= 0 and CisCache.ped or PlayerPedId()
end)

exports('GetCachedHeading', function()
    return CisCache.heading
end)

exports('GetCachedVehicle', function()
    if CisCache.vehicle == 0 then
        return nil
    end
    return CisCache.vehicle, CisCache.seat
end)

exports('GetCachedWeapon', function()
    return CisCache.weapon
end)

exports('GetCachedServerId', function()
    return CisCache.serverId
end)

exports('GetCachedPlayerId', function()
    return CisCache.playerId ~= 0 and CisCache.playerId or PlayerId()
end)

exports('GetCachedSeat', function()
    if CisCache.vehicle == 0 then
        return nil
    end
    return CisCache.seat
end)

exports('OnPlayerCache', function(key, cb)
    return CisCache.on(key, cb)
end)

-- The id-based half of OnPlayerCache, for the same reason RemoveNearWatcher
-- exists: the returned unsubscribe cannot be called from another resource.
exports('RemovePlayerCacheListener', function(id)
    return CisCache.off(id)
end)

exports('WatchNear', function(coords, distance, onEnter, onExit, onEnterEvent, onExitEvent)
    return CisCache.watchNear(coords, distance, onEnter, onExit, onEnterEvent, onExitEvent)
end)

-- STOPPING A WATCHER, IN A FORM A CONSUMER CAN ACTUALLY CALL.
--
-- `WatchNear` returns an unsubscribe function, and a function RETURNED across
-- the exports boundary has no representation on the other side: the consumer
-- gets a table and cannot call it. Passing a function IN works -- the library
-- holds it and invokes it in this realm -- which is why onEnter and onExit are
-- fine and the return value is not. The harness proved it on a live server:
-- `WatchNear returned table, not an unsubscribe function`.
--
-- So the id is the handle. `watchNear` already returns it as its second value;
-- this is the other half of the pair.
exports('RemoveNearWatcher', function(id)
    return CisCache.removeNearWatcher(id)
end)

-- A CONSUMER THAT STOPS TAKES ITS NEAR WATCHERS AND LISTENERS WITH IT.
--
-- A watcher is a per-tick distance check, and a listener left behind holds a
-- funcref into a resource that no longer exists -- it raises on every change
-- for the rest of the session.
AddEventHandler('onResourceStop', function(resource)
    -- A forged stop from another client script is ignored (shared/owned.lua).
    if not CisRealStop(resource) then
        return
    end
    if resource == GetCurrentResourceName() then
        return
    end
    if CisOwned.forget(headingFollowers, 'heading', resource) then
        CisOwned.release(headingFollowers, resource)
    end
    local freed = CisOwned.release(nearOwned, resource)
    local dropped = 0
    for i = 1, #freed do
        if freed[i].kind == 'nearWatcher' then
            nearWatchers[freed[i].id] = nil
            CisOwned.forget(nearOwned, 'nearWatcher', freed[i].id)
            dropped = dropped + 1
        end
    end
    local freedListeners = CisOwned.release(listenerOwned, resource)
    local droppedListeners = 0
    for i = 1, #freedListeners do
        if dropListener(freedListeners[i].id) then
            droppedListeners = droppedListeners + 1
        end
    end
    if dropped > 0 or droppedListeners > 0 then
        CisLog('info', ('cis_libs: released %d near watcher(s) and %d cache listener(s) owned by %s')
            :format(dropped, droppedListeners, tostring(resource)))
    end
end)

RegisterCommand('cis_debug', function()
    local zone = exports['cis_libs']:GetZoneDebug()
    print(('[cis_libs] ped=%s veh=%s armed=%s zonePassMs=%s'):format(
        tostring(CisCache.ped),
        tostring(CisCache.vehicle),
        tostring(CisCache.armed),
        tostring(zone and zone.lastPassMs)
    ))
end, false)
