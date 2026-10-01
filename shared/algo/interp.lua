-- Interpolation, easing and FRAME-RATE INDEPENDENT smoothing.
--
-- PURE. No natives, no GetFrameTime, no state: every time-varying function
-- takes `dt` (or `now`) as an argument, which is what makes the whole file
-- testable under fengari with no game running -- a smoothing function you can
-- only exercise by owning a ped is a smoothing function that is never exercised.
--
-- WHY THIS FILE IS MOSTLY ABOUT dt
--
-- The one thing every FiveM resource gets wrong is frame-rate dependence. The
-- naive smoothing is
--
--     value = value + (target - value) * 0.1
--
-- applied once per frame. That factor of 0.1 is "10% of the way per FRAME", so
-- the result depends on the frame rate: at 30fps it converges roughly twice as
-- fast in wall-clock time as at 60fps, and a player on a 5fps stream sees a
-- camera swing while a player at 144fps sees a snap. Any such factor must be
-- divided by dt, and dividing by dt blows up when dt is tiny (a hitch makes
-- value/tiny -> infinity) and stalls when dt is huge.
--
-- The fix used here is exponential decay with a closed-form step:
--
--     value = target + (current - target) * exp(-dt / smoothTime)
--
-- which is the exact solution of dV/dt = (target - V)/smoothTime over one
-- frame. There is no per-frame constant anywhere, so the trajectory is
-- identical at 15, 60 or 240 fps, and a dt of 0 (a paused frame) is free rather
-- than a divide-by-zero. That property is the entire reason this function
-- exists and it is why it is preferred over lerp-toward-target in every place
-- below.
--
-- A second smoother, `smoothDamp`, is provided as well: exponential decay
-- reaches 95% of the way in about 3*smoothTime but has no velocity, so a value
-- that overshoots its target and comes back (a camera pushed past a wall) is
-- not expressible. A critically damped spring gives a velocity for free and
-- provably never overshoots. The cost is that its state is a velocity, not a
-- scalar, so the caller has to carry two numbers. Use damp() for scalars you
-- only need the value of; use smoothDamp() when the motion needs to be
-- physical (camera, doors, physics props).
--
-- ANGLE CONVENTION
--
-- Two systems, both used in this repo:
--   * radians in [-pi, pi) for internal maths (`wrapAngle`),
--   * GTA headings in degrees [0, 360) for natives (`wrapDegrees`).
-- Mixing them is the single most common source of "the door spins the wrong
-- way". `wrap` is the one primitive both are built on and it handles negative
-- inputs correctly, which `(v - min) % range` gets wrong in Lua: `%` is fmod,
-- so a negative input returns a negative remainder.
--
-- VECTOR3 CONVENTION
--
-- A point is `{x=,y=,z=}` or `{1,2,3}` -- both are accepted on input, matching
-- shared/grid.lua, because a caller should not have to convert a native vec3
-- before doing arithmetic on it. Output is always a fresh `{x=,y=,z=}`, or
-- written into a caller-supplied `out` table to keep a per-frame loop from
-- generating garbage. At 512 entities and 60fps that is 30k tables a second,
-- and a GC pause during a firefight is a stutter.

CisInterp = {}

local HALF_PI = math.pi * 0.5
local TAU = math.pi * 2
local DEG = 180.0 / math.pi
local RAD = math.pi / 180.0

-- Easing curves, t in [0,1], f(0)=0 and f(1)=1.
--
-- The classic Penner set. `linear` is included as a named curve rather than
-- left implicit so that a config value of "linear" is a valid choice rather
-- than a name that silently does nothing.
--
-- Deliberately NOT here: spring easings driven by a stiffness/damping pair.
-- Those are a function of elapsed time, not of t, and mixing them into a
-- t-parameterised table is how you get an animation that runs at a different
-- speed depending on which menu opened it. `smoothDamp` is the honest way to
-- get spring behaviour.
CisInterp.EASINGS = {
    linear    = function(t) return t end,

    -- Quadratic / cubic / quartic: the "power" family. Cheap, no branch.
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

    -- Sine: gentlest possible start, the default for UI that must not feel
    -- mechanical (a bar filling, a panel sliding).
    sineIn    = function(t) return 1 - math.cos(t * HALF_PI) end,
    sineOut   = function(t) return math.sin(t * HALF_PI) end,
    sineInOut = function(t) return 0.5 * (1 - math.cos(t * math.pi)) end,

    -- Exponential: starts (or ends) at a nearly flat tangent. Reach for this
    -- for anything that should feel mechanical or snappy.
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

    -- Back: overshoots by `overshoot` before settling. This is the ONE curve
    -- here that is not monotonic, and it is deliberate -- a button that
    -- overshoots reads as physical. Keep it small; a large one looks broken.
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

    -- Elastic: a damped sine. The constants give a period of about 0.3 of the
    -- duration, which is the only one that reads as "bounce" rather than
    -- "wobble".
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

    -- Bounce: piecewise parabolic arcs. The only curve with no closed form,
    -- and the only one that looks like a physical ball.
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

-- bounceIn and bounceInOut are derived rather than written out, so there is one
-- copy of the parabolic constants to get right.
CisInterp.EASINGS.bounceIn = function(t)
    return 1 - CisInterp.EASINGS.bounceOut(1 - t)
end

CisInterp.EASINGS.bounceInOut = function(t)
    if t < 0.5 then
        return 0.5 * (1 - CisInterp.EASINGS.bounceOut(1 - 2 * t))
    end
    return 0.5 * CisInterp.EASINGS.bounceOut(2 * t - 1) + 0.5
end

--- Does `name` exist in the easing table? Use it to validate a config value at
--- load time rather than discovering a typo when a door does not animate.
---@param name
--- @return boolean
function CisInterp.hasEase(name)
    return type(name) == 'string' and CisInterp.EASINGS[name] ~= nil
end

--- Evaluate a named easing curve.
--- @param name string   key into CisInterp.EASINGS
--- @param t number     progress, NOT clamped: values outside 0..1 extrapolate,
---                      which is what a curve that is driven past its end needs
--- @return number  f(t)
---
--- An unknown name returns `t` itself, i.e. linear. A missing config key should
--- produce a menu that animates slightly wrong, not a client that stops
--- rendering; call hasEase() at load time if you would rather fail loudly.
function CisInterp.ease(name, t)
    local curve = CisInterp.EASINGS[name]
    if not curve then
        return t
    end
    return curve(t)
end

-- ---------------------------------------------------------------- scalars

--- Constrain `v` to [lo, hi]. A reversed range (lo > hi) returns hi rather than
--- erroring, because the caller got the arguments the wrong way round and
--- returning something usable beats a stack trace in a render loop.
---@param v
---@param lo
---@param hi
--- @return number
--- Constrain `v` to [lo, hi].
---
--- INFINITE BOUNDS ARE LEGAL AND MEANINGFUL: smoothDamp calls this as
--- `clamp(change, -maxChange, maxChange)` with `maxChange = (maxSpeed or
--- math.huge) * smoothTime`, so "no speed limit" arrives here as two infinite
--- bounds. Refusing infinities would break the most common calling pattern in
--- this module, so the NaN check below is on `v` ONLY.
---
--- A NaN `v` is the actual bug: every comparison against NaN is false, so it
--- fell through all three branches and came back out as NaN, three subsystems
--- later, as a coordinate. It returns nil and a reason instead.
---
--- @return number
--- @return number|nil,string  `nil, reason` for a NaN value or an inverted range
--- @raise  when any argument is not a number
function CisInterp.clamp(v, lo, hi)
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
    -- An infinite VALUE still clamps: inf > hi, so it lands on hi, and that is
    -- the correct answer rather than an error.
    if lo > hi then
        return nil, ('CisInterp.clamp: lo %s is greater than hi %s')
            :format(tostring(lo), tostring(hi))
    end
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

--- Constrain `v` to [0, 1].
---@param v
--- @return number
function CisInterp.clamp01(v)
    if v < 0 then return 0 end
    if v > 1 then return 1 end
    return v
end

--- -1, 0 or 1 by sign. Returns 0 for 0 rather than raising.
---@param v
--- @return number
function CisInterp.sign(v)
    if v > 0 then return 1 end
    if v < 0 then return -1 end
    return 0
end

--- Linear interpolation. t is NOT clamped: t > 1 extrapolates past `b`, which
--- is exactly what an ease that overshoots needs. Use `lerpClamped` when you
--- want a hard 0..1 result.
---
--- Written `a + (b - a) * t` rather than `a * (1 - t) + b * t` because the
--- first form is exact at t = 0 and t = 1 -- it returns `a` and `b` bit for bit
--- -- and does not lose precision when a and b are large and close, which they
--- are for world coordinates in the tens of thousands.
---@param a
---@param b
---@param t
--- @return number
function CisInterp.lerp(a, b, t)
    return a + (b - a) * t
end

--- lerp with t clamped to [0, 1].
---@param a
---@param b
---@param t
--- @return number
function CisInterp.lerpClamped(a, b, t)
    return a + (b - a) * CisInterp.clamp01(t)
end

--- Where `v` sits between `a` and `b`, as a fraction. Returns 0 for a == b
--- rather than 0/0: a zero-length range has no meaningful position and 0 is
--- the safe answer for the callers that multiply the result by a length.
---@param a
---@param b
---@param v
--- @return number
function CisInterp.inverseLerp(a, b, v)
    if a == b then
        return 0
    end
    return (v - a) / (b - a)
end

--- Map `v` from one range to another.
--- @param clamped boolean|nil when true, the input is clamped to the input
---        range first; when false or nil, values outside the range extrapolate
---@param v
---@param inMin
---@param inMax
---@param outMin
---@param outMax
--- @return number
function CisInterp.remap(v, inMin, inMax, outMin, outMax, clamped)
    if inMin == inMax then
        return outMin
    end
    local t = (v - inMin) / (inMax - inMin)
    if clamped then
        t = CisInterp.clamp01(t)
    end
    return outMin + (outMax - outMin) * t
end

--- Wrap `v` into [min, max), including for negative `v`.
---
--- `(v - min) % (max - min)` alone is wrong for negatives in Lua: `%` is fmod,
--- so -1 %% 4 is -1, not 3. Adding min back after a double wrap fixes it, and
--- is why this is a function and not a one-liner in every call site.
--- A zero or negative range returns `min`.
---@param v
---@param min
---@param max
--- @return number
function CisInterp.wrap(v, min, max)
    local range = max - min
    if range <= 0 then
        return min
    end
    return min + ((v - min) % range + range) % range
end

--- Hermite smoothstep between two edges. t is 0 below edge0, 1 above edge1,
--- and eased in between (zero first AND second derivative at both ends, so a
--- value crossing an edge does not visibly kink). Reversed edges are handled:
--- a > b still returns 0 for v == a.
---@param edge0
---@param edge1
---@param x
--- @return number
function CisInterp.smoothstep(edge0, edge1, x)
    if edge0 == edge1 then
        return x < edge0 and 0 or 1
    end
    local t = CisInterp.clamp01((x - edge0) / (edge1 - edge0))
    return t * t * (3 - 2 * t)
end

--- Quintic smootherstep. Second derivative is zero at the edges too, and so is
--- the third -- the curve is C2 continuous across the edges, which is what you
--- want when a value can cross an edge repeatedly (a falloff that is C1 has a
--- visible change of acceleration at the boundary when driven by a moving
--- entity). Use smoothstep unless you have a specific reason.
---@param edge0
---@param edge1
---@param x
--- @return number
function CisInterp.smootherstep(edge0, edge1, x)
    if edge0 == edge1 then
        return x < edge0 and 0 or 1
    end
    local t = CisInterp.clamp01((x - edge0) / (edge1 - edge0))
    return t * t * t * (t * (t * 6 - 15) + 10)
end

--- Move `current` toward `target` by at most `maxDelta`.
---
--- This is the frame-rate INDEPENDENT one, and it is here for the specific case
--- where a constant speed in units-per-second is the requirement: doors, train
--- speeds, a progress bar. The cap is a SPEED, not a fraction of the gap, so
--- the result does not depend on the frame rate -- but it eases nothing.
---
--- A negative maxDelta is treated as 0, i.e. "do not move". Without that, a
--- negated cap moves the value AWAY from its target, which is never what a
--- caller means and is a very confusing thing to debug.
---@param current
---@param target
---@param maxDelta
--- @return number
function CisInterp.moveTowards(current, target, maxDelta)
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

--- Frame-rate independent exponential smoothing. See the header for why this
--- is not `value + (target - value) * k`.
---
--- @param current number
--- @param target  number
--- @param smoothTime number  seconds to close ~63% of the gap. Larger is
---        slower. 0 or less snaps to target immediately.
--- @param dt      number  seconds since the last call. 0 or less returns
---        `current` unchanged.
--- @return number
function CisInterp.damp(current, target, smoothTime, dt)
    if dt <= 0 then
        return current
    end
    if smoothTime <= 0 then
        return target
    end
    -- NaN guard. A single NaN entering this function poisons every later call,
    -- because the next target is a function of the last one; returning the
    -- target re-syncs instead of propagating the poison forever.
    if current ~= current then
        return target
    end
    return target + (current - target) * math.exp(-dt / smoothTime)
end

--- damp() around a circle: takes the short way round. `damp` from 170 to -170
--- would travel 340 degrees; this travels 20.
---@param current
---@param target
---@param smoothTime
---@param dt
--- @return number radians in [-pi, pi)
function CisInterp.dampAngle(current, target, smoothTime, dt)
    local delta = CisInterp.wrapAngle(target - current)
    return CisInterp.wrapAngle(current + CisInterp.damp(0, delta, smoothTime, dt))
end

--- Critically damped spring smoothing, with a velocity.
---
--- A spring, not an exponential: a spring can be pushed past its target and
--- comes back, and it settles in a predictable time no matter how it was
--- disturbed. Critically damped specifically means the damping is exactly large
--- enough that it returns without overshooting -- zeta = 1, the fastest return
--- that does not ring. (Under-damped rings, which looks great on a UI and looks
--- broken on a door; over-damped is sluggish.)
---
--- The closed-form step below is the standard SmoothDamp formulation, from
--- Patrick O'Shaughnessy's "Critically Damped Ease-In/Ease-Out Behavior"
--- (Game Programming Gems 4, 1.2) in the form Unity popularised. It is a
--- numerical approximation of the analytic solution chosen because it is
--- unconditionally stable for any dt -- a naive spring integrator explodes when
--- dt * omega > 2, which happens on the first frame after a hitch.
---
---@param current
---@param target
---@param velocity
---@param smoothTime
---@param maxSpeed
---@param dt
--- @return number value    the new value
--- @return number velocity the new velocity, in units per second -- PASS THIS
---         BACK IN on the next call or the spring has no memory and behaves
---         exactly like damp()
function CisInterp.smoothDamp(current, target, velocity, smoothTime, maxSpeed, dt)
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
    -- The decay term, approximated by its reciprocal series. exp(-x) for large
    -- x underflows to 0 and the reciprocal would be infinity; this form stays
    -- finite and accurate across the whole range.
    local expo = 1 / (1 + x + 0.48 * x * x + 0.235 * x * x * x)

    local originalTarget = target
    local change = current - target
    local maxChange = (maxSpeed or math.huge) * smoothTime
    change = CisInterp.clamp(change, -maxChange, maxChange)
    target = current - change

    local temp = (velocity + omega * change) * dt
    local newVelocity = (velocity - omega * temp) * expo
    local output = target + (change + temp) * expo

    -- Terminal condition. On the frame the value reaches the target the
    -- remaining velocity must be discarded, or the value sails past and the
    -- "critically damped, never overshoots" property is lost to rounding.
    if (originalTarget - current > 0) == (output > originalTarget) then
        output = originalTarget
        newVelocity = 0
    end

    return output, newVelocity
end

-- ---------------------------------------------------------------- angles

--- Wrap radians into [-pi, pi). The interval is half-open on the left: -pi and
--- pi are the same direction and this returns -pi for both.
---@param rad
--- @return number
function CisInterp.wrapAngle(rad)
    return CisInterp.wrap(rad, -math.pi, math.pi)
end

--- Wrap radians into [0, 2*pi).
---@param rad
--- @return number
function CisInterp.wrapAnglePositive(rad)
    return CisInterp.wrap(rad, 0, TAU)
end

--- Wrap degrees into [0, 360). This is the GTA heading convention and the one
--- SetEntityHeading and GetEntityHeading speak.
---@param deg
--- @return number
function CisInterp.wrapDegrees(deg)
    return CisInterp.wrap(deg, 0, 360)
end

--- Signed shortest rotation from `a` to `b`, in radians, in [-pi, pi).
--- Positive means counter-clockwise in maths terms, which is CLOCKWISE on a
--- GTA map (y is inverted). Read it as "which way and how far", not "which
--- compass direction".
---@param a
---@param b
--- @return number
function CisInterp.angleDelta(a, b)
    return CisInterp.wrapAngle(b - a)
end

--- Signed shortest rotation from heading `a` to heading `b`, in degrees.
--- Use this for anything that goes into or comes out of a heading native.
---@param a
---@param b
--- @return number
function CisInterp.headingDelta(a, b)
    return CisInterp.wrapDegrees(b - a)
end

--- Interpolate a heading the short way round. t is not clamped, so t > 1
--- overshoots past `b`, which is what a spin does.
---@param a
---@param b
---@param t
--- @return number degrees, in [0, 360)
function CisInterp.lerpHeading(a, b, t)
    return CisInterp.wrapDegrees(a + CisInterp.headingDelta(a, b) * t)
end

--- Unit forward vector for a GTA heading, written as (x, y).
---
--- GTA's heading is a compass bearing: 0 is north, 90 is east, and it increases
--- clockwise. North is -Z, so the vector is (sin, -cos) and NOT (cos, sin).
--- Getting this backwards produces a vehicle that turns the opposite way from
--- the way the driver is steering, which is a genuinely hard bug to see.
---
---@param headingDeg
--- @return number, number  x, y
function CisInterp.headingToVector(headingDeg)
    local rad = headingDeg * RAD
    return math.sin(rad), -math.cos(rad)
end

--- The heading a unit vector points at, in degrees [0, 360). Inverse of
--- headingToVector for any (x, y); the zero vector has no heading, so it returns
--- 0 rather than NaN.
---
--- Uses the two-argument math.atan rather than math.atan2. atan2 was deprecated
--- in Lua 5.1 and REMOVED in 5.3, so a file that calls it parses everywhere and
--- runs nowhere this repository actually runs; the two-argument form is the
--- portable spelling and is present in LuaJIT, 5.3 and 5.4 alike.
---@param x
---@param y
--- @return number
function CisInterp.vectorToHeading(x, y)
    if x == 0 and y == 0 then
        return 0
    end
    return CisInterp.wrapDegrees(math.atan(x, -y) * DEG)
end

-- ---------------------------------------------------------------- vector3

-- Read a point that may be keyed or positional. Returns nil, nil, nil for
-- anything that is not a usable point, so a caller can test the first result
-- once instead of guarding every component. z is returned as-is, INCLUDING nil
-- -- a point with no z is not a point at z=0, and the lerp below needs to tell
-- the difference so it can take z from the other end.
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

--- Horizontal distance between two points. z is ignored on purpose: almost
--- every "how far is that player" question in this repo is about the ground
--- plane, and a player on a roof should still be 3m away, not 30m.
---@param ax
---@param ay
---@param bx
---@param by
--- @return number
function CisInterp.dist2(ax, ay, bx, by)
    local dx, dy = bx - ax, by - ay
    return math.sqrt(dx * dx + dy * dy)
end

--- Full 3D distance between two points.
---@param ax
---@param ay
---@param az
---@param bx
---@param by
---@param bz
--- @return number
function CisInterp.dist3(ax, ay, az, bx, by, bz)
    local dx, dy, dz = bx - ax, by - ay, (bz or 0) - (az or 0)
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

--- Horizontal distance between two point tables.
---@param a
---@param b
--- @return number  0 when either point is not a usable table
function CisInterp.distance2D(a, b)
    local ax, ay = xyz(a)
    local bx, by = xyz(b)
    if not ax then return 0 end
    if not bx then return 0 end
    return CisInterp.dist2(ax, ay, bx, by)
end

--- Full distance between two point tables.
---@param a
---@param b
--- @return number  0 when either point is not a usable table
function CisInterp.distance3D(a, b)
    local ax, ay, az = xyz(a)
    local bx, by, bz = xyz(b)
    if not ax then return 0 end
    if not bx then return 0 end
    return CisInterp.dist3(ax, ay, az, bx, by, bz)
end

--- Move a point toward a target by at most `maxDelta` METRES. Constant speed,
--- frame-rate independent because the cap is a distance per second, not a
--- fraction of the gap. A negative maxDelta is treated as 0 (stay put).
---@param current
---@param target
---@param maxDelta
--- @return table  { x, y, z }
function CisInterp.moveTowardsVec3(current, target, maxDelta)
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

--- Interpolate two points. t is not clamped. A component that is missing on
--- EITHER input is taken from the other rather than treated as 0 -- blending a
--- real x with a 0 z would drop the point to the floor.
--- @param out table|nil  optional table to write into instead of allocating
---@param a
---@param b
---@param t
--- @return table  { x, y, z }; a zero vector if either input is unusable
function CisInterp.lerpVec3(a, b, t, out)
    local ax, ay, az = xyz(a)
    local bx, by, bz = xyz(b)
    if not ax or not bx then
        out = out or {}
        out.x, out.y, out.z = 0, 0, 0
        return out
    end
    -- A point with no z takes the other end's z, so blending a native vec3
    -- against a hand-built {x,y} does not drop it to the floor.
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

--- Frame-rate independent smoothing of a point, per axis. See the header.
--- @param out table|nil
---@param current
---@param target
---@param smoothTime
---@param dt
--- @return table  { x, y, z }
function CisInterp.dampVec3(current, target, smoothTime, dt, out)
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
    out.x = CisInterp.damp(cx, tx, smoothTime, dt)
    out.y = CisInterp.damp(cy, ty, smoothTime, dt)
    out.z = CisInterp.damp(cz, tz, smoothTime, dt)
    return out
end

--- Shorten or lengthen a point's offset from the ORIGIN to `maxLength`. This is
--- for direction vectors (speed, aim, impulse), not for world positions -- a
--- point at (900, 900, 20) clamped to length 2 is a point near the origin, not
--- a clamped direction.
---
--- A zero-length vector is returned unchanged rather than divided by zero.
---@param v
---@param maxLength
---@param out
--- @return table  { x, y, z }
function CisInterp.clampLength(v, maxLength, out)
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

--- Unit-length copy of a direction vector. The zero vector is returned as the
--- zero vector: there is no direction, and pretending otherwise produces NaN
--- that then spreads through a particle system.
---@param v
---@param out
--- @return table  { x, y, z }
function CisInterp.normalize(v, out)
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
