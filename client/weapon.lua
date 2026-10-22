-- Weapon data, and the attachments the selected weapon actually carries.
--
-- WHICH COMPONENTS A WEAPON CAN TAKE IS THE GAME'S ANSWER, NOT OURS. The list
-- below is a deliberately generous SUPERSET of component names: every generic
-- `COMPONENT_AT_*` attachment, plus the per-weapon families (clips, MK2 rounds,
-- finishes, camos) for every weapon whose short name is known. On the first
-- look at a weapon, DOES_WEAPON_TAKE_WEAPON_COMPONENT filters that superset down
-- to the components THIS weapon takes, and that short list is cached for the
-- session. A name that does not exist costs one native call, once, and is never
-- asked again; a real component missing from the superset is the only failure
-- mode, and the old table -- 24 generic attachments, no clips, no MK2 rounds, no
-- finishes -- was that failure mode for most of what a player can buy.

local GENERIC = {
    'AT_AR_FLSH', 'AT_AR_FLSH_REH', 'AT_PI_FLSH', 'AT_PI_FLSH_02', 'AT_PI_FLSH_03',
    'AT_AR_AFGRIP', 'AT_AR_AFGRIP_02',
    'AT_SIGHTS', 'AT_SIGHTS_SMG', 'AT_PI_RAIL', 'AT_PI_RAIL_02',
    'AT_SCOPE_MACRO', 'AT_SCOPE_MACRO_02', 'AT_SCOPE_MACRO_MK2', 'AT_SCOPE_MACRO_02_MK2',
    'AT_SCOPE_MACRO_02_SMG_MK2', 'AT_SCOPE_SMALL', 'AT_SCOPE_SMALL_02', 'AT_SCOPE_SMALL_MK2',
    'AT_SCOPE_SMALL_SMG_MK2', 'AT_SCOPE_MEDIUM', 'AT_SCOPE_MEDIUM_MK2', 'AT_SCOPE_LARGE',
    'AT_SCOPE_LARGE_MK2', 'AT_SCOPE_LARGE_FIXED_ZOOM', 'AT_SCOPE_LARGE_FIXED_ZOOM_MK2',
    'AT_SCOPE_MAX', 'AT_SCOPE_NV', 'AT_SCOPE_THERMAL',
    'AT_AR_SUPP', 'AT_AR_SUPP_02', 'AT_PI_SUPP', 'AT_PI_SUPP_02', 'AT_SR_SUPP', 'AT_SR_SUPP_03',
    'AT_PI_COMP', 'AT_PI_COMP_02', 'AT_PI_COMP_03',
    'AT_MUZZLE_01', 'AT_MUZZLE_02', 'AT_MUZZLE_03', 'AT_MUZZLE_04', 'AT_MUZZLE_05',
    'AT_MUZZLE_06', 'AT_MUZZLE_07', 'AT_MUZZLE_08', 'AT_MUZZLE_09',
    'AT_AR_BARREL_01', 'AT_AR_BARREL_02', 'AT_BP_BARREL_01', 'AT_BP_BARREL_02',
    'AT_CR_BARREL_01', 'AT_CR_BARREL_02', 'AT_MG_BARREL_01', 'AT_MG_BARREL_02',
    'AT_MRFL_BARREL_01', 'AT_MRFL_BARREL_02', 'AT_SB_BARREL_01', 'AT_SB_BARREL_02',
    'AT_SC_BARREL_01', 'AT_SC_BARREL_02', 'AT_SR_BARREL_01', 'AT_SR_BARREL_02',
}

-- The per-weapon component families, as COMPONENT_<weapon>_<suffix>.
local FAMILIES = {
    'CLIP_01', 'CLIP_02', 'CLIP_03', 'CLIP_04', 'CLIP_BOXMAG', 'CLIP_DRUM',
    'CLIP_TRACER', 'CLIP_INCENDIARY', 'CLIP_ARMORPIERCING', 'CLIP_FMJ', 'CLIP_HOLLOWPOINT',
    'CLIP_EXPLOSIVE',
    'VARMOD_LUXE', 'VARMOD_LOWRIDER', 'VARMOD_SECURITY', 'VARMOD_XMAS18', 'VARMOD_XM3',
    'VARMOD_BOSS', 'VARMOD_GOON', 'VARMOD_BASE', 'VARMOD_PIMP', 'VARMOD_BALLAS', 'VARMOD_DOLLAR',
    'VARMOD_DIAMOND', 'VARMOD_HATE', 'VARMOD_LOVE', 'VARMOD_PLAYER', 'VARMOD_KING', 'VARMOD_VAGOS',
    'CAMO', 'CAMO_02', 'CAMO_03', 'CAMO_04', 'CAMO_05', 'CAMO_06', 'CAMO_07', 'CAMO_08',
    'CAMO_09', 'CAMO_10', 'CAMO_IND_01',
    'CAMO_SLIDE', 'CAMO_02_SLIDE', 'CAMO_03_SLIDE', 'CAMO_04_SLIDE', 'CAMO_05_SLIDE',
    'CAMO_06_SLIDE', 'CAMO_07_SLIDE', 'CAMO_08_SLIDE', 'CAMO_09_SLIDE', 'CAMO_10_SLIDE',
    'CAMO_IND_01_SLIDE',
}

-- Weapon short names as the component names spell them (WEAPON_<name> is the
-- weapon, COMPONENT_<name>_* its components).
local WEAPONS = {
    'PISTOL', 'COMBATPISTOL', 'APPISTOL', 'PISTOL50', 'SNSPISTOL', 'HEAVYPISTOL', 'VINTAGEPISTOL',
    'REVOLVER', 'PISTOL_MK2', 'SNSPISTOL_MK2', 'REVOLVER_MK2', 'CERAMICPISTOL', 'PISTOLXM3',
    'TECPISTOL', 'GADGETPISTOL', 'MARKSMANPISTOL', 'NAVYREVOLVER', 'RAYPISTOL',
    'MICROSMG', 'SMG', 'ASSAULTSMG', 'COMBATPDW', 'MINISMG', 'MACHINEPISTOL', 'SMG_MK2',
    'ASSAULTRIFLE', 'CARBINERIFLE', 'ADVANCEDRIFLE', 'SPECIALCARBINE', 'BULLPUPRIFLE',
    'COMPACTRIFLE', 'ASSAULTRIFLE_MK2', 'CARBINERIFLE_MK2', 'SPECIALCARBINE_MK2',
    'BULLPUPRIFLE_MK2', 'MILITARYRIFLE', 'HEAVYRIFLE', 'TACTICALRIFLE', 'BATTLERIFLE',
    'MG', 'COMBATMG', 'GUSENBERG', 'COMBATMG_MK2',
    'SNIPERRIFLE', 'HEAVYSNIPER', 'MARKSMANRIFLE', 'HEAVYSNIPER_MK2', 'MARKSMANRIFLE_MK2',
    'PRECISIONRIFLE',
    'PUMPSHOTGUN', 'SAWNOFFSHOTGUN', 'ASSAULTSHOTGUN', 'BULLPUPSHOTGUN', 'HEAVYSHOTGUN',
    'PUMPSHOTGUN_MK2', 'COMBATSHOTGUN',
    'KNUCKLE', 'SWITCHBLADE',
}

local GENERIC_HASHES
local WEAPON_NAME_BY_HASH
-- weapon hash -> array of the component hashes it can take. Built once each.
local takes = {}

local function build()
    if GENERIC_HASHES then
        return
    end
    GENERIC_HASHES = {}
    for i = 1, #GENERIC do
        GENERIC_HASHES[i] = joaat('COMPONENT_' .. GENERIC[i])
    end
    WEAPON_NAME_BY_HASH = {}
    for i = 1, #WEAPONS do
        WEAPON_NAME_BY_HASH[joaat('WEAPON_' .. WEAPONS[i])] = WEAPONS[i]
    end
end

local function componentsFor(weaponHash)
    local list = takes[weaponHash]
    if list then
        return list
    end
    build()
    list = {}
    local seen = {}
    local function consider(hash)
        if not seen[hash] then
            seen[hash] = true
            if DoesWeaponTakeWeaponComponent(weaponHash, hash) then
                list[#list + 1] = hash
            end
        end
    end
    for i = 1, #GENERIC_HASHES do
        consider(GENERIC_HASHES[i])
    end
    local name = WEAPON_NAME_BY_HASH[weaponHash]
    if name then
        for i = 1, #FAMILIES do
            consider(joaat(('COMPONENT_%s_%s'):format(name, FAMILIES[i])))
        end
    end
    takes[weaponHash] = list
    return list
end

function GetWeaponAttachments(ped, weaponHash)
    local attachments = {}
    if not ped or ped == 0 or not weaponHash or weaponHash == 0 then
        return attachments
    end
    local list = componentsFor(weaponHash)
    for i = 1, #list do
        local component = list[i]
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
