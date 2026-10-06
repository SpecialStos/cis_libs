-- Client half of 8.5 soak. Does not freeze the player. Creates a modest set of
-- zones and points, answers a diagnostics sample every minute, pings a callback.
-- Never sends coords, names or identifiers.

local zoneNames = {}
local pointIds = {}

local function snapDiag(d)
    if type(d) ~= 'table' then
        return { missing = true }
    end
    return {
        realm = d.realm,
        uptimeMs = d.uptimeMs,
        memoryKb = d.memoryKb,
        counters = d.counters,
        probes = d.probes,
        timings = d.timings,
    }
end

local function pedCoords()
    local ped = PlayerPedId()
    if not ped or ped == 0 then return nil end
    return GetEntityCoords(ped)
end

RegisterNetEvent('cis_test:soak_start', function()
    zoneNames, pointIds = {}, {}
    local c = pedCoords()
    if not c then
        TriggerServerEvent('cis_test:soak_client_ready', { ok = false, why = 'no ped' })
        return
    end
    for i = 1, 20 do
        local name = 'soak_z_' .. i
        local ok = exports['cis_libs']:CreateZone('box', name, {
            x = c.x + 80.0 + (i % 5) * 6.0,
            y = c.y + math.floor(i / 5) * 6.0,
            z = c.z,
        }, { x = 4.0, y = 4.0, z = 4.0 }, {})
        if ok then zoneNames[#zoneNames + 1] = name end
        if i % 5 == 0 then Wait(0) end
    end
    for i = 1, 20 do
        local id, why = exports['cis_libs']:CreatePoint({
            coords = { x = c.x + 90.0 + i, y = c.y, z = c.z },
            distance = 4.0,
        })
        if type(id) == 'number' then
            pointIds[#pointIds + 1] = id
        elseif i == 1 then
            print(('[cis_test:client] soak CreatePoint refused: %s'):format(tostring(why)))
        end
        if i % 5 == 0 then Wait(0) end
    end
    TriggerServerEvent('cis_test:soak_client_ready', {
        ok = true,
        zones = #zoneNames,
        points = #pointIds,
    })
end)

RegisterNetEvent('cis_test:soak_tick', function(minute, doCollect)
    pcall(function()
        exports['cis_libs']:CallCallback('cis_test:perfPing', function() end)
    end)
    local d = nil
    pcall(function() d = exports['cis_libs']:GetDiagnostics({ collect = doCollect }) end)
    local zd, pd
    pcall(function() zd = exports['cis_libs']:GetZoneDebug() end)
    pcall(function() pd = exports['cis_libs']:GetPointsDebug() end)
    TriggerServerEvent('cis_test:soak_client_sample', {
        minute = minute,
        diagnostics = snapDiag(d),
        zoneDebug = zd,
        pointsDebug = pd,
    })
end)

RegisterNetEvent('cis_test:soak_stop', function()
    for i = 1, #zoneNames do
        pcall(function() exports['cis_libs']:RemoveZone(zoneNames[i]) end)
        if i % 5 == 0 then Wait(0) end
    end
    for i = 1, #pointIds do
        pcall(function() exports['cis_libs']:RemovePoint(pointIds[i]) end)
        if i % 5 == 0 then Wait(0) end
    end
    zoneNames, pointIds = {}, {}
end)
