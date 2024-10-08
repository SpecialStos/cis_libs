-- cis_libs/server/server_error_handler.lua

local function wrapHandler(handler, eventName)
    return function(...)
        local status, err = pcall(handler, ...)
        if not status then
            exports['cis_libs']:AutoLogError(err, eventName)
        end
    end
end

-- Wrap RegisterNetEvent
local originalRegisterNetEvent = RegisterNetEvent
RegisterNetEvent = function(eventName, handler)
    if handler then
        originalRegisterNetEvent(eventName, wrapHandler(handler, eventName))
    else
        originalRegisterNetEvent(eventName)
    end
end

-- Wrap AddEventHandler
local originalAddEventHandler = AddEventHandler
AddEventHandler = function(eventName, handler)
    originalAddEventHandler(eventName, wrapHandler(handler, eventName))
end

-- Wrap server callbacks
local function wrapCallback(cb)
    return function(...)
        local status, err = pcall(cb, ...)
        if not status then
            exports['cis_libs']:AutoLogError(err, "ServerCallback")
        end
    end
end

-- Framework-specific wrappers
local function initializeFrameworkErrorHandling()
    if Config.Framework.Type == "QBCORE" or Config.Framework.Type == "QBOX" then
        -- QBCore and QBBox server callbacks
        if QBCore and QBCore.Functions then
            local originalCreateCallback = QBCore.Functions.CreateCallback
            QBCore.Functions.CreateCallback = function(name, cb)
                originalCreateCallback(name, wrapCallback(cb))
            end
            print("QBCore/QBox server callback error handling initialized")
        else
            print("Warning: QBCore/QBox object not found. Ensure it's properly initialized.")
        end
    elseif Config.Framework.Type == "ESX" or Config.Framework.Type == "ESX-LEGACY" then
        -- ESX server callbacks
        if ESX then
            local originalRegisterServerCallback = ESX.RegisterServerCallback
            ESX.RegisterServerCallback = function(name, cb)
                originalRegisterServerCallback(name, wrapCallback(cb))
            end
            print("ESX server callback error handling initialized")
        else
            print("Warning: ESX object not found. Ensure it's properly initialized.")
        end
    else
        print("No specific framework detected. Using generic error handling.")
    end
end

-- Initialize framework-specific error handling
Citizen.CreateThread(function()
    -- Wait for the framework to initialize
    Citizen.Wait(5000)
    initializeFrameworkErrorHandling()
end)

-- Generic error handler for custom callbacks
function CreateSafeCallback(name, cb)
    if Config.Framework.Type == "QBCORE" or Config.Framework.Type == "QBOX" then
        QBCore.Functions.CreateCallback(name, cb)
    elseif Config.Framework.Type == "ESX" or Config.Framework.Type == "ESX-LEGACY" then
        ESX.RegisterServerCallback(name, cb)
    else
        -- For no framework, we'll create a simple callback system
        RegisterNetEvent(name)
        AddEventHandler(name, function(...)
            local source = source
            local callback = function(...)
                TriggerClientEvent(name .. ':response', source, ...)
            end
            wrapCallback(cb)(source, callback, ...)
        end)
    end
end

-- Export the safe callback creator
exports('CreateSafeCallback', CreateSafeCallback)
--[[exports['cis_libs']:SafeNetEventHandler('someEvent', function(...)
    -- Event handling code that might error
end)--]]

--print("Server-side error handling initialized for " .. (Config.Framework.Type or "No Framework"))