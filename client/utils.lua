-- cis_libs/client/utils.lua

function Round(num, numDecimalPlaces)
    return tonumber(string.format("%." .. (numDecimalPlaces or 0) .. "f", num))
end

function GetDistanceBetweenCoords(x1, y1, z1, x2, y2, z2)
    return #(vector3(x1, y1, z1) - vector3(x2, y2, z2))
end

function DebugLog(message)
    if Config.Debug then
        print("[cis_libs] " .. tostring(message))
    end
end

function DrawText3D(x, y, z, text)
    local onScreen, _x, _y = World3dToScreen2d(x, y, z)
    local p = GetGameplayCamCoords()
    local distance = GetDistanceBetweenCoords(p.x, p.y, p.z, x, y, z, 1)
    local scale = (1 / distance) * 2
    local fov = (1 / GetGameplayCamFov()) * 100
    local scale = scale * fov
    if onScreen then
        SetTextScale(0.35, 0.35)
        SetTextFont(4)
        SetTextProportional(1)
        SetTextColour(255, 255, 255, 215)
        SetTextEntry("STRING")
        SetTextCentre(1)
        AddTextComponentString(text)
        DrawText(_x,_y)
        local factor = (string.len(text)) / 370
        DrawRect(_x,_y+0.0125, 0.015+ factor, 0.03, 0, 0, 0, 100)
    end
end

function CreatePed(hash, coords, heading)
    RequestModel(hash)
    while not HasModelLoaded(hash) do
        Wait(5)
    end

    local ped = CreatePed(4, hash, coords, false, false)
    FreezeEntityPosition(ped, true)
    SetEntityHeading(ped, heading)
    SetEntityAsMissionEntity(ped, true, true)
    SetPedHearingRange(ped, 0.0)
    SetPedSeeingRange(ped, 0.0)
    SetPedAlertness(ped, 0.0)
    SetPedFleeAttributes(ped, 0, 0)
    SetBlockingOfNonTemporaryEvents(ped, true)
    SetPedCombatAttributes(ped, 46, true)
    SetPedFleeAttributes(ped, 0, 0)
    SetPedDropsWeaponsWhenDead(ped, false)
    FreezeEntityPosition(ped, false)
    return ped
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

function GetAngleDifference(ped, ped2)
    local pedRotation = GetEntityRotation(ped)
    local pedForwardVector = vector3(-math.sin(pedRotation.z), math.cos(pedRotation.z), 0)
    local pedToPed2Vector = vector3(ped2.x - ped.x, ped2.y - ped.y, ped2.z - ped.z)
    pedToPed2Vector = pedToPed2Vector / #pedToPed2Vector
    local dotProduct = pedForwardVector.x * pedToPed2Vector.x + pedForwardVector.y * pedToPed2Vector.y + pedForwardVector.z * pedToPed2Vector.z
    local angle = math.acos(dotProduct)
    return math.deg(angle)
end

function PedHasSight(ped, ped2)
    if HasEntityClearLosToEntity(ped, ped2, 17) then
        local pedForwardVector = GetEntityForwardVector(ped)
        local pedToPed2Vector = vector3(ped2.x - ped.x, ped2.y - ped.y, ped2.z - ped.z)
        pedToPed2Vector = pedToPed2Vector / #pedToPed2Vector
   
        local dotProduct = pedForwardVector.x * pedToPed2Vector.x + pedForwardVector.y * pedToPed2Vector.y + pedForwardVector.z * pedToPed2Vector.z
        local angle = math.deg(math.acos(dotProduct))
   
        return angle < 90
    end
    return false
end

-- Export all functions
exports('Round', Round)
exports('GetDistanceBetweenCoords', GetDistanceBetweenCoords)
exports('DebugLog', DebugLog)
exports('DrawText3D', DrawText3D)
exports('CreatePed', CreatePed)
exports('RandomFloat', RandomFloat)
exports('GetTableSize', GetTableSize)
exports('GetAngleDifference', GetAngleDifference)
exports('PedHasSight', PedHasSight)