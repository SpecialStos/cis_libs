local CreatePedNative = CreatePed

function DebugLog(message)
    if Config and Config.Printing and Config.Printing.Debug then
        print('[cis_libs] ' .. tostring(message))
    end
end

function CreatePed(model, coords, heading, options)
    options = options or {}
    local loaded, modelHash = RequestModelTimeout(model, options.timeout or 5000)
    if not loaded then
        DebugLog('CreatePed received an invalid or unloaded model: ' .. tostring(model))
        return 0
    end

    local ped = CreatePedNative(
        options.pedType or 4,
        modelHash,
        coords.x,
        coords.y,
        coords.z,
        heading or 0.0,
        options.networked ~= false,
        options.missionEntity == true
    )

    if ped ~= 0 then
        if options.freeze then FreezeEntityPosition(ped, true) end
        if options.invincible then SetEntityInvincible(ped, true) end
        if options.blockEvents then SetBlockingOfNonTemporaryEvents(ped, true) end
        if options.scenario then TaskStartScenarioInPlace(ped, options.scenario, 0, true) end
    end

    SetModelAsNoLongerNeeded(modelHash)
    return ped
end

function Round(num, numDecimalPlaces)
    return tonumber(string.format('%.' .. (numDecimalPlaces or 0) .. 'f', num))
end

function GetDistanceBetweenCoords(x1, y1, z1, x2, y2, z2)
    return #(vector3(x1, y1, z1) - vector3(x2, y2, z2))
end

function DrawText3D(x, y, z, text, settings)
    if type(settings) == 'table' and settings[1] then
        settings = { color = settings }
    end

    local onScreen, _x, _y = World3dToScreen2d(x, y, z)
    if not onScreen then
        return
    end
    local p = GetGameplayCamCoords()
    local distance = #(p - vector3(x, y, z))
    if distance <= 0.01 then
        return
    end
    local scale = (1 / distance) * 2 * (1 / GetGameplayCamFov()) * 100
    local textScale = settings and settings.scale or vec2(0.35 * scale, 0.35 * scale)
    local font = settings and settings.font or 4
    local color = settings and settings.color or { 255, 255, 255, 215 }
    local center = settings and settings.center or 1
    local alpha = color[4] or 215

    SetTextScale(textScale.x, textScale.y)
    SetTextFont(font)
    SetTextProportional(1)
    SetTextColour(color[1], color[2], color[3], alpha)
    SetTextEntry('STRING')
    SetTextCentre(center)
    AddTextComponentString(text)
    DrawText(_x, _y)

    local factor = (string.len(text)) / 370
    DrawRect(_x, _y + 0.0125, 0.015 + factor, 0.03, 0, 0, 0, 100)
end

function RandomFloat(lower, greater)
    return lower + math.random() * (greater - lower)
end

function GetTableSize(t)
    local count = 0
    for _ in pairs(t) do
        count = count + 1
    end
    return count
end

exports('Round', Round)
exports('GetDistanceBetweenCoords', GetDistanceBetweenCoords)
exports('DebugLog', DebugLog)
exports('DrawText3D', DrawText3D)
exports('CreatePed', CreatePed)
exports('RandomFloat', RandomFloat)
exports('GetTableSize', GetTableSize)
