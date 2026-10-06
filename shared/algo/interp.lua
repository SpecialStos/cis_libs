-- Interpolation, easing and FRAME-RATE INDEPENDENT smoothing.

local M = {}

local HALF_PI = math.pi * 0.5
local TAU = math.pi * 2
local DEG = 180.0 / math.pi
local RAD = math.pi / 180.0

-- Easing curves, t in [0,1], f(0)=0 and f(1)=1.
M.EASINGS = {
    linear    = function(t) return t end,

    -- Quadratic / cubic / quartic: the "power" family.
    quadIn    = function(t) return t * t end,
    quadOut   = function(t) return t * (2 - t) end,
    quadInOut = function(t)
        if t < 0.5 then return 2 * t * t end
        return -1 + (4 - 2 * t) * t
    end,

    cubicIn   = function(t) return t * t * t end,
    cubicOut  = function(t)
        local f = t - 1
        return f * f * f + 1
    end,
    cubicInOut = function(t)
        if t < 0.5 then return 4 * t * t * t end
        return 1 - ((-2 * t + 2) ^ 3) * 0.5
    end,

    quartIn   = function(t) return t * t * t * t end,
    quartOut  = function(t)
        local f = 1 - t
        return 1 - f * f * f * f
    end,
    quartInOut = function(t)
        if t < 0.5 then return 8 * t * t * t * t end
        local f = t - 1
        return 1 - 8 * f * f * f * f
    end,

    -- Sine: gentlest possible start, the default for UI that must not feel mechanical
    sineIn    = function(t) return 1 - math.cos(t * HALF_PI) end,
    sineOut   = function(t) return math.sin(t * HALF_PI) end,
    sineInOut = function(t) return 0.5 * (1 - math.cos(t * math.pi)) end,

    -- Exponential: starts (or ends) at a nearly flat tangent.
    expoIn    = function(t)
        if t <= 0 then return 0 end
        return (2) ^ (10 * (t - 1))
    end,
    expoOut   = function(t)
        if t >= 1 then return 1 end
        return 1 - (2) ^ (-10 * t)
    end,
    expoInOut = function(t)
        if t <= 0 then return 0 end
        if t >= 1 then return 1 end
        if t < 0.5 then return 0.5 * (2) ^ (20 * t - 10) end
        return 1 - 0.5 * (2) ^ (-20 * t + 10)
    end,

    -- Circular: same shape as quadratic, steeper.
    circIn    = function(t) return 1 - math.sqrt(1 - t * t) end,
    circOut   = function(t) return math.sqrt(t * (2 - t)) end,
    circInOut = function(t)
        if t < 0.5 then
            return 0.5 * (1 - math.sqrt(1 - 4 * t * t))
        end
        return 0.5 * (math.sqrt(1 - (2 * t - 2) * (2 * t - 2)) + 1)
    end,

    -- Back: overshoots by `overshoot` before settling.
    backIn    = function(t)
        local s = 1.70158
        return t * t * ((s + 1) * t - s)
    end,
    backOut   = function(t)
        local s = 1.70158
        local f = t - 1
        return f * f * ((s + 1) * f + s) + 1
    end,
    backInOut = function(t)
        local s = 1.70158 * 1.525
        if t < 0.5 then
            return 0.5 * (2 * t) ^ 2 * ((s + 1) * 2 * t - s)
        end
        local f = 2 * t - 2
        return 0.5 * (f * f * ((s + 1) * f + s) + 2)
    end,

    -- Elastic: a damped sine. The constants give a period of about 0.3 of the duration,
    elasticIn = function(t)
        if t <= 0 then return 0 end
        if t >= 1 then return 1 end
        return -(2) ^ (10 * (t - 1)) * math.sin((t - 1.1) * 5 * math.pi)
    end,
    elasticOut = function(t)
        if t <= 0 then return 0 end
        if t >= 1 then return 1 end
        return (2) ^ (-10 * t) * math.sin((t - 0.1) * 5 * math.pi) + 1
    end,
    elasticInOut = function(t)
        if t <= 0 then return 0 end
        if t >= 1 then return 1 end
        t = t * 2
        if t < 1 then
            return -0.5 * (2) ^ (10 * (t - 1)) * math.sin((t - 1.1) * 5 * math.pi)
        end
        t = t - 1
        return (2) ^ (-10 * t) * math.sin((t - 0.1) * 5 * math.pi) * 0.5 + 1
    end,

    -- Bounce: piecewise parabolic arcs.
    bounceOut = function(t)
        if t < 1 / 2.75 then
            return 7.5625 * t * t
        elseif t < 2 / 2.75 then
            t = t - 1.5 / 2.75
            return 7.5625 * t * t + 0.75
        elseif t < 2.5 / 2.75 then
            t = t - 2.25 / 2.75
            return 7.5625 * t * t + 0.9375
        end
        t = t - 2.625 / 2.75
        return 7.5625 * t * t + 0.984375
    end,
}

-- bounceIn and bounceInOut are derived rather than written out, so there is one copy of
M.EASINGS.bounceIn = function(t)
    return 1 - M.EASINGS.bounceOut(1 - t)
end

M.EASINGS.bounceInOut = function(t)
    if t < 0.5 then
        return 0.5 * (1 - M.EASINGS.bounceOut(1 - 2 * t))
    end
    return 0.5 * M.EASINGS.bounceOut(2 * t - 1) + 0.5
end

function M.hasEase(name)
    return type(name) == 'string' and M.EASINGS[name] ~= nil
end

function M.ease(name, t)
    local curve = M.EASINGS[name]
    if not curve then
        return t
    end
    return curve(t)
end


function M.clamp(v, lo, hi)
    if type(v) ~= 'number' then
        error(('CisInterp.clamp: v must be a number, got %s'):format(type(v)), 2)
    end
    if type(lo) ~= 'number' or type(hi) ~= 'number' then
        error(('CisInterp.clamp: lo and hi must be numbers, got %s and %s')
            :format(type(lo), type(hi)), 2)
    end
    if v ~= v then
        return nil, 'CisInterp.clamp: v is NaN, which cannot be clamped'
    end
    -- An infinite VALUE still clamps: inf > hi, so it lands on hi, and that is the
    if lo > hi then
        return nil, ('CisInterp.clamp: lo %s is greater than hi %s')
            :format(tostring(lo), tostring(hi))
    end
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

function M.clamp01(v)
    if v < 0 then return 0 end
    if v > 1 then return 1 end
    return v
end

function M.sign(v)
    if v > 0 then return 1 end
    if v < 0 then return -1 end
    return 0
end

function M.lerp(a, b, t)
    return a + (b - a) * t
end

function M.lerpClamped(a, b, t)
    return a + (b - a) * M.clamp01(t)
end

function M.inverseLerp(a, b, v)
    if a == b then
        return 0
    end
    return (v - a) / (b - a)
end

function M.remap(v, inMin, inMax, outMin, outMax, clamped)
    if inMin == inMax then
        return outMin
    end
    local t = (v - inMin) / (inMax - inMin)
    if clamped then
        t = M.clamp01(t)
    end
    return outMin + (outMax - outMin) * t
end

function M.wrap(v, min, max)
    local range = max - min
    if range <= 0 then
        return min
    end
    return min + ((v - min) % range + range) % range
end

function M.smoothstep(edge0, edge1, x)
    if edge0 == edge1 then
        return x < edge0 and 0 or 1
    end
    local t = M.clamp01((x - edge0) / (edge1 - edge0))
    return t * t * (3 - 2 * t)
end

function M.smootherstep(edge0, edge1, x)
    if edge0 == edge1 then
        return x < edge0 and 0 or 1
    end
    local t = M.clamp01((x - edge0) / (edge1 - edge0))
    return t * t * t * (t * (t * 6 - 15) + 10)
end

function M.moveTowards(current, target, maxDelta)
    if maxDelta < 0 then
        maxDelta = 0
    end
    local d = target - current
    if d > maxDelta then
        return current + maxDelta
    elseif d < -maxDelta then
        return current - maxDelta
    end
    return target
end

function M.damp(current, target, smoothTime, dt)
    if dt <= 0 then
        return current
    end
    if smoothTime <= 0 then
        return target
    end
    -- NaN guard. A single NaN entering this function poisons every later call, because
    if current ~= current then
        return target
    end
    return target + (current - target) * math.exp(-dt / smoothTime)
end

function M.dampAngle(current, target, smoothTime, dt)
    local delta = M.wrapAngle(target - current)
    return M.wrapAngle(current + M.damp(0, delta, smoothTime, dt))
end

function M.smoothDamp(current, target, velocity, smoothTime, maxSpeed, dt)
    velocity = velocity or 0
    if dt <= 0 then
        return current, velocity
    end
    if smoothTime <= 0 then
        return target, 0
    end
    if current ~= current or target ~= target then
        return target, 0
    end

    local omega = 2 / smoothTime
    local x = omega * dt
    -- The decay term, approximated by its reciprocal series.
    local expo = 1 / (1 + x + 0.48 * x * x + 0.235 * x * x * x)

    local originalTarget = target
    local change = current - target
    local maxChange = (maxSpeed or math.huge) * smoothTime
    change = M.clamp(change, -maxChange, maxChange)
    target = current - change

    local temp = (velocity + omega * change) * dt
    local newVelocity = (velocity - omega * temp) * expo
    local output = target + (change + temp) * expo

    -- Terminal condition. On the frame the value reaches the target the remaining
    if (originalTarget - current > 0) == (output > originalTarget) then
        output = originalTarget
        newVelocity = 0
    end

    return output, newVelocity
end


function M.wrapAngle(rad)
    return M.wrap(rad, -math.pi, math.pi)
end

function M.wrapAnglePositive(rad)
    return M.wrap(rad, 0, TAU)
end

function M.wrapDegrees(deg)
    return M.wrap(deg, 0, 360)
end

function M.angleDelta(a, b)
    return M.wrapAngle(b - a)
end

function M.headingDelta(a, b)
    return M.wrapDegrees(b - a)
end

function M.lerpHeading(a, b, t)
    return M.wrapDegrees(a + M.headingDelta(a, b) * t)
end

function M.headingToVector(headingDeg)
    local rad = headingDeg * RAD
    return math.sin(rad), -math.cos(rad)
end

function M.vectorToHeading(x, y)
    if x == 0 and y == 0 then
        return 0
    end
    return M.wrapDegrees(math.atan(x, -y) * DEG)
end


-- Read a point that may be keyed or positional.
local function xyz(p)
    if type(p) ~= 'table' then
        return nil, nil, nil
    end
    local x, y, z = p.x, p.y, p.z
    if x == nil then
        x, y, z = p[1], p[2], p[3]
    end
    if type(x) ~= 'number' or type(y) ~= 'number' then
        return nil, nil, nil
    end
    return x, y, z
end

function M.dist2(ax, ay, bx, by)
    local dx, dy = bx - ax, by - ay
    return math.sqrt(dx * dx + dy * dy)
end

function M.dist3(ax, ay, az, bx, by, bz)
    local dx, dy, dz = bx - ax, by - ay, (bz or 0) - (az or 0)
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

function M.distance2D(a, b)
    local ax, ay = xyz(a)
    local bx, by = xyz(b)
    if not ax then return 0 end
    if not bx then return 0 end
    return M.dist2(ax, ay, bx, by)
end

function M.distance3D(a, b)
    local ax, ay, az = xyz(a)
    local bx, by, bz = xyz(b)
    if not ax then return 0 end
    if not bx then return 0 end
    return M.dist3(ax, ay, az, bx, by, bz)
end

function M.moveTowardsVec3(current, target, maxDelta)
    local cx, cy, cz = xyz(current)
    local tx, ty, tz = xyz(target)
    if not cx then return { x = 0, y = 0, z = 0 } end
    if not tx or cz == nil then return { x = cx, y = cy, z = cz or 0 } end
    if tz == nil then tz = cz end
    if maxDelta < 0 then
        maxDelta = 0
    end
    local dx, dy, dz = tx - cx, ty - cy, tz - cz
    local d = math.sqrt(dx * dx + dy * dy + dz * dz)
    if d <= maxDelta then
        return { x = tx, y = ty, z = tz }
    end
    local f = maxDelta / d
    return { x = cx + dx * f, y = cy + dy * f, z = cz + dz * f }
end

function M.lerpVec3(a, b, t, out)
    local ax, ay, az = xyz(a)
    local bx, by, bz = xyz(b)
    if not ax or not bx then
        out = out or {}
        out.x, out.y, out.z = 0, 0, 0
        return out
    end
    -- A point with no z takes the other end's z, so blending a native vec3 against a
    if az == nil then az = bz end
    if bz == nil then bz = az end
    if az == nil then az = 0 end
    if bz == nil then bz = 0 end
    out = out or {}
    out.x = ax + (bx - ax) * t
    out.y = ay + (by - ay) * t
    out.z = az + (bz - az) * t
    return out
end

function M.dampVec3(current, target, smoothTime, dt, out)
    local cx, cy, cz = xyz(current)
    local tx, ty, tz = xyz(target)
    if not cx then
        out = out or {}
        out.x, out.y, out.z = 0, 0, 0
        return out
    end
    if not tx then
        out = out or {}
        out.x, out.y, out.z = cx, cy, cz or 0
        return out
    end
    if cz == nil then cz = tz end
    if tz == nil then tz = cz end
    if cz == nil then cz = 0 end
    if tz == nil then tz = 0 end
    out = out or {}
    out.x = M.damp(cx, tx, smoothTime, dt)
    out.y = M.damp(cy, ty, smoothTime, dt)
    out.z = M.damp(cz, tz, smoothTime, dt)
    return out
end

function M.clampLength(v, maxLength, out)
    local x, y, z = xyz(v)
    if not x then
        out = out or {}
        out.x, out.y, out.z = 0, 0, 0
        return out
    end
    z = z or 0
    out = out or {}
    local lenSq = x * x + y * y + z * z
    if lenSq > maxLength * maxLength and lenSq > 0 then
        local f = maxLength / math.sqrt(lenSq)
        x, y, z = x * f, y * f, z * f
    end
    out.x, out.y, out.z = x, y, z
    return out
end

function M.normalize(v, out)
    local x, y, z = xyz(v)
    out = out or {}
    if not x then
        out.x, out.y, out.z = 0, 0, 0
        return out
    end
    z = z or 0
    local len = math.sqrt(x * x + y * y + z * z)
    if len > 0 then
        x, y, z = x / len, y / len, z / len
    end
    out.x, out.y, out.z = x, y, z
    return out
end

-- A MODULE, NOT A GLOBAL.
if ... ~= 'cis_require' then
    CisInterp = M
end

return M
