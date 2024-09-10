Config = nil
Security = nil

-- Create a new thread
Citizen.CreateThread(function()

    -- Get the version from fxmanifest.lua
    local version = GetResourceMetadata(GetCurrentResourceName(), 'version', 0)

    -- Print a message indicating the start of loading process
    print("cis_libs: Loading (version " .. version .. ")")
    -- Trigger a server event to get the data
    TriggerServerEvent("cis_libs:server:getData")
    -- Wait until Config is not nil
    while Config == nil or Security == nil do
        -- Pause the script for 100ms
        Citizen.Wait(100)
    end
    -- Print a message indicating the end of loading process
    print("cis_libs: Loaded (version " .. version .. ")")
end)

RegisterNetEvent("cis_libs:client:getData", function(data)
    Config = data.Config
    Security = data.Security
end)