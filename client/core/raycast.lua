-- The shape-test ENGINE: probes, polled to a result.
--
-- ONE SOURCE, TWO VMS. Pure functions; no state. cis_libs runs this as a
-- client_script behind the RaycastCamera / RaycastFromCoords exports, and a
-- consumer's `Cis.raycast.*` loads the same text into its own VM, so the poll's
-- Wait(0) loop yields the CALLER's thread and nothing crosses per frame.

local M = {}

local DEFAULT_TIMEOUT_MS = 2000
-- Poll every frame. The probe is asynchronous, the cost is one native call, and
local POLL_MS = 0

-- GET_SHAPE_TEST_RESULT(_INCLUDING_MATERIAL)'s status: 0 the handle is invalid
-- (failed), 1 still pending, 2 done. "Loop until returning 0 or 2; unless the
-- return value is 2, the other return values are undefined." This used to treat
-- 0 as pending, so a failed probe was polled to the timeout and a pending one
-- (1) was read as a result.
local FAILED = 0
local PENDING = 1
local DONE = 2

-- START_SHAPE_TEST_LOS_PROBE's last argument.
local LOS_OPTIONS = 7

-- The longest ray: a hundred kilometres, ten times the map. An infinite one put
-- inf (or, at a zero direction component, NaN) into the probe's end point.
local MAX_DISTANCE = 100000

local function finite(v)
    return type(v) == 'number' and v == v and v ~= math.huge and v ~= -math.huge
end

local function isPoint(p)
    -- vector3 is userdata on some runtimes and the type name 'vector3' on others.
    return p ~= nil and finite(p.x) and finite(p.y) and finite(p.z)
end

-- An infinite timeout is no timeout, so it falls back like any other bad value.
local function positiveMs(value, fallback)
    if finite(value) and value > 0 then
        return value
    end
    return fallback
end

-- Read a started probe to a result, or give up at the deadline.
local function read(handle, deadline, timeoutMs)
    while true do
        local state, hit, endCoords, normal, material, entity =
            GetShapeTestResultIncludingMaterial(handle)
        if state == DONE then
            -- `hit` is a BOOL* out-parameter, which CfxLua hands back as the
            -- integer 0 or 1 -- and 0 is TRUTHY in Lua, so `if hit` reported every
            -- miss as a hit. Both spellings are accepted.
            if hit == true or hit == 1 then
                return true, entity, endCoords, normal, material
            end
            -- A miss still has an end point and a normal -- the surface the ray stopped
            return false, nil, endCoords, normal, material
        elseif state == FAILED then
            return nil, 'the shape test failed: the engine no longer knows this handle'
        elseif state ~= PENDING then
            return nil, ('the shape test answered an unknown status %s'):format(tostring(state))
        end
        if GetGameTimer() >= deadline then
            -- %s, not %d: a fractional timeout raised in Lua 5.4.
            return nil, ('the shape test did not resolve within %sms'):format(timeoutMs)
        end
        Wait(POLL_MS)
    end
end

-- THE DEFAULT IGNORE IS THE PLAYER, not 0. A camera ray starts behind the player
-- and, ignoring nothing, its first hit was the player's own ped -- or the vehicle
-- they sit in, which is the entity the ray actually passes through.
local function defaultIgnore()
    local ped = PlayerPedId()
    local vehicle = GetVehiclePedIsIn(ped, false)
    if vehicle and vehicle ~= 0 then
        return vehicle
    end
    return ped
end

local function startProbe(x1, y1, z1, x2, y2, z2, flags, ignore)
    -- START_SHAPE_TEST_LOS_PROBE (0x7EE9F5D83DD4F90E), the ASYNCHRONOUS probe.
    -- The synchronous one blocked the game thread for a result `read` polls for
    -- anyway, and its own native docs say to use this one.
    return StartShapeTestLosProbe(
        x1, y1, z1, x2, y2, z2, flags, ignore, LOS_OPTIONS)
end

function M.camera(flags, ignore, distance, timeoutMs)
    if flags == nil then flags = -1 end
    if ignore == nil then ignore = defaultIgnore() end
    distance = distance or 10.0
    if not finite(distance) or distance <= 0 or distance > MAX_DISTANCE then
        return nil, ('distance must be a positive finite number of at most %d metres, got %s')
            :format(MAX_DISTANCE, tostring(distance))
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

function M.fromCoords(origin, target, flags, ignore, timeoutMs)
    if not isPoint(origin) then
        return nil, 'origin is not a point with finite x/y/z'
    end
    if not isPoint(target) then
        return nil, 'target is not a point with finite x/y/z'
    end
    if flags == nil then flags = -1 end
    if ignore == nil then ignore = defaultIgnore() end
    timeoutMs = positiveMs(timeoutMs, DEFAULT_TIMEOUT_MS)
    local handle = startProbe(
        origin.x, origin.y, origin.z, target.x, target.y, target.z, flags, ignore)
    if handle == nil or handle == 0 then
        return nil, 'the engine refused to start a shape test'
    end
    return read(handle, GetGameTimer() + timeoutMs, timeoutMs)
end

-- A MODULE. Published under CisCore when cis_libs runs it as a client_script.
if ... ~= 'cis_require' then
    CisCore = CisCore or {}
    CisCore.raycast = M
end

return M
