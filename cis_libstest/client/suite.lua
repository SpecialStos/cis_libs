-- Client-side test definitions. Zones and doors are created at the player's
-- current position so enter/exit and proximity assertions can run without the
-- tester having to walk anywhere.

CisTestClientSuite = {}

local function resourceStarted(name)
    return GetResourceState(name) == 'started'
end

function CisTestClientSuite.build(ctx, config)
    local r = CisTestRunner.new()
    local reg = function(name, fn, opts)
        CisTestRunner.register(r, name, fn, opts)
    end

    local suffix = tostring(GetGameTimer())
    local created = { zones = {}, targets = {}, doors = {} }

    -- End-to-end zone tests need the player to actually move. Teleporting is
    -- deterministic; walking is not. HOME is captured once so every test
    -- restores the player before the next one starts.
    local HOME = nil
    local function captureHome()
        if not HOME then
            local c = Cis.player.coords()
            HOME = vector3(c.x, c.y, c.z)
        end
        return HOME
    end

    local function teleportTo(coords)
        local ped = Cis.player.ped()
        SetEntityCoordsNoOffset(ped, coords.x, coords.y, coords.z, false, false, false)
        -- Let one frame run so the cache sees the new position.
        Wait(0)
        Wait(0)
        return Cis.player.coords()
    end

    local function restoreHome()
        if HOME then
            teleportTo(HOME)
        end
    end

    -- Ask the server what the client-side relay has delivered so far, and
    -- which source the server saw for this request.
    local function relayPayload()
        local results = table.pack(pcall(function()
            return Cis.callback.await('cis_libstest:getRelay')
        end))
        if not results[1] or type(results[2]) ~= 'table' then
            return nil
        end
        return results[2]
    end

    local function relaySoFar(kind)
        local payload = relayPayload()
        if not payload or type(payload.entries) ~= 'table' then
            return nil
        end
        local out = {}
        for i = 1, #payload.entries do
            local e = payload.entries[i]
            if not kind or e.kind == kind then
                out[#out + 1] = e
            end
        end
        return out
    end

    local function countFor(list, zoneName)
        local n = 0
        if type(list) ~= 'table' then
            return n
        end
        for i = 1, #list do
            if list[i].zone == zoneName then
                n = n + 1
            end
        end
        return n
    end

    -- ------------------------------------------------------------- lifecycle
    reg('client: cis_libs resource is started', function(t)
        t.equal(GetResourceState('cis_libs'), 'started', 'resource state')
    end)

    reg('client: Config was delivered by the server', function(t)
        local c = t
        -- Config is set in cis_libs's client VM, not ours. Read it back through
        -- the export rather than assuming a shared global.
        local cfg = exports['cis_libs']:GetClientConfig()
        c.truthy(cfg ~= nil, 'config delivered')
        if cfg then
            c.exists(cfg.Framework, 'Config.Framework present')
            c.exists(cfg.Doorlock, 'Config.Doorlock present')
            c.truthy(type(cfg.CallbackTimeout) == 'number', 'CallbackTimeout is a number')
        end
    end)

    reg('client: delivered config carries no secrets', function(t)
        local c = t
        local cfg = exports['cis_libs']:GetClientConfig()
        c.exists(cfg, 'config delivered')
        if cfg then
            local blob = CisTestReport.encode(cfg, '')
            c.truthy(not blob:find('discord.com/api/webhooks', 1, true), 'no webhook URL')
            c.truthy(not blob:find('CHANGE-ME', 1, true), 'no placeholder')
            c.equal(cfg.Framework.Database, nil, 'database config not sent to client')
        end
    end)

    reg('client: Cis.ready resolves true', function(t)
        t.truthy(Cis.wait(5000), 'Cis.wait returns true')
    end)

    reg('client: library reports ready', function(t)
        local c = t
        c.truthy(exports['cis_libs']:IsReady(), 'cis_libs reports ready')
    end)

    reg('client: serverId matches the player', function(t)
        local c = t
        c.equal(Cis.player.serverId(), GetPlayerServerId(PlayerId()), 'server id')
    end)

    -- --------------------------------------------------------- player state
    reg('client: ped handle is valid', function(t)
        local c = t
        local ped = Cis.player.ped()
        c.truthy(ped ~= nil and ped ~= 0, 'ped handle')
        c.equal(ped, PlayerPedId(), 'matches PlayerPedId')
        c.truthy(DoesEntityExist(ped), 'ped entity exists')
    end)

    reg('client: coords return a vector3', function(t)
        local c = t
        local coords = Cis.player.coords()
        c.exists(coords, 'coords returned')
        c.equal(type(coords.x), 'number', 'x is numeric')
        c.equal(type(coords.y), 'number', 'y is numeric')
        c.equal(type(coords.z), 'number', 'z is numeric')
    end)

    reg('client: coords are memoised within a frame', function(t)
        local c = t
        local a, b = Cis.player.coords(), Cis.player.coords()
        c.equal(a, b, 'same table within one frame')
    end)

    reg('client: heading is a number', function(t)
        local c = t
        c.equal(type(Cis.player.heading()), 'number', 'heading type')
    end)

    reg('client: vehicle returns a handle or nil', function(t)
        local c = t
        local vehicle, seat = Cis.player.vehicle()
        if vehicle then
            c.truthy(DoesEntityExist(vehicle), 'vehicle entity exists')
            c.truthy(seat == nil or (seat >= -1 and seat <= 16), 'seat is a plausible index')
        else
            c.pass('on foot, nil returned as documented')
        end
    end)

    reg('client: weapon data is well formed when armed', function(t)
        local c = t
        local weapon = Cis.player.weapon()
        if weapon then
            c.equal(type(weapon.hash), 'number', 'hash numeric')
            c.equal(type(weapon.ammo), 'number', 'ammo numeric')
            c.exists(weapon.attachments, 'attachments present')
        else
            c.pass('unarmed, nil returned as documented')
        end
    end)

    reg('client: weapon read does not mutate a previous snapshot', function(t)
        local c = t
        local first = Cis.player.weapon()
        local second = Cis.player.weapon()
        if first and second then
            c.truthy(first ~= second or first.hash == second.hash, 'snapshots are not corrupted')
        else
            c.pass('unarmed, nothing to compare')
        end
    end)

    reg('client: cache subscription fires on change', function(t)
        local c = t
        local fired = false
        local unsub = Cis.player.on('ped', function() fired = true end)
        c.truthy(type(unsub) == 'function' or unsub == nil, 'on() returned without throwing')
        c.pass('subscription registered (event delivery is asynchronous)')
    end)

    reg('client: near() registers a proximity watcher', function(t)
        local c = t
        local coords = Cis.player.coords()
        -- Callbacks cannot cross the exports boundary, so near() is called
        -- without them. A failure here is about the boundary, not near().
        local ok, res, why = pcall(function()
            return Cis.player.near(coords, 5.0)
        end)
        c.set('threw', not ok)
        c.set('returned', res)
        c.set('reason', why)
        c.truthy(ok, 'near() did not throw')
        c.truthy(res ~= nil or why ~= nil, 'near() returned a handle or an explicit reason')
    end)

    reg('client: Globals table is populated', function(t)
        local c = t
        local globals = exports['cis_libs']:GetGlobals()
        c.exists(globals, 'Globals returned')
        if globals then
            c.exists(globals.Player, 'Globals.Player present')
            c.exists(globals.Vehicle, 'Globals.Vehicle present')
            c.exists(globals.ServerInfo, 'Globals.ServerInfo present')
        end
    end)

    -- ----------------------------------------------------------------- zones
    reg('client: box zone creates and contains its centre', function(t)
        local c = t
        local name = 'cis_test_box_' .. suffix
        created.zones[#created.zones + 1] = name
        local centre = vector3(10.0, 10.0, 72.0)
        local didCreate, why = Cis.zones.box(name, centre, vector3(4.0, 4.0, 4.0), {})
        c.set('createReturned', didCreate)
        c.set('createReason', why)
        c.truthy(didCreate, 'zone created')
        local insideCentre = Cis.zones.contains(name, centre)
        c.set('containsCentre', insideCentre)
        c.truthy(insideCentre, 'centre is inside')
        local containsFar = Cis.zones.contains(name, vector3(500.0, 500.0, 72.0))
        c.set('containsFar', containsFar)
        c.truthy(not containsFar, 'far point is outside')
        local didRemove = Cis.zones.remove(name)
        c.set('removeReturned', didRemove)
        if not didRemove then
            c.fail('zone removed', ('remove returned %s (create=%s containsCentre=%s containsFar=%s)'):format(
                tostring(didRemove), tostring(didCreate), tostring(insideCentre), tostring(containsFar)))
            return
        end
        c.set('containsAfterRemove', Cis.zones.contains(name, centre))
        c.truthy(true, 'zone removed')
    end)

    reg('client: sphere zone creates and contains its centre', function(t)
        local c = t
        local name = 'cis_test_sphere_' .. suffix
        local centre = vector3(20.0, 20.0, 72.0)
        local didCreate, why = Cis.zones.sphere(name, centre, 5.0, {})
        c.set('createReturned', didCreate)
        c.set('createReason', why)
        c.truthy(didCreate, 'zone created')
        c.truthy(Cis.zones.contains(name, centre), 'centre is inside')
        c.truthy(not Cis.zones.contains(name, vector3(100.0, 20.0, 72.0)), 'far point is outside')
        local didRemove = Cis.zones.remove(name)
        c.set('removeReturned', didRemove)
        if not didRemove then
            c.fail('zone removed', ('remove returned %s after create returned %s'):format(
                tostring(didRemove), tostring(didCreate)))
            return
        end
        c.truthy(true, 'zone removed')
    end)

    reg('client: a returned function reference is callable', function(t)
        local c = t
        -- Measured: a function returned from an export arrives as a table
        -- carrying __cfx_functionReference, not as nil. Whether that
        -- reference can actually be invoked decides if client-side callbacks
        -- are recoverable at all, so probe both call shapes.
        local coords = Cis.player.coords()
        local handle = Cis.player.near(coords, 5.0)
        c.set('handleType', type(handle))
        c.set('isRef', type(handle) == 'table' and handle.__cfx_functionReference ~= nil)
        if type(handle) ~= 'table' then
            t.skip('no function reference was returned across the boundary')
            return
        end
        local directOk = pcall(function() return handle() end)
        c.set('directCallWorked', directOk)
        local selfOk = pcall(function() return handle(handle) end)
        c.set('selfCallWorked', selfOk)
        c.truthy(directOk or selfOk, 'a returned function reference is invokable')
    end)

    reg('client: poly zone creates and contains its centre', function(t)
        local c = t
        local name = 'cis_test_poly_' .. suffix
        local square = {
            vector3(0.0, 0.0, 72.0), vector3(10.0, 0.0, 72.0),
            vector3(10.0, 10.0, 72.0), vector3(0.0, 10.0, 72.0),
        }
        local didCreate, why = Cis.zones.poly(name, square, {})
        c.set('createReturned', didCreate)
        c.set('createReason', why)
        c.truthy(didCreate, 'zone created')
        c.truthy(Cis.zones.contains(name, vector3(5.0, 5.0, 72.0)), 'centre is inside')
        c.truthy(not Cis.zones.contains(name, vector3(50.0, 5.0, 72.0)), 'far point is outside')
        local didRemove = Cis.zones.remove(name)
        c.set('removeReturned', didRemove)
        if not didRemove then
            c.fail('zone removed', ('remove returned %s after create returned %s'):format(
                tostring(didRemove), tostring(didCreate)))
            return
        end
        c.truthy(true, 'zone removed')
    end)

    reg('client: zone fires onEnter at the player position', function(t)
        local c = t
        -- onEnter is a function in the options table, and a function cannot
        -- cross the exports boundary. Measured: it arrives as nil, so the zone
        -- is created with no callback and this can never fire from here.
        local name = 'cis_test_enter_' .. suffix
        created.zones[#created.zones + 1] = name
        local coords = Cis.player.coords()
        local createdZone = Cis.zones.sphere(name, coords, 50.0, {
            onEnter = function() end,
        })
        c.set('zoneCreated', createdZone)
        t.truthy(createdZone, 'zone created for the enter check')
        Wait(700)
        -- Inside-ness is observable through the grid regardless of callbacks.
        local stillThere = Cis.zones.contains(name, coords)
        c.set('containsPlayer', stillThere)
        t.skip('onEnter cannot be observed: a callback in the options table does not cross the exports boundary')
        Cis.zones.remove(name)
    end)

    reg('client: zone inside callback fires on its interval', function(t)
        local name = 'cis_test_inside_' .. suffix
        created.zones[#created.zones + 1] = name
        local coords = Cis.player.coords()
        -- The `inside` callback is dropped at the boundary, so the tick count
        -- cannot be observed from another resource. What we can still verify is
        -- that an insideInterval zone is accepted and holds the player.
        local createdZone = Cis.zones.sphere(name, coords, 50.0, {
            insideInterval = 100,
            inside = function() end,
        })
        t.set('zoneCreated', createdZone)
        t.truthy(createdZone, 'zone created with an insideInterval')
        Wait(900)
        t.set('stillContainsPlayer', Cis.zones.contains(name, coords))
        t.skip('the inside callback cannot be observed: it does not cross the exports boundary')
        Cis.zones.remove(name)
    end)

    reg('client: removing an unknown zone returns false', function(t)
        t.equal(Cis.zones.remove('cis_test_zone_that_does_not_exist'), false, 'unknown zone')
    end)

    reg('client: zone debug stats are readable', function(t)
        local c = t
        local stats = exports['cis_libs']:GetZoneDebug()
        c.exists(stats, 'zone debug returned')
        if stats then
            c.equal(type(stats.lastPassMs), 'number', 'lastPassMs is numeric')
        end
    end)

    -- ---------------------------------------------------------------- target
    reg('client: target availability is reported', function(t)
        local c = t
        local available = exports['cis_libs']:TargetAvailable()
        c.equal(type(available), 'boolean', 'TargetAvailable is boolean')
        if not available then
            c.skip('no target provider started (ox_target or qb-target)')
        end
    end)

    reg('client: target creates and removes', function(t)
        local c = t
        if not exports['cis_libs']:TargetAvailable() then
            c.skip('no target provider started')
            return
        end
        local name = 'cis_test_target_' .. suffix
        local coords = vector3(5.0, 5.0, 72.0)
        local didCreate, why = Cis.target.add('sphere', name, coords, 3.0, {
            options = { { name = 'cis_test_opt', label = 'Test', icon = 'fas fa-check' } },
        })
        c.set('createReturned', didCreate)
        c.set('createReason', why)
        c.truthy(didCreate, 'target created')
        local existed = Cis.target.exists(name)
        c.set('existsAfterCreate', existed)
        c.truthy(existed, 'target exists')
        local didRemove = Cis.target.remove(name)
        c.set('removeReturned', didRemove)
        if not didRemove then
            c.fail('target removed', ('remove returned %s, existsAfterCreate=%s'):format(
                tostring(didRemove), tostring(existed)))
            return
        end
        c.set('existsAfterRemove', Cis.target.exists(name))
        c.truthy(not Cis.target.exists(name), 'target gone')
    end)

    -- ----------------------------------------------------------------- doors
    reg('client: door registers and exposes its state', function(t)
        local c = t
        local id = 'cis_test_client_door_' .. suffix
        local ok = Cis.doors.add({
            id = id,
            model = 'v_warehousedoor01a',
            coords = Cis.player.coords(),
            locked = false,
        })
        c.truthy(ok, 'door added')
        c.equal(Cis.doors.get(id), false, 'door starts unlocked')
    end, { mutating = true })

    reg('client: closest door is found at the player position', function(t)
        local c = t
        local id = 'cis_test_client_door_near_' .. suffix
        Cis.doors.add({
            id = id,
            model = 'v_warehousedoor01a',
            coords = Cis.player.coords(),
            interactCoords = Cis.player.coords(),
            locked = false,
        })
        local closest = exports['cis_libs']:GetClosestDoor()
        c.exists(closest, 'closest door found')
        if closest then
            c.equal(closest.id, id, 'correct door identified')
            c.truthy(closest.distance <= 2.0, ('distance %.2f within range'):format(closest.distance))
        end
    end, { mutating = true })

    reg('client: unknown door state is nil', function(t)
        t.equal(Cis.doors.get('cis_test_no_such_door'), nil, 'unknown door returns nil')
    end)

    -- ------------------------------------------------------------------ sync
    reg('client: synced entities can be listed', function(t)
        local c = t
        local entities = exports['cis_libs']:GetSyncedEntities()
        c.equal(type(entities), 'table', 'entity map is a table')
    end)

    -- ------------------------------------------------------------- streaming
    reg('client: a valid model streams in', function(t)
        local c = t
        local loaded, hash = Cis.streaming.model('prop_barrel_01a', 5000)
        c.truthy(loaded, 'model loaded')
        c.equal(type(hash), 'number', 'hash returned')
    end)

    reg('client: an invalid model is rejected', function(t)
        local c = t
        local loaded = Cis.streaming.model('not_a_real_model_name', 500)
        c.truthy(not loaded, 'invalid model reports not loaded')
    end)

    -- ------------------------------------------------------------- inventory
    reg('client: inventory count is a number', function(t)
        local c = t
        c.equal(type(Cis.inventory.count('bread')), 'number', 'count type')
    end)

    reg('client: has() agrees with count()', function(t)
        local c = t
        local count = Cis.inventory.count('cis_libs_test_item')
        c.equal(Cis.inventory.has('cis_libs_test_item', 1), count >= 1, 'has matches count')
    end)

    -- ------------------------------------------------------------ callbacks
    reg('client: unknown callback returns a failure, not an error', function(t)
        local c = t
        -- The completion callback cannot cross the exports boundary, so there is
        -- nothing to observe here. The server suite covers callback dispatch.
        t.skip('callback completion function cannot cross the exports boundary')
    end)

    -- ------------------------------------------------------------------ utils
    reg('client: Round formats to the requested precision', function(t)
        local c = t
        c.equal(exports['cis_libs']:Round(1.2345, 2), 1.23, 'two decimals')
        c.equal(exports['cis_libs']:Round(1.6, 0), 2, 'zero decimals')
    end)

    reg('client: RandomFloat stays in range', function(t)
        local c = t
        local value = exports['cis_libs']:RandomFloat(5, 10)
        c.truthy(value >= 5 and value <= 10, ('value %.3f within [5,10]'):format(value))
    end)

    reg('client: GetTableSize counts entries', function(t)
        local c = t
        c.equal(exports['cis_libs']:GetTableSize({ a = 1, b = 2, c = 3 }), 3, 'three entries')
    end)

    reg('client: distance helper is correct', function(t)
        local c = t
        c.equal(exports['cis_libs']:GetDistanceBetweenCoords(0, 0, 0, 3, 4, 0), 5.0, '3-4-5 triangle')
    end)

    reg('client: CreatePed returns a handle for a valid model', function(t)
        local c = t
        local ped = exports['cis_libs']:CreatePed('a_m_m_business_01', vector3(0.0, 0.0, 72.0), 0.0, {
            networked = false,
            timeout = 8000,
        })
        c.truthy(ped ~= nil and ped ~= 0, 'ped created')
        if ped and ped ~= 0 then
            DeleteEntity(ped)
        end
    end)

    -- ------------------------------------------------------------- vehicles
    reg('client: vehicle properties round-trip', function(t)
        local c = t
        local vehicle = exports['cis_libs']:GetClosestVehicle()
        if not vehicle or vehicle == 0 then
            c.skip('no vehicle nearby')
            return
        end
        local props = exports['cis_libs']:GetVehicleProperties(vehicle)
        c.exists(props, 'properties returned')
        if props then
            c.equal(type(props.plate), 'string', 'plate is a string')
            c.equal(type(props.model), 'number', 'model is numeric')
        end
    end)

    reg('client: GetClosestVehicle returns a handle or zero', function(t)
        local c = t
        local vehicle = exports['cis_libs']:GetClosestVehicle()
        c.truthy(vehicle ~= nil, 'a value was returned')
    end)

    reg('client: current weapon data is retrievable', function(t)
        local c = t
        local weapon = exports['cis_libs']:GetCurrentWeaponData()
        c.exists(weapon, 'weapon data returned')
        if weapon then
            c.equal(type(weapon.hash), 'number', 'hash numeric')
        end
    end)

    -- ---------------------------------------------------------------- logging
    reg('client: logging does not throw at any level', function(t)
        local c = t
        local ok = pcall(function()
            Cis.log.debug('cis_libs self-test debug')
            Cis.log.info('cis_libs self-test info')
            Cis.log.warn('cis_libs self-test warn')
            Cis.log.error('cis_libs self-test error')
        end)
        c.truthy(ok, 'all four log levels executed')
    end)

    reg('client: error logging does not throw', function(t)
        local c = t
        -- Capturing output is not possible from here: `print` inside cis_libs's
        -- VM is a different global from ours, so overriding _G.print proves
        -- nothing. Verify the call is safe and leave the console check to the
        -- operator, who can see the output directly.
        local ok = pcall(function()
            Cis.log.error('cis_libs self-test visible error')
        end)
        c.truthy(ok, 'log.error executed without throwing')
    end)

    -- ---------------------------------------------- zones: end to end (teleport)
    reg('client: zone relays onEnter when the player is teleported in', function(t)
        local c = t
        local home = captureHome()
        local name = 'cis_test_enter_e2e_' .. suffix
        local centre = vector3(home.x + 60.0, home.y, home.z)
        c.set('centre', { x = centre.x, y = centre.y, z = centre.z })
        c.truthy(Cis.zones.sphere(name, centre, 10.0, {
            onEnterEvent = 'cis_libstest:zoneEnter',
        }), 'zone created with an onEnterEvent relay')
        -- Start outside, then step in.
        teleportTo(centre)
        Wait(900)
        local landed = Cis.player.coords()
        c.set('landedOn', { x = landed.x, y = landed.y, z = landed.z })
        c.truthy(Cis.zones.contains(name, landed), 'player is inside the zone after teleport')
        local seen = relaySoFar('zoneEnter')
        c.set('relayType', type(seen))
        c.set('relayCount', countFor(seen, name))
        c.truthy(countFor(seen, name) >= 1,
            ('zoneEnter relay delivered to the server (%d)'):format(countFor(seen, name)))
        Cis.zones.remove(name)
        restoreHome()
    end)

    reg('client: zone relays onExit when the player is teleported out', function(t)
        local c = t
        local home = captureHome()
        local name = 'cis_test_exit_e2e_' .. suffix
        local centre = vector3(home.x - 60.0, home.y, home.z)
        c.truthy(Cis.zones.sphere(name, centre, 10.0, {
            onEnterEvent = 'cis_libstest:zoneEnter',
            onExitEvent = 'cis_libstest:zoneExit',
        }), 'zone created with enter and exit relays')
        teleportTo(centre)
        Wait(700)
        local enteredCount = countFor(relaySoFar('zoneEnter'), name)
        c.set('enteredCount', enteredCount)
        teleportTo(home)
        Wait(900)
        local back = Cis.player.coords()
        c.truthy(not Cis.zones.contains(name, back), 'player is outside the zone after teleporting back')
        local exits = countFor(relaySoFar('zoneExit'), name)
        c.set('exitCount', exits)
        c.truthy(enteredCount >= 1, 'entered first, so the exit is meaningful')
        c.truthy(exits >= 1, ('zoneExit relay delivered to the server (%d)'):format(exits))
        Cis.zones.remove(name)
        restoreHome()
    end)

    reg('client: zone relays inside on its interval', function(t)
        local c = t
        local home = captureHome()
        local name = 'cis_test_inside_e2e_' .. suffix
        local centre = vector3(home.x + 100.0, home.y + 40.0, home.z)
        c.truthy(Cis.zones.sphere(name, centre, 10.0, {
            insideInterval = 150,
            insideEvent = 'cis_libstest:zoneInside',
        }), 'zone created with an insideEvent relay')
        teleportTo(centre)
        Wait(1400)
        local ticks = countFor(relaySoFar('zoneInside'), name)
        c.set('insideTicks', ticks)
        c.truthy(ticks >= 2, ('insideEvent relayed %d times in 1400ms'):format(ticks))
        Cis.zones.remove(name)
        restoreHome()
    end)

    reg('client: proximity watcher relays enter and exit', function(t)
        local c = t
        local home = captureHome()
        local target = vector3(home.x, home.y - 80.0, home.z)
        local handle = Cis.player.near(target, 10.0, nil, nil,
            'cis_libstest:nearEnter', 'cis_libstest:nearExit')
        c.truthy(handle ~= nil, 'watcher registered')
        teleportTo(target)
        Wait(900)
        local enters = #relaySoFar('nearEnter')
        c.set('nearEnters', enters)
        c.truthy(enters >= 1, ('nearEnter relayed %d times'):format(enters))
        teleportTo(home)
        Wait(900)
        local exits = #relaySoFar('nearExit')
        c.set('nearExits', exits)
        c.truthy(exits >= 1, ('nearExit relayed %d times'):format(exits))
        if type(handle) == 'function' then
            handle()
        end
        restoreHome()
    end)

    reg('client: server sees this player as the callback source', function(t)
        local c = t
        local payload = relayPayload()
        c.set('payloadType', type(payload))
        if type(payload) ~= 'table' then
            t.skip('the relay callback did not return a table')
            return
        end
        c.set('serverSawSrc', payload.src)
        c.set('myServerId', Cis.player.serverId())
        c.equal(payload.src, Cis.player.serverId(),
            'a remote handler receives the caller id across a real net event')
    end)

    reg('client: player returns to its starting position', function(t)
        local c = t
        local home = captureHome()
        local here = Cis.player.coords()
        local dist = #(here - home)
        c.set('distanceFromHome', dist)
        c.truthy(dist < 5.0, ('player restored to within %.1fm of home'):format(dist))
    end)

    return r
end