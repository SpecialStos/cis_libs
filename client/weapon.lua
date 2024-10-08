-- cis_libs/client/weapon.lua

local function GetWeaponAttachments(weaponHash)
    if Config.Printing and Config.Printing.Debug then
        exports['cis_libs']:LogDebug("Getting attachments for weapon hash: " .. tostring(weaponHash))
    end
    -- Implement logic to get weapon attachments
    -- This is a placeholder and needs to be expanded based on game natives
    return {}
end

function GetCurrentWeaponData(ped)
    if Config.Printing and Config.Printing.Debug then
        exports['cis_libs']:LogDebug("Getting current weapon data for ped: " .. tostring(ped))
    end

    local weaponHash = GetSelectedPedWeapon(ped)
    local ammoType = GetPedAmmoTypeFromWeapon(ped, weaponHash)
    
    local weaponData = {
        hash = weaponHash,
        ammo = GetAmmoInPedWeapon(ped, weaponHash),
        ammoType = ammoType,
        attachments = GetWeaponAttachments(weaponHash),
        -- Add more weapon details as needed
    }

    if Config.Printing and Config.Printing.Debug then
        exports['cis_libs']:LogDebug("Weapon data retrieved: " .. json.encode(weaponData))
    end
    return weaponData
end

exports('GetCurrentWeaponData', GetCurrentWeaponData)