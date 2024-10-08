-- cis_libs/client/initialize.lua

Config = nil
Security = nil
DoorData = nil

-- Create a new thread
Citizen.CreateThread(function()
    -- Get the version from fxmanifest.lua
    local version = GetResourceMetadata(GetCurrentResourceName(), 'version', 0)

    -- Print a message indicating the start of loading process
    print("cis_libs: Loading (version " .. version .. ")")
    
    -- Trigger a server event to get the data
    TriggerServerEvent("cis_libs:server:getData")

    -- Wait for Config and Security to be loaded
    while Config == nil or Security == nil do
        Citizen.Wait(100)
    end
    
    -- Wait for DoorData to be received
    while DoorData == nil do
        Citizen.Wait(100)
    end

    -- Process door data
    if DoorData then
        for doorId, doorInfo in pairs(DoorData.doors) do
            TriggerEvent(Security.EventPrefix .. ':doorlock:addDoor', doorInfo)
        end
        for groupId, groupInfo in pairs(DoorData.groups) do
            TriggerEvent(Security.EventPrefix .. ':doorlock:addDoorGroup', groupInfo)
        end
        if Config.Printing and Config.Printing.Debug then
            exports['cis_libs']:LogDebug("Finished processing door data")
        end
    else
        if Config.Printing and Config.Printing.Debug then
            exports['cis_libs']:LogWarn("No door data received")
        end
    end

    -- Print a message indicating the end of loading process
    print("cis_libs: Loaded (version " .. version .. ")")

    if Config.Printing and Config.Printing.Debug then
        exports['cis_libs']:LogDebug("Initialization complete, including door data processing")
    end
end)

RegisterNetEvent("cis_libs:client:getData")
AddEventHandler("cis_libs:client:getData", function(data)
    Config = data.Config
    Security = data.Security
    DoorData = data.DoorData
    print(json.encode(DoorData))
    if Config.Printing and Config.Printing.Debug then
        exports['cis_libs']:LogDebug("Received and stored initial data including door information")
    end
end)