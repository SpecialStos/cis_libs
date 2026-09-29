-- Attachment components are listed only when the selected weapon actually has them.

local COMPONENT_SLOTS = {
    `COMPONENT_AT_AR_FLSH`,
    `COMPONENT_AT_PI_FLSH`,
    `COMPONENT_AT_AR_AFGRIP`,
    `COMPONENT_AT_AR_AFGRIP_02`,
    `COMPONENT_AT_SCOPE_MACRO`,
    `COMPONENT_AT_SCOPE_MACRO_02`,
    `COMPONENT_AT_SCOPE_SMALL`,
    `COMPONENT_AT_SCOPE_MEDIUM`,
    `COMPONENT_AT_SCOPE_LARGE`,
    `COMPONENT_AT_SCOPE_MAX`,
    `COMPONENT_AT_SCOPE_NV`,
    `COMPONENT_AT_SCOPE_THERMAL`,
    `COMPONENT_AT_AR_SUPP`,
    `COMPONENT_AT_AR_SUPP_02`,
    `COMPONENT_AT_PI_SUPP`,
    `COMPONENT_AT_PI_SUPP_02`,
    `COMPONENT_AT_SR_SUPP`,
    `COMPONENT_AT_MUZZLE_01`,
    `COMPONENT_AT_MUZZLE_02`,
    `COMPONENT_AT_MUZZLE_03`,
    `COMPONENT_AT_MUZZLE_04`,
    `COMPONENT_AT_MUZZLE_05`,
    `COMPONENT_AT_MUZZLE_06`,
    `COMPONENT_AT_MUZZLE_07`,
}

function GetWeaponAttachments(ped, weaponHash)
    local attachments = {}
    if not ped or ped == 0 or not weaponHash then
        return attachments
    end
    for i = 1, #COMPONENT_SLOTS do
        local component = COMPONENT_SLOTS[i]
        if HasPedGotWeaponComponent(ped, weaponHash, component) then
            attachments[#attachments + 1] = component
        end
    end
    return attachments
end

function GetCurrentWeaponData(ped)
    ped = ped or (CisCache and CisCache.ped) or PlayerPedId()
    if CisCache and CisCache.weapon and ped == CisCache.ped then
        return CisCache.weapon
    end
    local weaponHash = GetSelectedPedWeapon(ped)
    return {
        hash = weaponHash,
        ammo = GetAmmoInPedWeapon(ped, weaponHash),
        ammoType = GetPedAmmoTypeFromWeapon(ped, weaponHash),
        attachments = GetWeaponAttachments(ped, weaponHash),
    }
end

exports('GetCurrentWeaponData', GetCurrentWeaponData)
