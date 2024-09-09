-- cis_libs/client/weapon.lua

local function GetWeaponAttachments(weaponHash)
    -- Implement logic to get weapon attachments
    -- This is a placeholder and needs to be expanded based on game natives
    return {}
end

function GetCurrentWeaponData(ped)
    local weaponHash = GetSelectedPedWeapon(ped)
    local ammoType = GetPedAmmoTypeFromWeapon(ped, weaponHash)
    
    return {
        hash = weaponHash,
        ammo = GetAmmoInPedWeapon(ped, weaponHash),
        ammoType = ammoType,
        attachments = GetWeaponAttachments(weaponHash),
        -- Add more weapon details as needed
    }
end

exports('GetCurrentWeaponData', GetCurrentWeaponData)