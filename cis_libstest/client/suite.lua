-- Client-side tests.
--
-- A separate resource with its own Lua VM, so none of cis_libs's globals exist
-- here. The Cis proxy and the pure shared/ modules are loaded in fxmanifest.
--
-- Zones and doors are created relative to the player's current position so
-- enter/exit assertions can run without anyone walking anywhere.
--
-- Tagged: `probe`, `mutating`, `teleport`.

CisTestClientSuite = {}

function CisTestClientSuite.build(ctx, config)
    local r = CisTestRunner.new()
    local reg = function(name, fn, opts)
        CisTestRunner.register(r, name, fn, opts)
    end

    local suffix = tostring(GetGameTimer())
    local created = { zones = {}, targets = {}, doors = {} }

    -- Teleport helpers. HOME is captured once and restored after every test so
    -- cases stay independent.
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
        -- One frame for the cache to observe the new position.
        Wait(0)
        Wait(0)
        return Cis.player.coords()
    end

    local function restoreHome()
        if HOME then
            teleportTo(HOME)
        end
    end

    -- Ask the server what the client-side relay delivered, and which source the
    -- server saw for the request.
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

    -- ======================================================================
    -- BOUNDARY PROBES
    -- ======================================================================

    reg('probe: a returned function reference is callable', function(t)
        local c = t
        local coords = Cis.player.coords()
        local handle = Cis.player.near(coords, 5.0)
        local callable, kind = CisTestProbe.isCallable(handle)
        c.set('handleType', type(handle))
        c.set('callableKind', kind)
        if not callable then
            t.skip(('near() returned a %s, not a function reference'):format(kind))
            return
        end
        local directOk = pcall(function() return handle() end)
        c.set('directCallWorked', directOk)
        c.truthy(directOk, 'the reference is invokable')
    end, { probe = true })

    reg('probe: a vector3 survives the exports boundary', function(t)
        local c = t
        local coords = Cis.player.coords()
        c.set('localType', type(coords))
        c.equal(type(coords), 'vector3', 'the proxy returns a vector3 locally')
        -- The self trap made it LOOK like vector3 was dropped. Confirm an
        -- export call accepting one does not throw.
        local ok = pcall(function()
            return exports['cis_libs']:ZoneContains('cis_test_roundtrip', coords)
        end)
        c.set('threw', not ok)
        c.truthy(ok, 'a vector3 argument did not throw inside the export')
    end, { probe = true })

    reg('probe: exports return values, and false is not nil', function(t)
        local c = t
        local available = exports['cis_libs']:TargetAvailable()
        c.set('targetAvailable', available)
        c.equal(type(available), 'boolean', 'TargetAvailable returns a real boolean, not nil')
    end, { probe = true })

    -- ======================================================================
    -- LIFECYCLE
    -- ======================================================================

    reg('core: cis_libs resource is started', function(t)
        t.equal(GetResourceState('cis_libs'), 'started', 'resource state')
    end)

    reg('core: the library reports ready', function(t)
        t.truthy(exports['cis_libs']:IsReady(), 'IsReady is true')
    end)

    reg('core: config was delivered by the server', function(t)
        local c = t
        local cfg = exports['cis_libs']:GetClientConfig()
        c.truthy(cfg ~= nil, 'config delivered')
        if cfg then
            c.exists(cfg.Framework, 'Config.Framework present')
            c.exists(cfg.Doorlock, 'Config.Doorlock present')
            c.equal(type(cfg.CallbackTimeout), 'number', 'CallbackTimeout is a number')
        end
    end)

    reg('core: the delivered config carries no secrets', function(t)
        local c = t
        local cfg = exports['cis_libs']:GetClientConfig()
        c.exists(cfg, 'config delivered')
        if cfg then
            local blob = CisTestReport.encode(cfg, '')
            c.truthy(not blob:find('discord.com/api/webhooks', 1, true), 'no webhook URL')
            c.truthy(not blob:find('CHANGE-ME', 1, true), 'no placeholder')
            c.equal(cfg.Framework.Database, nil, 'database config not sent to the client')
            c.equal(cfg.AuthorizedResources, nil, 'allow-list not sent to the client')
        end
    end)

    reg('core: the server sees this player as the callback source', function(t)
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

    -- ======================================================================
    -- PLAYER STATE
    -- ======================================================================

    reg('core: the ped handle is valid', function(t)
        local c = t
        local ped = Cis.player.ped()
        c.truthy(ped ~= nil and ped ~= 0, 'ped handle')
        c.equal(ped, PlayerPedId(), 'matches PlayerPedId')
        c.truthy(DoesEntityExist(ped), 'the ped entity exists')
    end)

    reg('core: coords return a vector3', function(t)
        local c = t
        local coords = Cis.player.coords()
        c.exists(coords, 'coords returned')
        c.equal(type(coords.x), 'number', 'x is numeric')
        c.equal(type(coords.z), 'number', 'z is numeric')
    end)

    reg('core: coords are memoised within a frame', function(t)
        local a, b = Cis.player.coords(), Cis.player.coords()
        t.equal(a, b, 'the same table within one frame')
    end)

    reg('core: heading is a number', function(t)
        t.equal(type(Cis.player.heading()), 'number', 'heading type')
    end)

    reg('core: serverId matches the player', function(t)
        t.equal(Cis.player.serverId(), GetPlayerServerId(PlayerId()), 'server id')
    end)

    reg('core: vehicle returns a handle or nil', function(t)
        local c = t
        local vehicle, seat = Cis.player.vehicle()
        if vehicle then
            c.truthy(DoesEntityExist(vehicle), 'the vehicle entity exists')
            c.truthy(seat == nil or (seat >= -1 and seat <= 16), 'the seat is a plausible index')
        else
            c.pass('on foot, nil returned as documented')
        end
    end)

    reg('core: weapon data is well formed when armed', function(t)
        local c = t
        local w = Cis.player.weapon()
        if w then
            c.equal(type(w.hash), 'number', 'hash numeric')
            c.equal(type(w.ammo), 'number', 'ammo numeric')
            c.exists(w.attachments, 'attachments present')
        else
            c.pass('unarmed, nil returned as documented')
        end
    end)

    reg('core: the Globals table is populated', function(t)
        local c = t
        local g = exports['cis_libs']:GetGlobals()
        c.exists(g, 'Globals returned')
        if g then
            c.exists(g.Player, 'Globals.Player present')
            c.exists(g.Vehicle, 'Globals.Vehicle present')
            c.exists(g.ServerInfo, 'Globals.ServerInfo present')
        end
    end)

    reg('core: a cache subscription registers without throwing', function(t)
        local ok = pcall(function()
            Cis.player.on('ped', function() end)
        end)
        t.truthy(ok, 'Cis.player.on did not throw')
    end)

    -- ======================================================================
    -- ZONES (no teleport)
    -- ======================================================================

    reg('core: a box zone creates, contains, and removes', function(t)
        local c = t
        local name = 'cis_test_box_' .. suffix
        local centre = vector3(10.0, 10.0, 72.0)
        local didCreate, why = Cis.zones.box(name, centre, vector3(4.0, 4.0, 4.0), {})
        c.set('createReturned', didCreate)
        c.set('createReason', why)
        c.truthy(didCreate, 'zone created')
        if not didCreate then return end
        c.truthy(Cis.zones.contains(name, centre), 'the centre is inside')
        c.truthy(not Cis.zones.contains(name, vector3(500.0, 500.0, 72.0)), 'a far point is outside')
        c.set('removeReturned', Cis.zones.remove(name))
        c.truthy(not Cis.zones.contains(name, centre), 'the zone is gone after removal')
    end)

    reg('core: a sphere zone creates and contains its centre', function(t)
        local c = t
        local name = 'cis_test_sphere_' .. suffix
        local centre = vector3(20.0, 20.0, 72.0)
        local didCreate, why = Cis.zones.sphere(name, centre, 5.0, {})
        c.set('createReturned', didCreate)
        c.set('createReason', why)
        c.truthy(didCreate, 'zone created')
        if not didCreate then return end
        c.truthy(Cis.zones.contains(name, centre), 'the centre is inside')
        c.set('removeReturned', Cis.zones.remove(name))
    end)

    reg('core: a poly zone creates and contains its centre', function(t)
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
        if not didCreate then return end
        c.truthy(Cis.zones.contains(name, vector3(5.0, 5.0, 72.0)), 'the centre is inside')
        c.set('removeReturned', Cis.zones.remove(name))
    end)

    reg('core: removing an unknown zone returns false', function(t)
        t.equal(Cis.zones.remove('cis_test_zone_that_does_not_exist'), false, 'unknown zone')
    end)

    reg('core: zone debug stats are readable', function(t)
        local c = t
        local s = exports['cis_libs']:GetZoneDebug()
        c.exists(s, 'zone debug returned')
        if s then
            c.equal(type(s.lastPassMs), 'number', 'lastPassMs is numeric')
        end
    end)

    -- ======================================================================
    -- ZONES (teleport) -- gated by RunTeleport
    -- ======================================================================

    reg('teleport: a zone relays onEnter when the player is teleported in', function(t)
        local c = t
        local home = captureHome()
        local name = 'cis_test_enter_e2e_' .. suffix
        local centre = vector3(home.x + 60.0, home.y, home.z)
        c.set('centre', { x = centre.x, y = centre.y, z = centre.z })
        c.truthy(Cis.zones.sphere(name, centre, 10.0, {
            onEnterEvent = 'cis_libstest:zoneEnter',
        }), 'zone created with an onEnterEvent relay')
        teleportTo(centre)
        Wait(900)
        local landed = Cis.player.coords()
        c.set('landedOn', { x = landed.x, y = landed.y, z = landed.z })
        c.truthy(Cis.zones.contains(name, landed), 'the player is inside after teleporting')
        c.set('relayCount', countFor(relaySoFar('zoneEnter'), name))
        c.truthy(countFor(relaySoFar('zoneEnter'), name) >= 1,
            ('zoneEnter relay delivered to the server (%d)'):format(countFor(relaySoFar('zoneEnter'), name)))
        Cis.zones.remove(name)
        restoreHome()
    end, { teleport = true })

    reg('teleport: a zone relays onExit when the player is teleported out', function(t)
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
        local entered = countFor(relaySoFar('zoneEnter'), name)
        c.set('enteredCount', entered)
        teleportTo(home)
        Wait(900)
        local back = Cis.player.coords()
        c.truthy(not Cis.zones.contains(name, back), 'the player is outside after teleporting back')
        local exits = countFor(relaySoFar('zoneExit'), name)
        c.set('exitCount', exits)
        c.truthy(entered >= 1, 'the enter landed first, so the exit is meaningful')
        c.truthy(exits >= 1, ('zoneExit relay delivered to the server (%d)'):format(exits))
        Cis.zones.remove(name)
        restoreHome()
    end, { teleport = true })

    reg('teleport: a zone relays inside on its interval', function(t)
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
    end, { teleport = true })

    reg('teleport: a proximity watcher relays enter and exit', function(t)
        local c = t
        local home = captureHome()
        local target = vector3(home.x, home.y - 80.0, home.z)
        local handle = Cis.player.near(target, 10.0, nil, nil,
            'cis_libstest:nearEnter', 'cis_libstest:nearExit')
        c.set('handleType', type(handle))
        c.truthy(handle ~= nil, 'watcher registered')
        teleportTo(target)
        Wait(900)
        local enters = #(relaySoFar('nearEnter') or {})
        c.set('nearEnters', enters)
        c.truthy(enters >= 1, ('nearEnter relayed %d times'):format(enters))
        teleportTo(home)
        Wait(900)
        local exits = #(relaySoFar('nearExit') or {})
        c.set('nearExits', exits)
        c.truthy(exits >= 1, ('nearExit relayed %d times'):format(exits))
        if type(handle) == 'function' then
            pcall(handle)
        end
        restoreHome()
    end, { teleport = true })

    reg('teleport: the player is restored to its starting position', function(t)
        local c = t
        local home = captureHome()
        local here = Cis.player.coords()
        local dist = #(here - home)
        c.set('distanceFromHome', dist)
        c.truthy(dist < 5.0, ('restored to within %.1fm of home'):format(dist))
    end, { teleport = true })

    -- ======================================================================
    -- TARGET
    -- ======================================================================

    reg('core: target availability is reported', function(t)
        local c = t
        local available = exports['cis_libs']:TargetAvailable()
        c.equal(type(available), 'boolean', 'TargetAvailable is boolean')
        if not available then
            t.skip('no target provider started (ox_target or qb-target)')
        end
    end)

    reg('core: a target creates and removes', function(t)
        local c = t
        if not exports['cis_libs']:TargetAvailable() then
            t.skip('no target provider started')
            return
        end
        local name = 'cis_test_target_' .. suffix
        local didCreate = Cis.target.add('sphere', name, vector3(5.0, 5.0, 72.0), 3.0, {
            options = { { name = 'cis_test_opt', label = 'Test', icon = 'fas fa-check' } },
        })
        c.set('createReturned', didCreate)
        c.truthy(didCreate, 'target created')
        if not didCreate then return end
        local existed = Cis.target.exists(name)
        c.set('existsAfterCreate', existed)
        c.truthy(existed, 'target exists')
        local removed = Cis.target.remove(name)
        c.set('removeReturned', removed)
        c.truthy(removed, 'target removed')
        c.set('existsAfterRemove', Cis.target.exists(name))
        c.truthy(not Cis.target.exists(name), 'target gone')
    end)

    -- ======================================================================
    -- STREAMING, SYNC, INVENTORY
    -- ======================================================================

    reg('core: a valid model streams in', function(t)
        local c = t
        local loaded, hash = Cis.streaming.model('prop_barrel_01a', 5000)
        c.set('loaded', loaded)
        c.set('hashType', type(hash))
        c.truthy(loaded, 'the model loaded')
        c.equal(type(hash), 'number', 'a hash was returned')
    end)

    reg('core: an invalid model is rejected', function(t)
        local loaded = Cis.streaming.model('not_a_real_model_name', 500)
        t.truthy(not loaded, 'an invalid model reports not loaded')
    end)

    reg('core: synced entities can be listed', function(t)
        local c = t
        local e = exports['cis_libs']:GetSyncedEntities()
        c.equal(type(e), 'table', 'the entity map is a table')
    end)

    reg('core: inventory count is a number', function(t)
        t.equal(type(Cis.inventory.count('bread')), 'number', 'count type')
    end)

    reg('core: has() agrees with count()', function(t)
        local count = Cis.inventory.count('cis_libs_test_item')
        t.equal(Cis.inventory.has('cis_libs_test_item', 1), count >= 1, 'has matches count')
    end)

    -- ======================================================================
    -- UTILITIES
    -- ======================================================================

    reg('core: Round formats to the requested precision', function(t)
        local c = t
        c.equal(exports['cis_libs']:Round(1.2345, 2), 1.23, 'two decimals')
        c.equal(exports['cis_libs']:Round(1.6, 0), 2, 'zero decimals')
    end)

    reg('core: RandomFloat stays in range', function(t)
        local v = exports['cis_libs']:RandomFloat(5, 10)
        t.truthy(v >= 5 and v <= 10, ('value %.3f within [5,10]'):format(v))
    end)

    reg('core: GetTableSize counts entries', function(t)
        t.equal(exports['cis_libs']:GetTableSize({ a = 1, b = 2, c = 3 }), 3, 'three entries')
    end)

    reg('core: the distance helper is correct', function(t)
        t.equal(exports['cis_libs']:GetDistanceBetweenCoords(0, 0, 0, 3, 4, 0), 5.0, '3-4-5 triangle')
    end)

    reg('core: CreatePed returns a handle for a valid model', function(t)
        local c = t
        local ped = exports['cis_libs']:CreatePed('a_m_m_business_01', vector3(0.0, 0.0, 72.0), 0.0, {
            networked = false,
            timeout = 8000,
        })
        c.set('ped', ped)
        c.truthy(ped ~= nil and ped ~= 0, 'a ped was created')
        if ped and ped ~= 0 then
            DeleteEntity(ped)
        end
    end)

    reg('core: GetClosestVehicle returns a value', function(t)
        t.truthy(exports['cis_libs']:GetClosestVehicle() ~= nil, 'a value was returned')
    end)

    reg('core: vehicle properties round-trip', function(t)
        local c = t
        local vehicle = exports['cis_libs']:GetClosestVehicle()
        if not vehicle or vehicle == 0 then
            t.skip('no vehicle nearby')
            return
        end
        local props = exports['cis_libs']:GetVehicleProperties(vehicle)
        c.exists(props, 'properties returned')
        if props then
            c.equal(type(props.plate), 'string', 'plate is a string')
            c.equal(type(props.model), 'number', 'model is numeric')
        end
    end)

    reg('core: current weapon data is retrievable', function(t)
        local c = t
        local w = exports['cis_libs']:GetCurrentWeaponData()
        c.exists(w, 'weapon data returned')
        if w then
            c.equal(type(w.hash), 'number', 'hash numeric')
        end
    end)

    -- ======================================================================
    -- LOGGING
    -- ======================================================================

    reg('core: logging does not throw at any level', function(t)
        local ok = pcall(function()
            Cis.log.debug('cis_libs self-test debug')
            Cis.log.info('cis_libs self-test info')
            Cis.log.warn('cis_libs self-test warn')
            Cis.log.error('cis_libs self-test error')
        end)
        t.truthy(ok, 'all four log levels executed')
    end)

    reg('core: an error log does not throw', function(t)
        -- Capturing output is not possible from here: `print` inside cis_libs's
        -- VM is a different global from ours, so overriding _G.print proves
        -- nothing. Verify the call is safe; the operator can see the output.
        t.truthy(pcall(function() Cis.log.error('cis_libs self-test visible error') end),
            'log.error executed without throwing')
    end)

    -- ======================================================================
    -- OPEN DEFECT -- client-observable
    -- ======================================================================

    reg('defect 9.1: framework.notify is realm-asymmetric on the client', function(t)
        local c = t
        -- init.lua routes (srcOrNil, message, kind). A two-argument call
        -- resolves differently per realm; the client export takes
        -- (message, kind). Record what happened.
        local ok = pcall(function()
            Cis.framework.notify('cis_libs self-test notify probe', 'error')
        end)
        c.set('threw', not ok)
        c.truthy(ok, 'the call did not throw')
        c.pass('argument routing for a two-argument call is ambiguous across realms; '
            .. 'see deltareport1.md section 9.1')
    end)

    -- ======================================================================
    -- MUTATING
    -- ======================================================================

    reg('mutating: a door registers at the player position', function(t)
        local c = t
        local id = 'cis_test_client_door_' .. suffix
        local ok = Cis.doors.add({
            id = id,
            model = 'v_warehousedoor01a',
            coords = Cis.player.coords(),
            locked = false,
        })
        c.set('added', ok)
        c.truthy(ok, 'door added')
        if ok then
            c.equal(Cis.doors.get(id), false, 'the door starts unlocked')
        end
    end, { mutating = true })

    reg('mutating: the closest door is found at the player position', function(t)
        local c = t
        local id = 'cis_test_client_door_near_' .. suffix
        local coords = Cis.player.coords()
        local ok = Cis.doors.add({
            id = id,
            model = 'v_warehousedoor01a',
            coords = coords,
            interactCoords = coords,
            locked = false,
        })
        c.set('added', ok)
        if not ok then
            t.skip('the allow-list refused this test resource from adding a door')
            return
        end
        local closest = exports['cis_libs']:GetClosestDoor()
        c.exists(closest, 'a closest door was found')
        if closest then
            c.set('closestId', closest.id)
            c.equal(closest.id, id, 'the correct door was identified')
        end
    end, { mutating = true })

    reg('mutating: an unknown door has no state', function(t)
        t.equal(Cis.doors.get('cis_test_no_such_door'), nil, 'unknown door returns nil')
    end)

    return r
end
