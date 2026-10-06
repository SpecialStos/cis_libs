-- Event-driven player cache. Idle: 1s watchdog only. No Wait(0). No seat scans.
--
-- This is the singleton every other client module reads instead of calling
-- natives, and the reason `Cis.player.vehicle()` and friends are a boundary
-- crossing for a consumer: this table exists in exactly
-- one VM. A `shared_script` of this file is not a second view of these values,
-- it is a second cache with a second watchdog thread polling the same ped.

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

    local listeners = {
        ped = {},
        vehicle = {},
        seat = {},
        weapon = {},
        armed = {},
        aiming = {},
    }

local nearWatchers = {}
local nearSeq = 0
-- who asked for which near watcher. See shared/owned.lua.
local nearOwned = CisOwned.new()
local UNARMED = `WEAPON_UNARMED`

local function emit(key, current, previous)
    local list = listeners[key]
    if not list then
        return
    end
    for i = 1, #list do
        local ok, err = pcall(list[i], current, previous)
        if not ok then
            CisLog('error', 'cache listener: ' .. tostring(err))
        end
    end
end

-- publishGlobals exists for the compatibility shims (GetGlobals) and for
-- consumers that were written against the old global shape. It is the only
-- per-tick allocation in the module -- one vec4 -- and it is why the tick is
-- not tightened below 250ms without cost.
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
-- change. That is the entire reason the watchdog can run at 1Hz and consumers
-- can still trust an event-driven subscription: an unchanged value produces no
-- work at all.
local function setField(key, value)
    local previous = CisCache[key]
    if previous == value then
        return false
    end
    CisCache[key] = value
    emit(key, value, previous)
    return true
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

-- Seat index from a vehicle-entered event. The array form is
-- { vehicle, seatIndex } in some builds and { entity, vehicle, seatIndex } in
-- others, so the index is validated rather than trusted: a raw array read here
-- used to hand back the vehicle handle as a seat number.
local function readSeatFromEvent(data)
    if type(data) ~= 'table' then
        return nil
    end
    local named = data.seatIndex
    if named == nil and type(data.named) == 'table' then
        named = data.named.seatIndex
    end
    if type(named) == 'number' then
        return named
    end
    local last = data[#data]
    if type(last) == 'number' and last >= -1 and last <= 16 then
        return last
    end
    return nil
end

local function refreshPed()
    local playerId = PlayerId()
    local ped = PlayerPedId()
    CisCache.playerId = playerId
    CisCache.serverId = GetPlayerServerId(playerId)
    setField('ped', ped)
    CisCache.heading = GetEntityHeading(ped)
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
    if ped == 0 then
        setField('vehicle', 0)
        setField('seat', nil)
        return
    end
    local vehicle = GetVehiclePedIsIn(ped, false)
    if vehicle == 0 then
        setField('vehicle', 0)
        setField('seat', nil)
        return
    end
    setField('vehicle', vehicle)
    -- Re-derive whenever the cached seat is missing or out of the range a seat
    -- index can actually take, so a bad value never sticks.
    local seat = CisCache.seat
    if type(seat) ~= 'number' or seat < -1 or seat > 16 then
        setField('seat', seatIndexOf(ped, vehicle))
    end
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
        end
        return
    end
    setField('weapon', weaponPayload(ped, hash))
end

-- `IsPlayerFreeAiming` and `GetPedConfigFlag` both answer a BOOLEAN in Lua.
--
-- Both were compared to 1, which is `true == 1` and therefore false for every
-- player at every moment. `CisCache.aiming` was never true, so every consumer
-- subscribed to it heard nothing, on a stock server, for the life of the
-- process -- with no error anywhere, because the code ran exactly as written.
--
-- `GetPedConfigFlag` is the one place a number still appears: it returns an
-- integer bitmask, so a ped config flag is compared as a bit rather than as an
-- equality. That is also why 'configFlag' is not the real aiming state on
-- current builds -- see the default in shared/defaults.lua.
local function aimingNow()
    local cfg = Config and Config.AimingCheckType or 'default'
    if cfg == 'configFlag' then
        return GetPedConfigFlag(CisCache.ped, 78) and true or false
    end
    return IsPlayerFreeAiming(CisCache.playerId) and true or false
end

local function onEnteredVehicle(vehicle, seat)
    if type(vehicle) ~= 'number' or vehicle == 0 then
        return
    end
    -- Settle the seat before emitting, so a 'vehicle' listener never observes
    -- a stale seat alongside the new handle.
    setField('seat', seat)
    if seat == nil then
        refreshVehicle(CisCache.ped)
    end
    setField('vehicle', vehicle)
end

local function onLeftVehicle()
    setField('vehicle', 0)
    setField('seat', nil)
end

AddEventHandler('gameEventTriggered', function(name, args)
    if name == 'CEventNetworkPlayerEnteredVehicle' then
        refreshPed()
        onEnteredVehicle(args and args[2], type(args) == 'table' and readSeatFromEvent(args) or nil)
    elseif name == 'CEventNetworkPlayerLeftVehicle' then
        onLeftVehicle()
    end
end)

AddEventHandler('CEventNetworkPlayerEnteredVehicle', function(data)
    if type(data) ~= 'table' then
        return
    end
    onEnteredVehicle(data.vehicle or data[2], readSeatFromEvent(data))
end)

AddEventHandler('CEventNetworkPlayerLeftVehicle', onLeftVehicle)

-- The fallback poll. It exists because the game events are not sufficient on
-- their own: a respawn, a seat change with no matching event, or a weapon swap
-- can all leave the cache stale, and a stale cache is a desync the server has
-- to guess about. Events do the work between ticks; this is the floor.
CreateThread(function()
    if not CisReadyState.wait(15000) then
        return
    end

    -- Declared here and assigned inside the loop, which re-reads the config on
    -- every pass so an operator's change lands without a restart. Giving any of
    -- them a default here would be overwritten before anything read it.
    local intervals
    local playerMs
    local weaponMs

    refreshPed()
    refreshVehicle(CisCache.ped)
    refreshWeapon(CisCache.ped)

    local lastWeaponAt = 0
    -- GUARDED (3.10). One raise in here used to end this loop for
    -- good: the thread unwound and never came back, and the symptom
    -- -- callbacks timing out, props not spawning -- arrived minutes
    -- later with nothing connecting it to this line.
    local tick = CisLoopGuard.Body('client.cache.pass', function()
                -- THE INTERVALS ARE RE-READ EVERY PASS, not captured above.
                --
                -- The server re-pushes the client payload after SetConfig, so a client
                -- can be told a different interval mid-session -- and it was not
                -- listening. `playerMs` was read once before the loop, so the one value
                -- a re-push is most likely to change was the one value that could not,
                -- and the push looked like it had worked while nothing had.
                --
                -- Two table lookups and a `math.max` per pass, against a loop that
                -- already costs ten natives: not a measurable cost, and it is what makes
                -- the re-push mean anything.
                intervals = (Config and Config.UpdateInterval) or {}
                playerMs = math.max(100, intervals.Player or 1000)
                weaponMs = math.max(100, intervals.Weapon or playerMs)

                local ped = refreshPed()
                local inVeh = IsPedInAnyVehicle(ped, false)
                if inVeh then
                    refreshVehicle(ped)
                elseif CisCache.vehicle ~= 0 then
                    setField('vehicle', 0)
                    setField('seat', nil)
                end
                local now = GetGameTimer()
                if now - lastWeaponAt >= weaponMs then
                    lastWeaponAt = now
                    refreshWeapon(ped)
                end
                setField('aiming', aimingNow())
                CisCache.shooting = IsPedShooting(ped)
                publishGlobals()
                -- Interval RETURNED, not waited on: a Wait inside the guard's
                -- pcall would swallow the yield that unwinds this loop.
                return playerMs
    end)
    while true do
        Wait(tick() or playerMs)
    end
end)

-- Proximity watchers. Idle at 500ms with no watchers at all -- `next()` on an
-- empty table is the cheapest possible test, and a server with nothing near it
-- pays nothing for the feature existing.
CreateThread(function()
    if not CisReadyState.wait(15000) then
        return
    end
    local lastCoords
    local lastCheck = 0
    -- GUARDED (3.10): this loop carries `lastCoords` and `lastCheck` across
    -- ticks, so a raise used to leave them stale AND end the loop -- proximity
    -- watchers simply stopped firing for the rest of the session.
    local tickNear = CisLoopGuard.Body('client.cache.near', function()
        if next(nearWatchers) == nil then
            -- Idle, and the interval is RETURNED rather than waited on here:
            -- a Wait inside the guard's pcall would swallow the yield that
            -- unwinds this loop, so a stopped resource would keep ticking.
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
                    if watcher.onEnter then
                        pcall(watcher.onEnter, dist)
                    elseif watcher.onEnterEvent then
                        pcall(TriggerServerEvent, watcher.onEnterEvent, dist)
                    end
                elseif not inside and watcher.inside then
                    watcher.inside = false
                    if watcher.onExit then
                        pcall(watcher.onExit, dist)
                    elseif watcher.onExitEvent then
                        pcall(TriggerServerEvent, watcher.onExitEvent, dist)
                    end
                end
            end
        end
        return 200
    end)
    while true do
        Wait(tickNear() or 200)
    end
end)

function CisCache.on(key, cb)
    if type(cb) ~= 'function' then
        return
    end
    listeners[key] = listeners[key] or {}
    listeners[key][#listeners[key] + 1] = cb
    return function()
        local list = listeners[key]
        if not list then
            return
        end
        for i = #list, 1, -1 do
            if list[i] == cb then
                table.remove(list, i)
            end
        end
    end
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
    return unsubscribe, id
end

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
-- this is the other half of the pair. Without it a watcher can only be stopped
-- by its owner stopping, and it costs a distance check every tick for the life
-- of the server.
exports('RemoveNearWatcher', function(id)
    return CisCache.removeNearWatcher(id)
end)

-- A CONSUMER THAT STOPS TAKES ITS NEAR WATCHERS WITH IT ().
--
-- A watcher is a per-tick distance check on a coordinates table. A resource
-- that restarts leaks one every time, and the cost is invisible: no error, no
-- log line, just a server that gets marginally slower for as long as it is up.
AddEventHandler('onResourceStop', function(resource)
    if resource == GetCurrentResourceName() then
        return
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
    if dropped > 0 then
        CisLog('info', ('cis_libs: released %d near watcher(s) owned by %s')
            :format(dropped, tostring(resource)))
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

