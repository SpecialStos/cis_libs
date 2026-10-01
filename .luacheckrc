-- T1. Real lint.
--
-- Before this, `tools/luacheck.js` was the only thing checking Lua, and it only
-- PARSED. It could tell you a file had a syntax error. It could not tell you
-- about an unused variable, a shadowed local, a global assigned without `local`,
-- or a misspelled native -- which are the defects that survive a parse and cost
-- an afternoon.
--
-- This is the real luacheck. It is NOT an npm dependency and it is not installed
-- by `npm ci`: it is run in CI via apt/luarocks (see .github/workflows/tests.yml),
-- so the repository keeps its zero-runtime-dependency property.
--
-- The globals below are not decoration. luacheck reports every global a file
-- WRITES as a warning, and this library is built as a set of globals by design --
-- `CisRandom = {}` at the top of random.lua, `CisSemver = {}` in semver.lua, and
-- so on for every module. Without this file, `luacheck .` reports one warning per
-- module and the real findings drown in them.

std = "lua54"

-- The FiveM natives this repository calls. Taken from the resource's own usage,
-- not from a copy of a community list, because a list that drifts from the code
-- is worse than no list: it either silences warnings that should fire or
-- invents globals that hide a real typo. `tools/luacheck-natives.js` regenerates
-- this section from the source and CI checks it is current.
read_globals = {
    -- FiveM natives. Grouped by what they are for; the blank lines are the only
    -- documentation this format supports.
    "GetGameTimer", "GetRealTime", "GetCloudTimeAsInt",
    "GetPlayerPed", "GetPlayerFromIndex", "GetPlayers", "GetNumPlayerIndices",
    "GetPlayerName", "GetPlayerServerId", "GetPlayerEndpoint", "GetPlayerGUID",
    "GetEntityCoords", "GetEntityHeading", "GetEntityType", "GetEntityVelocity",
    "GetEntityRotation", "GetGroundZFor_3dCoord", "GetGroundHeightFor_3dCoord",
    "GetOffsetFromEntityInWorldCoords", "GetEntityRotationQuaternion",
    "GetPedBoneIndex", "GetPedSourceVariation", "GetPedTextureVariation",
    "GetVehiclePedIndex", "GetVehicleNumberPlateText", "GetVehicleNumberPlateTextIndex",
    "GetVehicleModelNumber", "GetVehicleType", "GetVehicleDoorLockStatus",
    "GetVehicleColour", "GetVehicleExtra", "GetVehicleExtraIndices",
    "IsPlayerFreeAiming", "IsPedShooting", "IsPedInAnyVehicle", "IsEntityDead",
    "IsPlayerDead", "IsControlPressed", "IsControlJustPressed", "IsControlJustReleased",
    "IsPedOnFoot", "IsPedInCover", "IsPedShootingInCover",
    "GetEntityForwardVector", "GetEntityForwardXAxis", "GetEntityForwardYAxis",
    "SetEntityCoords", "SetEntityCoordsNoOffset", "SetEntityHeading",
    "CreateObject", "CreateProp", "CreateVehicle", "DeleteEntity", "DeleteObject",
    "DeleteVehicle", "DeletePed", "DeleteProps", "DeleteVehicle",
    "FreezeEntityPosition", "SetEntityCollision", "SetEntityInvincible",
    "SetEntityAlpha", "SetEntityVisible", "SetEntityAsMissionEntity",
    "SetVehicleDoorsLocked", "SetVehicleDoorsLockedForAllPlayers",
    "SetVehicleEngineOn", "SetVehicleNumberPlateText", "SetVehicleModsLocked",
    "SetVehicleExtra", "SetVehicleColours", "SetVehicleDoorsLockedForPlayer",
    "SetVehicleTyreSmokeColor", "SetVehicleHeadlightColor",
    "GetVehicleColours", "GetVehicleTyreSmokeColor", "GetVehicleHeadlightColor",
    "SetPedAmmo", "GetPedAmmo", "SetPlayerArmour", "SetPedMoney",
    "GetPlayerPed", "SetEntityRotation", "SetPedToRagdoll",
    "RequestModel", "RequestAnimDict", "SetModelAsNoLongerNeeded",
    "SetAnimDictAsNoLongerNeeded", "HasModelLoaded", "HasAnimDictLoaded",
    "LoadModel", "LoadResourceFile", "GetCurrentResourceName", "GetResourceMetadata",
    "GetInvokingResource", "GetNumResources", "GetResourceByFindIndex",
    "StartResource", "StopResource", "RestartResource",
    "AddEventHandler", "RemoveEventHandler", "RegisterNetEvent",
    "TriggerEvent", "TriggerClientEvent", "TriggerServerEvent",
    "AddCommand", "RemoveCommand", "ExecuteCommand", "RegisterCommand",
    "Wait", "Citizen", "Citizen.Wait", "Citizen.CreateThread", "Citizen.SetTimeout",
    "CreateThread", "SetTimeout", "SetInterval", "ClearTimeout",
    "exports", "load", "loadstring", "dofile", "require",
    "GetEntityFromPed", "NetworkGetEntityIsNetworked", "NetworkGetNetworkIdFromEntity",
    "NetworkGetEntityFromNetworkId", "NetworkGetFirstEntity", "NetworkGetNextEntity",
    "SetNetworkIdExistsOnAllMachines", "SetNetworkIdCanMigrate",
    "NetworkRegisterEntityAsNetworked", "SetEntityAsNetworked",
    "GetPlayerPedIndex", "IsPlayerFreeAimingAtEntity", "IsPlayerFreeAimingAtCoord",
    "DisablePlayerFiring", "GetPedPropIndex", "SetPedPropIndex", "ClearPedProp",
    "SetPedComponent", "GetPedComponent", "ClearPedProp",
    "SetNuiFocus", "SendNuiMessage", "RegisterNUICallback", "TriggerNuiCallback",
    "GetConvar", "GetConvarInt", "GetConvarBool", "Convar",
    "GetPlayerWantedLevel", "SetPlayerWantedLevel", "ClearPlayerWantedLevel",
    "PerformHttpRequest", "PerformHttpRequestAsync",
    "json.encode", "json.decode", "json.null",
    "vector3", "vector2", "vector4", "quaternion", "quaternion", "matrix3",
    "table.pack", "table.unpack", "table.move",
    -- ox_lib / ox_target style helpers a consumer may legitimately use from a
    -- shared_script'd copy. Listed so a shared copy of a module does not emit a
    -- warning for calling the runtime it is part of.
    "oxmysql", "exports.oxmysql",
}

globals = {
    -- THE LIBRARY'S OWN SURFACE. Every module in this repository defines exactly
    -- one `Cis*` global and everything else hangs off it. This block is
    -- deliberately a PATTERN rather than a list: `CisRandom`, `CisWindow`,
    -- `CisValidatete`, `CisInterpq` and anything else someone adds later are all
    -- accepted, so the lint does not become a second thing to update when a module
    -- is renamed. A typo inside a KNOWN name is still caught -- that is what
    -- `unused` is for -- but a typo in the module's own name is not, which is the
    -- trade this makes.
    "Cis.*",

    -- init.lua is a consumer-facing proxy that installs itself onto whatever
    -- global it is shared into. It is the only file allowed to write `Cis`
    -- without `local`.
    "Cis",
}

-- Everything below is a decision, not a default.
--
-- 211 unused: an unused LOCAL is the single most useful finding this tool
-- produces, and it is not a default warning. It is left on deliberately.
unused = true
unused_args = true

-- 212 unused argument. An argument named `_` is exempt, which is how a callback
-- that must match a signature says so without silencing the rule.
unused_secondaries = true

-- 213 unused loop variable, and 214 unused loop control. Same reason.
self = false

-- 111 setting an undefined global. THIS IS THE ONE THAT MATTERS for this
-- repository, and it is why the globals blocks above exist rather than being a
-- blanket suppression. A misspelled native -- `GetEntityCoord` -- or a
-- misspelled module global -- `CisRegstry` -- is a runtime nil-index somewhere
-- else entirely, which is exactly the class of defect this phase exists to catch.
-- A module's own top-level `CisFoo = {}` is covered by the pattern above.
undef = true

-- 4 unused argument / 3 implicitly defined: a bare `local x` shadowing a
-- global is a real bug here, so the shadow check stays on.
shadowing = true

-- 113 accessing an undefined field of a global. The library keeps its internal
-- state in plain tables (`netBindings`, `logBindings`) and reaches into them by
-- key; turning this on would flag every one of those.
field = false

-- 142 setting an undefined field of a global.
mutating = false

-- 143 accessing an undefined field of a non-standard global.
ignore = { "212/_.*" }

-- Files CI parses with a real luacheck. The two client files using FiveM's
-- backtick hash literals (`` `WEAPON_UNARMED` ``) are EXCLUDED rather than
-- tolerated: no standard Lua parser accepts that syntax, so a warning-free run
-- that quietly skipped the rest of the directory would be worse than a failure.
exclude_files = {
    "client/cache.lua",
    "client/weapon.lua",
}

max_line_length = false
codes = true