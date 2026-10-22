-- Vehicle property capture and apply.
--
-- FIELD-COMPATIBLE WITH ox_lib's getVehicleProperties / setVehicleProperties:
-- the same field names, the same value shapes and the same meanings, so a row a
-- garage saved through either library applies through the other. Where this
-- file used to disagree it was wrong on a live server, not merely different:
-- `bulletProofTyres` held the inverse of its name, extras 0 and 16-20 were never
-- read, and five fields were read and never written back.
--
-- Get returns EVERYTHING; Set applies what is PRESENT and nothing else, so a
-- partial props table is safe -- missing keys are left alone rather than zeroed.
--
-- THERE IS NO DIFF. Set used to compare every field against a snapshot of what
-- it last applied, keyed by entity handle. Anything else that changed the
-- vehicle -- gameplay damage, another resource, a repair -- made the snapshot a
-- lie, so a re-apply of the saved props was skipped exactly when it was needed;
-- and handles are recycled, so a new vehicle inherited the old one's snapshot.
-- Every field is a handful of natives, applied when asked.

local function gameBuild()
    if Globals and Globals.ServerInfo and Globals.ServerInfo.GameBuild then
        return Globals.ServerInfo.GameBuild
    end
    return GetGameBuildNumber()
end

-- Tyre indices, as SET_VEHICLE_TYRE_BURST numbers them: 0-5 for the four (or
-- six) road wheels, 6-7 for a bike, and 45 / 47 for the middle pair of a
-- six-wheeled trailer.
local TYRES = { 0, 1, 2, 3, 4, 5, 6, 7, 45, 47 }

-- Every mod slot SetVehicleMod writes by index. 18, 20, 21 and 22 are toggles
-- and are handled separately; 23 and 24 carry the custom-tyre flag; 48 is the
-- livery and is applied with SetVehicleLivery as well.
local MODS = {
    modSpoilers = 0, modFrontBumper = 1, modRearBumper = 2, modSideSkirt = 3, modExhaust = 4,
    modFrame = 5, modGrille = 6, modHood = 7, modFender = 8, modRightFender = 9, modRoof = 10,
    modEngine = 11, modBrakes = 12, modTransmission = 13, modHorns = 14, modSuspension = 15,
    modArmor = 16, modNitrous = 17, modSubwoofer = 19, modPlateHolder = 25, modVanityPlate = 26,
    modTrimA = 27, modOrnaments = 28, modDashboard = 29, modDial = 30, modDoorSpeaker = 31,
    modSeats = 32, modSteeringWheel = 33, modShifterLeavers = 34, modAPlate = 35, modSpeakers = 36,
    modTrunk = 37, modHydrolic = 38, modEngineBlock = 39, modAirFilter = 40, modStruts = 41,
    modArchCover = 42, modAerials = 43, modTrimB = 44, modTank = 45, modWindows = 46,
    modDoorR = 47, modLightbar = 49,
}

-- The VMT_* toggles (TOGGLE_VEHICLE_MOD / IS_TOGGLE_MOD_ON), as ox_lib reads them.
local TOGGLES = { modTurbo = 18, modSmokeEnabled = 20, modHydraulics = 21, modXenon = 22 }

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

    -- Extras 0..20, stored as the native's `disable` flag: 0 is an extra that was
    -- ON, 1 is one that was OFF. `IsVehicleExtraTurnedOn` is the getter -- there
    -- is no `GetVehicleExtra` native.
    local extras = {}
    for i = 0, 20 do
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
    -- Do not roll windows up while reading. A getter that mutates the vehicle
    -- is not a getter.
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
    for _, i in ipairs(TYRES) do
        if IsVehicleTyreBurst(vehicle, i, false) then
            damage.tyres[i] = IsVehicleTyreBurst(vehicle, i, true) and 2 or 1
        end
    end

    local neons = {}
    for i = 0, 3 do
        neons[i + 1] = IsVehicleNeonLightEnabled(vehicle, i)
    end

    local props = {
        model = GetEntityModel(vehicle),
        plate = GetVehicleNumberPlateText(vehicle),
        plateIndex = GetVehicleNumberPlateTextIndex(vehicle),
        -- 0 is unlocked. GET_VEHICLE_DOOR_LOCK_STATUS -> int. Not an ox_lib field;
        -- an extra one, applied only when present.
        lockState = GetVehicleDoorLockStatus(vehicle),
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
        modFrontWheels = GetVehicleMod(vehicle, 23),
        modBackWheels = GetVehicleMod(vehicle, 24),
        modCustomTiresF = GetVehicleModVariation(vehicle, 23),
        modCustomTiresR = GetVehicleModVariation(vehicle, 24),
        modLivery = modLivery,
        -- livery (GetVehicleLivery) and modLivery (mod 48) are not the same
        -- number on every vehicle.
        livery = GetVehicleLivery(vehicle),
        modRoofLivery = GetVehicleRoofLivery(vehicle),
        windows = damage.windows,
        doors = damage.doors,
        tyres = damage.tyres,
        -- THE NAME IS THE MEANING. GET_VEHICLE_TYRES_CAN_BURST answers whether
        -- the tyres CAN burst, so a bulletproof set is the negation -- as ox_lib
        -- and qb store it. Storing the native's answer as-is made every saved
        -- "bulletproof" vehicle burstable and the reverse.
        bulletProofTyres = not GetVehicleTyresCanBurst(vehicle),
        driftTyres = gameBuild() >= 2372 and GetDriftTyresEnabled(vehicle),
    }
    for key, index in pairs(MODS) do
        props[key] = GetVehicleMod(vehicle, index)
    end
    for key, index in pairs(TOGGLES) do
        props[key] = IsToggleModOn(vehicle, index)
    end
    return props
end

-- WRITING NEEDS NETWORK CONTROL. A client writing to a networked vehicle it
-- does not control is overwritten by the owner's next sync, so the write looks
-- like it worked and silently does not. Control is requested and the call
-- answers `false, reason` at once rather than blocking: the caller -- a sync
-- loop, a garage -- retries on its own schedule.
local function hasControl(vehicle)
    if not NetworkGetEntityIsNetworked(vehicle) then
        return true
    end
    if NetworkHasControlOfEntity(vehicle) then
        return true
    end
    NetworkRequestControlOfEntity(vehicle)
    return false
end

-- Applies what `props` names and nothing else.
-- @return true, or false plus a reason. Nothing is written on a refusal.
function SetVehicleProperties(vehicle, props, fixVehicle)
    if not DoesEntityExist(vehicle) then
        return false, 'the vehicle does not exist'
    end
    if type(props) ~= 'table' then
        return false, ('props arrived as %s, not a table'):format(type(props))
    end
    if not hasControl(vehicle) then
        return false, 'this client does not control the vehicle; control was requested, retry'
    end

    -- Read BEFORE anything is written, so an omitted colour keeps the vehicle's own.
    local colorPrimary, colorSecondary = GetVehicleColours(vehicle)
    local pearlescentColor, wheelColor = GetVehicleExtraColours(vehicle)

    SetVehicleModKit(vehicle, 0)

    -- REPAIR FIRST. SetVehicleFixed restores health, glass, doors and tyres, so
    -- running it after the props were applied undid the saved damage it was
    -- handed -- a vehicle stored with two burst tyres came back pristine.
    if fixVehicle then
        SetVehicleFixed(vehicle)
    end

    if props.extras then
        -- THE NATIVE'S THIRD PARAMETER IS `disable`, and the getter stores 0 for
        -- an extra that was ON and 1 for one that was OFF, so the stored value IS
        -- that flag. SENT AS AN INTEGER: the declaration carries the note
        -- "Confirmed p2 does not work as a bool. Changed to int. [0=on, 1=off]"
        -- (citizenfx/natives, SET_VEHICLE_EXTRA.md).
        for id, disable in pairs(props.extras) do
            SetVehicleExtra(vehicle, tonumber(id), disable == 1 and 1 or 0)
        end
    end

    -- lockState 0 is a real state (unlocked), so presence is `~= nil`.
    if props.lockState ~= nil then SetVehicleDoorsLocked(vehicle, props.lockState) end
    if props.plate then SetVehicleNumberPlateText(vehicle, props.plate) end
    if props.plateIndex then SetVehicleNumberPlateTextIndex(vehicle, props.plateIndex) end
    if props.bodyHealth then SetVehicleBodyHealth(vehicle, props.bodyHealth + 0.0) end
    if props.engineHealth then SetVehicleEngineHealth(vehicle, props.engineHealth + 0.0) end
    if props.tankHealth then SetVehiclePetrolTankHealth(vehicle, props.tankHealth + 0.0) end
    if props.fuelLevel then SetVehicleFuelLevel(vehicle, props.fuelLevel + 0.0) end
    if props.oilLevel then SetVehicleOilLevel(vehicle, props.oilLevel + 0.0) end
    if props.dirtLevel then SetVehicleDirtLevel(vehicle, props.dirtLevel + 0.0) end

    -- COLOURS. A palette colour is a NUMBER, a custom one an { r, g, b } table,
    -- and the two are written by different natives.
    --
    -- SetVehicleColours takes BOTH indices, so the side the props do not name as
    -- a palette number keeps the vehicle's live index. It used to be handed
    -- "whatever color1 applied", which was nil when only color2 was given (the
    -- primary reset to black) and a TABLE when color1 was custom (the native
    -- raised, and every property after it was never applied).
    local c1, c2 = props.color1, props.color2
    local palette1 = type(c1) == 'number'
    local palette2 = type(c2) == 'number'
    if palette1 or palette2 then
        -- The finish first: SET_VEHICLE_MOD_COLOR_* sets the paint type and an
        -- index within it, and SetVehicleColours then sets the palette colour.
        if palette1 then
            ClearVehicleCustomPrimaryColour(vehicle)
            if props.paintType1 then SetVehicleModColor_1(vehicle, props.paintType1, 0, props.pearlescentColor or pearlescentColor) end
        end
        if palette2 then
            ClearVehicleCustomSecondaryColour(vehicle)
            if props.paintType2 then SetVehicleModColor_2(vehicle, props.paintType2, 0) end
        end
        SetVehicleColours(vehicle, palette1 and c1 or colorPrimary, palette2 and c2 or colorSecondary)
    end
    if type(c1) == 'table' then
        if props.paintType1 then SetVehicleModColor_1(vehicle, props.paintType1, 0, props.pearlescentColor or pearlescentColor) end
        SetVehicleCustomPrimaryColour(vehicle, c1[1], c1[2], c1[3])
    end
    if type(c2) == 'table' then
        if props.paintType2 then SetVehicleModColor_2(vehicle, props.paintType2, 0) end
        SetVehicleCustomSecondaryColour(vehicle, c2[1], c2[2], c2[3])
    end

    if props.pearlescentColor or props.wheelColor then
        SetVehicleExtraColours(vehicle, props.pearlescentColor or pearlescentColor, props.wheelColor or wheelColor)
    end
    if props.interiorColor then SetVehicleInteriorColor(vehicle, props.interiorColor) end
    if props.dashboardColor then SetVehicleDashboardColor(vehicle, props.dashboardColor) end

    if props.wheels then SetVehicleWheelType(vehicle, props.wheels) end
    if props.windowTint then SetVehicleWindowTint(vehicle, props.windowTint) end

    if props.neonEnabled then
        for i = 1, #props.neonEnabled do
            SetVehicleNeonLightEnabled(vehicle, i - 1, props.neonEnabled[i])
        end
    end
    if props.neonColor then
        SetVehicleNeonLightsColour(vehicle, props.neonColor[1], props.neonColor[2], props.neonColor[3])
    end

    if props.windows then
        for i = 1, #props.windows do
            RemoveVehicleWindow(vehicle, props.windows[i])
        end
    end
    if props.doors then
        for i = 1, #props.doors do
            SetVehicleDoorBroken(vehicle, props.doors[i], true)
        end
    end
    if props.tyres then
        for tyre, state in pairs(props.tyres) do
            SetVehicleTyreBurst(vehicle, tonumber(tyre), state == 2, 1000.0)
        end
    end

    if props.tyreSmokeColor then
        SetVehicleTyreSmokeColor(vehicle, props.tyreSmokeColor[1], props.tyreSmokeColor[2], props.tyreSmokeColor[3])
    end

    for key, index in pairs(MODS) do
        if props[key] then
            SetVehicleMod(vehicle, index, props[key], false)
        end
    end
    for key, index in pairs(TOGGLES) do
        if props[key] ~= nil then
            ToggleVehicleMod(vehicle, index, props[key] and true or false)
        end
    end
    if props.xenonColor then SetVehicleXenonLightsColor(vehicle, props.xenonColor) end
    if props.modFrontWheels then
        SetVehicleMod(vehicle, 23, props.modFrontWheels, props.modCustomTiresF and true or false)
    end
    if props.modBackWheels then
        SetVehicleMod(vehicle, 24, props.modBackWheels, props.modCustomTiresR and true or false)
    end
    -- AFTER the wheel mods: SET_VEHICLE_WHEEL_SIZE / _WIDTH only work on
    -- non-default wheels, so on a fresh vehicle they need the rims first.
    if props.wheelSize then SetVehicleWheelSize(vehicle, props.wheelSize + 0.0) end
    if props.wheelWidth then SetVehicleWheelWidth(vehicle, props.wheelWidth + 0.0) end

    if props.modLivery then
        SetVehicleMod(vehicle, 48, props.modLivery, false)
        SetVehicleLivery(vehicle, props.modLivery)
    end
    if props.livery then SetVehicleLivery(vehicle, props.livery) end
    if props.modRoofLivery then SetVehicleRoofLivery(vehicle, props.modRoofLivery) end
    if props.bulletProofTyres ~= nil then
        SetVehicleTyresCanBurst(vehicle, not props.bulletProofTyres)
    end
    if gameBuild() >= 2372 and props.driftTyres ~= nil then
        SetDriftTyresEnabled(vehicle, props.driftTyres and true or false)
    end

    return true
end

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

local CLOSEST_RANGE = 5.0
-- START_EXPENSIVE_SYNCHRONOUS_SHAPE_TEST_LOS_PROBE flags: 2 = vehicles.
local PROBE_VEHICLES = 2

-- The vehicle the player means: the one under a 5 m forward probe if there is
-- one, otherwise the nearest within 5 m from the vehicle pool. 0 when there is
-- none, the game's own "no entity".
--
-- A CIS-PREFIXED GLOBAL. This used to be a global named GetClosestVehicle, which
-- REPLACED the native of that name for every file in cis_libs -- and its own
-- fallback then called the native, which misses most parked and player
-- vehicles anyway. The export keeps its published name.
function CisGetClosestVehicle()
    local ped = (CisCache and CisCache.ped ~= 0 and CisCache.ped) or PlayerPedId()
    local from = GetEntityCoords(ped)
    if not from or from.x == nil then
        return 0
    end
    local to = GetOffsetFromEntityInWorldCoords(ped, 0.0, CLOSEST_RANGE, 0.0)
    if to and to.x ~= nil then
        -- SIX FLOATS, not two vectors: the probe takes x1, y1, z1, x2, y2, z2.
        local handle = StartExpensiveSynchronousShapeTestLosProbe(
            from.x, from.y, from.z, to.x, to.y, to.z, PROBE_VEHICLES, ped, 7)
        local status, hit, _, _, entityHit = GetShapeTestResult(handle)
        -- `hit` is a BOOL out-parameter; CfxLua hands those back as 0/1. Both
        -- spellings are accepted so a runtime that answers a boolean agrees.
        if status == 2 and (hit == true or hit == 1) and entityHit and entityHit ~= 0
            and GetEntityType(entityHit) == 2 then
            return entityHit
        end
    end
    local best, best2 = 0, CLOSEST_RANGE * CLOSEST_RANGE
    local pool = GetGamePool('CVehicle')
    for i = 1, #pool do
        local vehicle = pool[i]
        local c = GetEntityCoords(vehicle)
        if c and c.x ~= nil then
            local dx, dy, dz = c.x - from.x, c.y - from.y, c.z - from.z
            local d2 = dx * dx + dy * dy + dz * dz
            if d2 <= best2 then
                best, best2 = vehicle, d2
            end
        end
    end
    return best
end

exports('GetVehicleProperties', GetVehicleProperties)
exports('SetVehicleProperties', SetVehicleProperties)
exports('GetPlayerVehicleSeat', GetPlayerVehicleSeat)
exports('GetClosestVehicle', CisGetClosestVehicle)
