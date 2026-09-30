-- Vehicle property capture and apply.
--
-- `lastApplied` is the reason this file is stateful: SetVehicleProperties
-- diffs every field against its own last-applied snapshot so that calling it
-- on a moving synced vehicle is cheap and skips unchanged fields. Drop the
-- table and every apply becomes a full rewrite of every mod. It is keyed by
-- handle, and handles are recycled, so it is swept (see the thread below).
--
-- Get returns EVERYTHING; Set applies only what changed and only what is
-- present. A partial props table is therefore safe to pass in -- missing keys
-- are left alone rather than zeroed.

local GetClosestVehicleNative = GetClosestVehicle
local lastApplied = {}

local function gameBuild()
    if Globals and Globals.ServerInfo and Globals.ServerInfo.GameBuild then
        return Globals.ServerInfo.GameBuild
    end
    return GetGameBuildNumber()
end

local function sameValue(a, b)
    if a == b then
        return true
    end
    if type(a) ~= 'table' or type(b) ~= 'table' then
        return false
    end
    for k, v in pairs(a) do
        if not sameValue(v, b[k]) then
            return false
        end
    end
    for k in pairs(b) do
        if a[k] == nil then
            return false
        end
    end
    return true
end

function GetVehicleProperties(vehicle)
    if not DoesEntityExist(vehicle) then
        return nil
    end

    -- Custom colours overwrite the standard palette, so they are read last:
    -- whichever pair is current is the pair that has to travel.
    local colorPrimary, colorSecondary = GetVehicleColours(vehicle)
    local pearlescentColor, wheelColor = GetVehicleExtraColours(vehicle)
    local paintType1 = GetVehicleModColor_1(vehicle)
    local paintType2 = GetVehicleModColor_2(vehicle)

    if GetIsVehiclePrimaryColourCustom(vehicle) then
        colorPrimary = { GetVehicleCustomPrimaryColour(vehicle) }
    end
    if GetIsVehicleSecondaryColourCustom(vehicle) then
        colorSecondary = { GetVehicleCustomSecondaryColour(vehicle) }
    end

    local extras = {}
    for i = 1, 15 do
        if DoesExtraExist(vehicle, i) then
            extras[i] = IsVehicleExtraTurnedOn(vehicle, i) and 0 or 1
        end
    end

    local modLiveryCount = GetVehicleLiveryCount(vehicle)
    local modLivery = GetVehicleLivery(vehicle)
    if modLiveryCount == -1 or modLivery == -1 then
        modLivery = GetVehicleMod(vehicle, 48)
    end

    local damage = { windows = {}, doors = {}, tyres = {} }
    local windows = 0
    for i = 0, 7 do
        if not IsVehicleWindowIntact(vehicle, i) then
            windows = windows + 1
            damage.windows[windows] = i
        end
    end
    local doors = 0
    for i = 0, 5 do
        if IsVehicleDoorDamaged(vehicle, i) then
            doors = doors + 1
            damage.doors[doors] = i
        end
    end
    for i = 0, 7 do
        if IsVehicleTyreBurst(vehicle, i, false) then
            damage.tyres[i] = IsVehicleTyreBurst(vehicle, i, true) and 2 or 1
        end
    end

    local neons = {}
    for i = 0, 3 do
        neons[i + 1] = IsVehicleNeonLightEnabled(vehicle, i)
    end

    return {
        model = GetEntityModel(vehicle),
        plate = GetVehicleNumberPlateText(vehicle),
        plateIndex = GetVehicleNumberPlateTextIndex(vehicle),
        bodyHealth = math.floor(GetVehicleBodyHealth(vehicle) + 0.5),
        engineHealth = math.floor(GetVehicleEngineHealth(vehicle) + 0.5),
        tankHealth = math.floor(GetVehiclePetrolTankHealth(vehicle) + 0.5),
        fuelLevel = math.floor(GetVehicleFuelLevel(vehicle) + 0.5),
        oilLevel = math.floor(GetVehicleOilLevel(vehicle) + 0.5),
        dirtLevel = math.floor(GetVehicleDirtLevel(vehicle) + 0.5),
        paintType1 = paintType1,
        paintType2 = paintType2,
        color1 = colorPrimary,
        color2 = colorSecondary,
        pearlescentColor = pearlescentColor,
        interiorColor = GetVehicleInteriorColor(vehicle),
        dashboardColor = GetVehicleDashboardColour(vehicle),
        wheelColor = wheelColor,
        wheelWidth = GetVehicleWheelWidth(vehicle),
        wheelSize = GetVehicleWheelSize(vehicle),
        wheels = GetVehicleWheelType(vehicle),
        windowTint = GetVehicleWindowTint(vehicle),
        xenonColor = GetVehicleXenonLightsColor(vehicle),
        neonEnabled = neons,
        neonColor = { GetVehicleNeonLightsColour(vehicle) },
        extras = extras,
        tyreSmokeColor = { GetVehicleTyreSmokeColor(vehicle) },
        modSpoilers = GetVehicleMod(vehicle, 0),
        modFrontBumper = GetVehicleMod(vehicle, 1),
        modRearBumper = GetVehicleMod(vehicle, 2),
        modSideSkirt = GetVehicleMod(vehicle, 3),
        modExhaust = GetVehicleMod(vehicle, 4),
        modFrame = GetVehicleMod(vehicle, 5),
        modGrille = GetVehicleMod(vehicle, 6),
        modHood = GetVehicleMod(vehicle, 7),
        modFender = GetVehicleMod(vehicle, 8),
        modRightFender = GetVehicleMod(vehicle, 9),
        modRoof = GetVehicleMod(vehicle, 10),
        modEngine = GetVehicleMod(vehicle, 11),
        modBrakes = GetVehicleMod(vehicle, 12),
        modTransmission = GetVehicleMod(vehicle, 13),
        modHorns = GetVehicleMod(vehicle, 14),
        modSuspension = GetVehicleMod(vehicle, 15),
        modArmor = GetVehicleMod(vehicle, 16),
        modNitrous = GetVehicleMod(vehicle, 17),
        modTurbo = IsToggleModOn(vehicle, 18),
        modSubwoofer = GetVehicleMod(vehicle, 19),
        modSmokeEnabled = IsToggleModOn(vehicle, 20),
        modHydraulics = IsToggleModOn(vehicle, 21),
        modXenon = IsToggleModOn(vehicle, 22),
        modFrontWheels = GetVehicleMod(vehicle, 23),
        modBackWheels = GetVehicleMod(vehicle, 24),
        modCustomTiresF = GetVehicleModVariation(vehicle, 23),
        modCustomTiresR = GetVehicleModVariation(vehicle, 24),
        modPlateHolder = GetVehicleMod(vehicle, 25),
        modVanityPlate = GetVehicleMod(vehicle, 26),
        modTrimA = GetVehicleMod(vehicle, 27),
        modOrnaments = GetVehicleMod(vehicle, 28),
        modDashboard = GetVehicleMod(vehicle, 29),
        modDial = GetVehicleMod(vehicle, 30),
        modDoorSpeaker = GetVehicleMod(vehicle, 31),
        modSeats = GetVehicleMod(vehicle, 32),
        modSteeringWheel = GetVehicleMod(vehicle, 33),
        modShifterLeavers = GetVehicleMod(vehicle, 34),
        modAPlate = GetVehicleMod(vehicle, 35),
        modSpeakers = GetVehicleMod(vehicle, 36),
        modTrunk = GetVehicleMod(vehicle, 37),
        modHydrolic = GetVehicleMod(vehicle, 38),
        modEngineBlock = GetVehicleMod(vehicle, 39),
        modAirFilter = GetVehicleMod(vehicle, 40),
        modStruts = GetVehicleMod(vehicle, 41),
        modArchCover = GetVehicleMod(vehicle, 42),
        modAerials = GetVehicleMod(vehicle, 43),
        modTrimB = GetVehicleMod(vehicle, 44),
        modTank = GetVehicleMod(vehicle, 45),
        modWindows = GetVehicleMod(vehicle, 46),
        modDoorR = GetVehicleMod(vehicle, 47),
        modLivery = modLivery,
        modRoofLivery = GetVehicleRoofLivery(vehicle),
        modLightbar = GetVehicleMod(vehicle, 49),
        windows = damage.windows,
        doors = damage.doors,
        tyres = damage.tyres,
        bulletProofTyres = GetVehicleTyresCanBurst(vehicle),
        driftTyres = gameBuild() >= 2372 and GetDriftTyresEnabled(vehicle),
    }
end

-- Returns whether this client is allowed to modify the vehicle at all --
-- networked and not owned by anyone else. A consumer that ignores the return
-- writes to vehicles it has no authority over, which the server sees as a
-- desync it cannot explain.
function SetVehicleProperties(vehicle, props, fixVehicle)
    if not DoesEntityExist(vehicle) or type(props) ~= 'table' then
        return false
    end

    local prev = lastApplied[vehicle]
    local function changed(key)
        if props[key] == nil then
            return false
        end
        if prev and sameValue(prev[key], props[key]) then
            return false
        end
        return true
    end

    SetVehicleModKit(vehicle, 0)

    local colorPrimary, colorSecondary = GetVehicleColours(vehicle)
    local pearlescentColor, wheelColor = GetVehicleExtraColours(vehicle)

    if changed('plate') then SetVehicleNumberPlateText(vehicle, props.plate) end
    if changed('plateIndex') then SetVehicleNumberPlateTextIndex(vehicle, props.plateIndex) end
    if changed('bodyHealth') then SetVehicleBodyHealth(vehicle, props.bodyHealth + 0.0) end
    if changed('engineHealth') then SetVehicleEngineHealth(vehicle, props.engineHealth + 0.0) end
    if changed('tankHealth') then SetVehiclePetrolTankHealth(vehicle, props.tankHealth + 0.0) end
    if changed('fuelLevel') then SetVehicleFuelLevel(vehicle, props.fuelLevel + 0.0) end
    if changed('oilLevel') then SetVehicleOilLevel(vehicle, props.oilLevel + 0.0) end
    if changed('dirtLevel') then SetVehicleDirtLevel(vehicle, props.dirtLevel + 0.0) end

    if changed('color1') then
        if type(props.color1) == 'number' then
            ClearVehicleCustomPrimaryColour(vehicle)
            SetVehicleColours(vehicle, props.color1, colorSecondary)
        else
            if props.paintType1 then SetVehicleModColor_1(vehicle, props.paintType1, colorPrimary, pearlescentColor) end
            SetVehicleCustomPrimaryColour(vehicle, props.color1[1], props.color1[2], props.color1[3])
        end
    end

    if changed('color2') then
        if type(props.color2) == 'number' then
            ClearVehicleCustomSecondaryColour(vehicle)
            SetVehicleColours(vehicle, props.color1 or colorPrimary, props.color2)
        else
            if props.paintType2 then SetVehicleModColor_2(vehicle, props.paintType2, colorSecondary) end
            SetVehicleCustomSecondaryColour(vehicle, props.color2[1], props.color2[2], props.color2[3])
        end
    end

    if changed('pearlescentColor') or changed('wheelColor') then
        SetVehicleExtraColours(vehicle, props.pearlescentColor or pearlescentColor, props.wheelColor or wheelColor)
    end

    if changed('wheels') then SetVehicleWheelType(vehicle, props.wheels) end
    if changed('windowTint') then SetVehicleWindowTint(vehicle, props.windowTint) end

    if changed('neonEnabled') then
        for i = 1, #props.neonEnabled do
            SetVehicleNeonLightEnabled(vehicle, i - 1, props.neonEnabled[i])
        end
    end

    if changed('extras') then
        for id, disable in pairs(props.extras) do
            SetVehicleExtra(vehicle, tonumber(id), disable == 1)
        end
    end

    if changed('windows') then
        for i = 1, #props.windows do
            RemoveVehicleWindow(vehicle, props.windows[i])
        end
    end

    if changed('doors') then
        for i = 1, #props.doors do
            SetVehicleDoorBroken(vehicle, props.doors[i], true)
        end
    end

    if changed('tyres') then
        for tyre, state in pairs(props.tyres) do
            SetVehicleTyreBurst(vehicle, tonumber(tyre), state == 2, 1000.0)
        end
    end

    if changed('neonColor') then
        SetVehicleNeonLightsColour(vehicle, props.neonColor[1], props.neonColor[2], props.neonColor[3])
    end

    if changed('modSmokeEnabled') then ToggleVehicleMod(vehicle, 20, props.modSmokeEnabled) end
    if changed('tyreSmokeColor') then
        SetVehicleTyreSmokeColor(vehicle, props.tyreSmokeColor[1], props.tyreSmokeColor[2], props.tyreSmokeColor[3])
    end

    local mods = {
        modSpoilers = 0, modFrontBumper = 1, modRearBumper = 2, modSideSkirt = 3, modExhaust = 4,
        modFrame = 5, modGrille = 6, modHood = 7, modFender = 8, modRightFender = 9, modRoof = 10,
        modEngine = 11, modBrakes = 12, modTransmission = 13, modHorns = 14, modSuspension = 15,
        modArmor = 16, modNitrous = 17, modSubwoofer = 19, modPlateHolder = 25, modVanityPlate = 26,
        modTrimA = 27, modOrnaments = 28, modDashboard = 29, modDial = 30, modDoorSpeaker = 31,
        modSeats = 32, modSteeringWheel = 33, modShifterLeavers = 34, modAPlate = 35, modSpeakers = 36,
        modTrunk = 37, modHydrolic = 38, modEngineBlock = 39, modAirFilter = 40, modStruts = 41,
        modArchCover = 42, modAerials = 43, modTrimB = 44, modTank = 45, modWindows = 46, modLightbar = 49,
    }
    for key, index in pairs(mods) do
        if changed(key) then
            SetVehicleMod(vehicle, index, props[key], false)
        end
    end

    if changed('modTurbo') then ToggleVehicleMod(vehicle, 18, props.modTurbo) end
    if changed('modHydraulics') then ToggleVehicleMod(vehicle, 21, props.modHydraulics) end
    if changed('modXenon') then ToggleVehicleMod(vehicle, 22, props.modXenon) end
    if changed('modFrontWheels') then
        SetVehicleMod(vehicle, 23, props.modFrontWheels, props.modCustomTiresF)
    end
    if changed('modBackWheels') then
        SetVehicleMod(vehicle, 24, props.modBackWheels, props.modCustomTiresR)
    end
    if changed('modLivery') then
        SetVehicleMod(vehicle, 48, props.modLivery, false)
        SetVehicleLivery(vehicle, props.modLivery)
    end
    if changed('modRoofLivery') then SetVehicleRoofLivery(vehicle, props.modRoofLivery) end
    if changed('bulletProofTyres') then SetVehicleTyresCanBurst(vehicle, props.bulletProofTyres) end
    if gameBuild() >= 2372 and changed('driftTyres') then
        SetDriftTyresEnabled(vehicle, props.driftTyres and true or false)
    end

    if fixVehicle then
        SetVehicleFixed(vehicle)
    end

    local merged = {}
    if prev then
        for k, v in pairs(prev) do
            merged[k] = v
        end
    end
    for k, v in pairs(props) do
        merged[k] = v
    end
    lastApplied[vehicle] = merged
    local playerId = PlayerId()
    return not NetworkGetEntityIsNetworked(vehicle) or NetworkGetEntityOwner(vehicle) == playerId
end

-- lastApplied holds one snapshot per vehicle handle ever touched. Handles are
-- recycled by the game, so drop entries whose entity is gone instead of
-- letting the table grow for the lifetime of the client.
CreateThread(function()
    while true do
        Wait(30000)
        for vehicle in pairs(lastApplied) do
            if not DoesEntityExist(vehicle) then
                lastApplied[vehicle] = nil
            end
        end
    end
end)

AddEventHandler('onResourceStop', function(resource)
    if resource == GetCurrentResourceName() then
        lastApplied = {}
    end
end)

-- The cache first, and only the cache when it holds an answer. This is on the
-- door interaction path, which runs every frame while a door is in range, so
-- the fallback seat scan -- up to a dozen native calls -- must not be the
-- normal case.
function GetPlayerVehicleSeat()
    if CisCache and CisCache.vehicle ~= 0 and CisCache.seat ~= nil then
        return CisCache.seat
    end
    local ped = (CisCache and CisCache.ped ~= 0 and CisCache.ped) or PlayerPedId()
    local vehicle = GetVehiclePedIsIn(ped, false)
    if vehicle == 0 then
        return nil
    end
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

-- A 5m aim probe first: a raycast returns the vehicle actually being looked at,
-- which is what a door/vehicle interaction means, and GetClosestVehicle cannot
-- distinguish "under the crosshair" from "nearest to the player". The native is
-- the fallback, and 0 is returned rather than nil to match the game's own
-- convention.
function GetClosestVehicle()
    local ped = (CisCache and CisCache.ped ~= 0 and CisCache.ped) or PlayerPedId()
    local playerCoords = GetEntityCoords(ped)
    local inDirection = GetOffsetFromEntityInWorldCoords(ped, 0.0, 5.0, 0.0)
    local rayHandle = StartExpensiveSynchronousShapeTestLosProbe(playerCoords, inDirection, 10, ped, 0)
    local _, hit, _, _, entityHit = GetShapeTestResult(rayHandle)
    if hit == 1 and GetEntityType(entityHit) == 2 then
        return entityHit
    end
    local vehicle = GetClosestVehicleNative(playerCoords.x, playerCoords.y, playerCoords.z, 5.0, 0, 71)
    if vehicle ~= 0 then
        return vehicle
    end
    return 0
end

exports('GetVehicleProperties', GetVehicleProperties)
exports('SetVehicleProperties', SetVehicleProperties)
exports('GetPlayerVehicleSeat', GetPlayerVehicleSeat)
exports('GetClosestVehicle', GetClosestVehicle)
