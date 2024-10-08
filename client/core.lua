-- cis_libs/client/core.lua

Citizen.CreateThread(function()
    print("cis_libs: Loading core")
    while Config == nil or Security == nil do
        Citizen.Wait(100)
    end

    if Config.Printing and Config.Printing.Debug then
        exports['cis_libs']:LogInfo("Core initialization started")
    end

    Globals = {}

    Globals.ServerInfo = {
        GameBuild = GetGameBuildNumber(),
        Framework = Config.Framework,
        Debug = Config.Printing.Debug,
    }

    print("cis_libs: Loaded core")

    if Config.Printing and Config.Printing.Debug then
        exports['cis_libs']:LogDebug("Server info initialized: " .. json.encode(Globals.ServerInfo))
    end

    -- Player variables
    Globals.Player = {
        Ped = nil,
        PedId = nil,
        ServerId = GetPlayerServerId(PlayerId()),
        Coords = vector3(0, 0, 0),
        Heading = 0.0,
        IsArmed = false,
        IsShooting = false,
        IsAiming = false,
        IsInVehicle = false,
        Weapon = nil,
    }

    if Config.Printing and Config.Printing.Debug then
        exports['cis_libs']:LogDebug("Player globals initialized")
    end

    -- Vehicle variables
    Globals.Vehicle = {
        Current = 0,
        Last = 0,
        Seat = nil,
        Properties = {},
    }

    if Config.Printing and Config.Printing.Debug then
        exports['cis_libs']:LogDebug("Vehicle globals initialized")
    end

    -- Main thread for updating player data
    Citizen.CreateThread(function()
        while true do
            local status, err = pcall(function()
                Globals.Player.Ped = PlayerPedId()
                Globals.Player.PedId = PlayerId()
                Globals.Player.Coords = GetEntityCoords(Globals.Player.Ped)
                Globals.Player.Heading = GetEntityHeading(Globals.Player.Ped)
                Globals.Player.Coords4 = vec4(Globals.Player.Coords.x, Globals.Player.Coords.y, Globals.Player.Coords.z, Globals.Player.Heading)
                Globals.Player.IsArmed = IsPedArmed(Globals.Player.Ped, 7)
                Globals.Player.IsShooting = IsPedShooting(Globals.Player.Ped)
                Globals.Player.IsInVehicle = IsPedInAnyVehicle(Globals.Player.Ped, false)

                if(Config.AimingCheckType == "default")then
                    Globals.Player.IsAiming = IsPlayerFreeAiming(Globals.Player.PedId) == 1
                else
                    Globals.Player.IsAiming = GetPedConfigFlag(Globals.Player.PedId, 78) == 1
                end
            end)

            if not status and Config.Printing and Config.Printing.Debug then
                exports['cis_libs']:LogError("Error in core update thread: " .. tostring(err))
            end
            
            Citizen.Wait(Config.UpdateInterval.Player)
        end
    end)


    -- Main thread for vehicle data
    Citizen.CreateThread(function()
        while true do
            -- Update vehicle info
            if Globals.Player.IsInVehicle then
                Globals.Vehicle.Current = GetVehiclePedIsIn(Globals.Player.Ped, false)
                if Globals.Vehicle.Current ~= Globals.Vehicle.Last then
                    if Config.Printing and Config.Printing.Debug then
                        exports['cis_libs']:LogInfo("Player entered new vehicle: " .. Globals.Vehicle.Current)
                    end
                    Globals.Vehicle.Last = Globals.Vehicle.Current
                end
                Globals.Vehicle.Seat = GetPlayerVehicleSeat()
                Globals.Vehicle.Properties = exports.cis_libs:GetVehicleProperties(Globals.Vehicle.Current)
            else
                if Globals.Vehicle.Current ~= 0 then
                    if Config.Printing and Config.Printing.Debug then
                        exports['cis_libs']:LogInfo("Player exited vehicle: " .. Globals.Vehicle.Current)
                    end
                    Globals.Vehicle.Current = 0
                end
                Globals.Vehicle.Properties = {}
            end

            Citizen.Wait(Config.UpdateInterval.Vehicle)
        end
    end)

    -- Main thread for weapon data.
    Citizen.CreateThread(function()
        while true do
            -- Update weapon info
            if Globals.Player.IsArmed then
                Globals.Player.Weapon = exports.cis_libs:GetCurrentWeaponData(Globals.Player.Ped)
                if Config.Printing and Config.Printing.Debug then
                    exports['cis_libs']:LogDebug("Player armed with weapon: " .. json.encode(Globals.Player.Weapon))
                end
            else
                Globals.Player.Weapon = nil
            end
            Citizen.Wait(Config.UpdateInterval.Weapon)
        end
    end)

    if Config.Printing and Config.Printing.Debug then
        exports['cis_libs']:LogInfo("Core initialization completed")
    end

    -- Expose globals
    exports('GetGlobals', function() return Globals end)
end)