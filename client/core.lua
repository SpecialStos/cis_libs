-- cis_libs/client/core.lua

Citizen.CreateThread(function()

    while Config == nil or Security == nil do
        -- Pause the script for 100ms
        Citizen.Wait(100)
    end

    Globals = {}


    Globals.ServerInfo = {
        GameBuild = GetGameBuildNumber(),
        Framework = Config.Framework,
        Debug = Config.Debug,
    }

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
        Weapon = nil, -- This will be populated with detailed weapon info
    }

    -- Vehicle variables
    Globals.Vehicle = {
        Current = 0,
        Last = 0,
        Seat = nil,
        Properties = {}, -- This will be populated with detailed vehicle properties
    }

    -- Main thread for updating player data
    Citizen.CreateThread(function()
        while true do
            Globals.Player.Ped = PlayerPedId()
            Globals.Player.PedId = PlayerId()
            Globals.Player.Coords = GetEntityCoords(Globals.Player.Ped)
            Globals.Player.Heading = GetEntityHeading(Globals.Player.Ped)
            Globals.Player.Coords4 = vec4(Globals.Player.Coords.x, Globals.Player.Coords.y, Globals.Player.Coords.z, Globals.Player.Heading)
            Globals.Player.IsArmed = IsPedArmed(Globals.Player.Ped, 7)
            Globals.Player.IsShooting = IsPedShooting(Globals.Player.Ped)
            Globals.Player.IsInVehicle = IsPedInAnyVehicle(Globals.Player.Ped, false)

            if(Config.AimingCheckType == "default")then
                if(IsPlayerFreeAiming(Globals.Player.PedId) == 1)then
                    Globals.Player.IsAiming = true
                else
                    Globals.Player.IsAiming = false
                end
            else
                if(GetPedConfigFlag(Globals.Player.PedId, 78) == 1)then
                    Globals.Player.IsAiming = true
                else
                    Globals.Player.IsAiming = false
                end
            end
            
            -- Update weapon info
            if Globals.Player.IsArmed then
                Globals.Player.Weapon = exports.cis_libs:GetCurrentWeaponData(Globals.Player.Ped)
            else
                Globals.Player.Weapon = nil
            end
            
            -- Update vehicle info
            if Globals.Player.IsInVehicle then
                Globals.Vehicle.Current = GetVehiclePedIsIn(Globals.Player.Ped, false)
                Globals.Vehicle.Last = Globals.Vehicle.Current
                Globals.Vehicle.Seat = GetPlayerVehicleSeat()
                Globals.Vehicle.Properties = exports.cis_libs:GetVehicleProperties(Globals.Vehicle.Current)
            else
                Globals.Vehicle.Current = nil
                Globals.Vehicle.Properties = {}
            end
            
            Citizen.Wait(Config.UpdateInterval.Player)
        end
    end)

    -- Expose globals
    exports('GetGlobals', function() return Globals end)

end)