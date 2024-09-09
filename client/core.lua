-- cis_libs/client/core.lua

local Globals = {}

-- Player variables
Globals.Player = {
    Ped = nil,
    PedId = nil,
    ServerId = nil,
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
    Current = nil,
    Properties = {}, -- This will be populated with detailed vehicle properties
}

-- Main thread for updating player data
Citizen.CreateThread(function()
    while true do
        Globals.Player.Ped = PlayerPedId()
        Globals.Player.PedId = PlayerId()
        Globals.Player.ServerId = GetPlayerServerId(Globals.Player.PedId)
        Globals.Player.Coords = GetEntityCoords(Globals.Player.Ped)
        Globals.Player.Heading = GetEntityHeading(Globals.Player.Ped)
        Globals.Player.IsArmed = IsPedArmed(Globals.Player.Ped, 7)
        Globals.Player.IsShooting = IsPedShooting(Globals.Player.Ped)
        Globals.Player.IsAiming = IsPlayerFreeAiming(Globals.Player.PedId)
        Globals.Player.IsInVehicle = IsPedInAnyVehicle(Globals.Player.Ped, false)
        
        -- Update weapon info
        if Globals.Player.IsArmed then
            Globals.Player.Weapon = exports.cis_libs:GetCurrentWeaponData(Globals.Player.Ped)
        else
            Globals.Player.Weapon = nil
        end
        
        -- Update vehicle info
        if Globals.Player.IsInVehicle then
            Globals.Vehicle.Current = GetVehiclePedIsIn(Globals.Player.Ped, false)
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