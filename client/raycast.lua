-- Shape-test probes, polled to a result.

local DEFAULT_TIMEOUT_MS = 2000
-- Poll every frame. The probe is asynchronous, the cost is one native call, and
local POLL_MS = 0

-- GetShapeTestResultIncludingMaterial answers 0 while the probe is still running.
local PENDING = 0

-- START_SHAPE_TEST_LOS_PROBE's last argument.
local LOS_OPTIONS = 7

local function isPoint(p)
    -- vector3 is userdata on some runtimes and the type name 'vector3' on others.
    return p ~= nil
        and type(p.x) == 'number' and type(p.y) == 'number' and type(p.z) == 'number'
end

local function positiveMs(value, fallback)
    if type(value) == 'number' and value == value and value > 0 then
        return value
    end
    return fallback
end

-- Read a started probe to a result, or give up at the deadline.
local function read(handle, deadline, timeoutMs)
    while true do
        local state, hit, endCoords, normal, material, entity =
            GetShapeTestResultIncludingMaterial(handle)
        if state ~= PENDING then
            if hit then
                return true, entity, endCoords, normal, material
            end
            -- A miss still has an end point and a normal -- the surface the ray stopped
            return false, nil, endCoords, normal, material
        end
        if GetGameTimer() >= deadline then
            return nil, ('the shape test did not resolve within %dms'):format(timeoutMs)
        end
        Wait(POLL_MS)
    end
end

local function startProbe(x1, y1, z1, x2, y2, z2, flags, ignore)
    -- START_EXPENSIVE_SYNCHRONOUS_SHAPE_TEST_LOS_PROBE (0x377906D8A31E5586).
    return StartExpensiveSynchronousShapeTestLosProbe(
        x1, y1, z1, x2, y2, z2, flags, ignore, LOS_OPTIONS)
end

function CisRaycastCamera(flags, ignore, distance, timeoutMs)
    if flags == nil then flags = -1 end
    if ignore == nil then ignore = 0 end
    distance = distance or 10.0
    if type(distance) ~= 'number' or distance ~= distance or distance <= 0 then
        return nil, ('distance must be a positive finite number, got %s'):format(tostring(distance))
    end
    timeoutMs = positiveMs(timeoutMs, DEFAULT_TIMEOUT_MS)

    -- THE CAMERA'S ROTATION, not the ped's.
    local rot = GetGameplayCamRot(2)
    if not isPoint(rot) then
        return nil, 'the camera has no rotation yet'
    end
    local cam = GetGameplayCamCoord()
    if not isPoint(cam) then
        return nil, 'the camera has no position yet'
    end

    local rx = math.rad(rot.x)
    local rz = math.rad(rot.z)
    local horiz = math.abs(math.cos(rx))
    local dirX = -math.sin(rz) * horiz
    local dirY = math.cos(rz) * horiz
    local dirZ = math.sin(rx)
    local ex = cam.x + dirX * distance
    local ey = cam.y + dirY * distance
    local ez = cam.z + dirZ * distance

    local handle = startProbe(cam.x, cam.y, cam.z, ex, ey, ez, flags, ignore)
    if handle == nil or handle == 0 then
        return nil, 'the engine refused to start a shape test'
    end

    return read(handle, GetGameTimer() + timeoutMs, timeoutMs)
end

function CisRaycastFromCoords(origin, target, flags, ignore, timeoutMs)
    if not isPoint(origin) then
        return nil, 'origin is not a point'
    end
    if not isPoint(target) then
        return nil, 'target is not a point'
    end
    if flags == nil then flags = -1 end
    if ignore == nil then ignore = 0 end
    timeoutMs = positiveMs(timeoutMs, DEFAULT_TIMEOUT_MS)
    local handle = startProbe(
        origin.x, origin.y, origin.z, target.x, target.y, target.z, flags, ignore)
    if handle == nil or handle == 0 then
        return nil, 'the engine refused to start a shape test'
    end
    return read(handle, GetGameTimer() + timeoutMs, timeoutMs)
end

exports('RaycastCamera', CisRaycastCamera)
exports('RaycastFromCoords', CisRaycastFromCoords)
