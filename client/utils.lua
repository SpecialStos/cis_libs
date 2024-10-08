-- cis_libs/client/utils.lua

function DebugLog(message)
    if Config.Debug then
        print("[cis_libs] " .. tostring(message))
    end
end

function Round(num, numDecimalPlaces)
    return tonumber(string.format("%." .. (numDecimalPlaces or 0) .. "f", num))
end

function GetDistanceBetweenCoords(x1, y1, z1, x2, y2, z2)
    return #(vector3(x1, y1, z1) - vector3(x2, y2, z2))
end

-- Utility function for DrawText3D
function DrawText3D(x, y, z, text, settings)
    local onScreen, _x, _y = World3dToScreen2d(x, y, z)
    local p = GetGameplayCamCoords()
    local distance = GetDistanceBetweenCoords(p.x, p.y, p.z, x, y, z, 1)
    local scale = (1 / distance) * 2
    local fov = (1 / GetGameplayCamFov()) * 100
    local scale = scale * fov
    
    if onScreen then
        -- Use settings if provided, otherwise use default values
        local textScale = settings and settings.scale or vec2(0.35, 0.35)
        local font = settings and settings.font or 4
        local color = settings and settings.color or {255, 255, 255, 215}
        local center = settings and settings.center or 1
        
        SetTextScale(textScale.x, textScale.y)
        SetTextFont(font)
        SetTextProportional(1)
        SetTextColour(color[1], color[2], color[3], color[4])
        SetTextEntry("STRING")
        SetTextCentre(center)
        AddTextComponentString(text)
        DrawText(_x, _y)
        
        -- Apply dropshadow if enabled in settings
        if settings and settings.dropshadow and settings.dropshadow.enabled then
            SetTextDropshadow(table.unpack(settings.dropshadow.color))
            SetTextDropShadow()
        end
        
        -- Apply edge if enabled in settings
        if settings and settings.edge and settings.edge.enabled then
            SetTextEdge(table.unpack(settings.edge.color))
        end
        
        -- Apply outline if enabled in settings
        if settings and settings.outline then
            SetTextOutline()
        end
        
        -- Draw background rectangle (always drawn in original function)
        local factor = (string.len(text)) / 370
        DrawRect(_x, _y + 0.0125, 0.015 + factor, 0.03, 0, 0, 0, 100)
    end
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

-- Export all functions
exports('Round', Round)
exports('GetDistanceBetweenCoords', GetDistanceBetweenCoords)
exports('DebugLog', DebugLog)
exports('DrawText3D', DrawText3D)
exports('CreatePed', CreatePed)
exports('RandomFloat', RandomFloat)
exports('GetTableSize', GetTableSize)