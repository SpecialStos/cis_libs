-- cis_libs' shape tests: the engine in client/core/raycast.lua, behind two
-- exports. A consumer's `Cis.raycast.*` runs the same text in its own VM.

local Raycast = CisCore.raycast

function CisRaycastCamera(flags, ignore, distance, timeoutMs)
    return Raycast.camera(flags, ignore, distance, timeoutMs)
end

function CisRaycastFromCoords(origin, target, flags, ignore, timeoutMs)
    return Raycast.fromCoords(origin, target, flags, ignore, timeoutMs)
end

exports('RaycastCamera', CisRaycastCamera)
exports('RaycastFromCoords', CisRaycastFromCoords)
