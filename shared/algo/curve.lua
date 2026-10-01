-- Catmull-Rom / cubic Hermite splines and arc-length parameterised paths.
--
-- PURE. No natives, no state. A path is an immutable value: build it once from
-- a list of points, then query it as many times as a frame needs.
--
-- WHY A PATH OBJECT AND NOT JUST A catmullRom() FUNCTION
--
-- Evaluating a spline is trivial. The thing that actually breaks a spline in a
-- game is that the parameter t is NOT proportional to distance. A Catmull-Rom
-- segment spends very different amounts of t crossing a long chord than a
-- short one, so walking a path at a constant t-step makes a vehicle accelerate
-- through the short segments and crawl through the long ones. Every spline
-- driven by "t += speed * dt" looks wrong in exactly this way, and the usual
-- fix -- hand-tune the waypoints -- is a fix that has to be redone for every
-- route.
--
-- The real fix is to re-parameterise by ARC LENGTH: build a lookup of
-- cumulative chord length once, then ask for "the point at 30 metres along",
-- not "the point at t = 0.3". A caller then moves at a genuine constant speed
-- and the only thing it has to supply is a distance. That is why this file
-- builds a path object instead of exposing only a segment function.
--
-- The lookup is built by SAMPLING, not by solving the arc-length integral. A
-- spline has no closed-form arc length; the integral is a cubic root solved per
-- query, which is slow and which still has to be inverted. Sampling each
-- segment at `samples` points and accumulating chord distance costs O(segments
-- * samples) ONCE and is then a binary search -- O(log n) per query, with an
-- accuracy that is set by the sampling density rather than by floating point.
-- For route data that is not a compromise; it is the right trade.
--
-- WHY CENTRIPETAL, NOT UNIFORM
--
-- The uniform Catmull-Rom tangents assume the control points are evenly
-- spaced. Waypoints from GetGroundZFor_3dCoord, mission markers and hand-placed
-- door routes are never evenly spaced, and with uneven spacing the uniform form
-- OVERSHOOTS -- it produces cusps and loops through a sharp corner. The
-- centripetal form (alpha = 0.5, knot spacing proportional to the square root
-- of the chord length) provably cannot form a cusp or a self-intersection. It
-- is the default here for that reason. alpha = 0 recovers the uniform form,
-- which is what you want for evenly spaced animation keyframes.
--
-- The same trick is why the tangent code below has a degenerate-input branch
-- instead of clamping a distance to some epsilon. A duplicated waypoint gives
-- a zero-length knot interval, and clamping it to 1e-9 makes the tangent
-- formula collapse to zero -- a route that visibly stops dead at the duplicate.
-- Handling the zero interval exactly, by falling back to the full chord, keeps
-- a 2-point path a straight line and a path with a repeated waypoint smooth.

CisCurve = {}

local DEFAULT_ALPHA = 0.5
local DEFAULT_SAMPLES = 8

-- Accepts {x=,y=,z=} or {1,2,3}, matching shared/grid.lua. z defaults to 0.
-- Returns nil for anything that is not a usable point, so a bad entry in a
-- hand-edited route is skipped rather than poisoning every segment after it.
local function px(p)
    if type(p) ~= 'table' then
        return nil
    end
    local x, y, z = p.x, p.y, p.z
    if x == nil then
        x, y, z = p[1], p[2], p[3]
    end
    if type(x) ~= 'number' or type(y) ~= 'number' then
        return nil
    end
    return x, y, z or 0
end

local function dist(a, b)
    local dx, dy, dz = b.x - a.x, b.y - a.y, b.z - a.z
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

--- Chord length of a polyline, summed.
--- @param points table|nil  list of point tables
--- @return number  0 for nil, for an empty list, and for a single point --
---         a caller asking "how long is this route" wants 0, not an error and
---         not an infinity
function CisCurve.lengthOf(points)
    if type(points) ~= 'table' then
        return 0
    end
    local total = 0
    local previous = nil
    for i = 1, #points do
        local x, y, z = px(points[i])
        if x then
            local p = { x = x, y = y, z = z }
            if previous then
                total = total + dist(previous, p)
            end
            previous = p
        end
    end
    return total
end

--- Cubic Hermite basis evaluation.
---
--- The primitive every spline here is built on: two endpoints and two tangents
--- in, one point out. Catmull-Rom is this with automatically derived tangents.
--- Hermite rather than Bezier because Bezier's control points are not on the
--- curve -- you cannot place a waypoint at a Bezier control point and have the
--- route go through it, which is the one thing a waypoint list must do.
---
---@param p0
---@param p1
---@param m0
---@param m1
---@param t
--- @return number, number, number  x, y, z
function CisCurve.hermite(p0, p1, m0, m1, t)
    local t2 = t * t
    local t3 = t2 * t
    -- Cubic Hermite basis. h00 and h01 interpolate the endpoints; h10 and h11
    -- apply the tangents. They sum to 1 for every t, which is what keeps the
    -- point on the curve for arbitrary (even non-monotonic) tangents.
    local h00 = 2 * t3 - 3 * t2 + 1
    local h10 = t3 - 2 * t2 + t
    local h01 = -2 * t3 + 3 * t2
    local h11 = t3 - t2
    return p0.x * h00 + m0.x * h10 + p1.x * h01 + m1.x * h11,
           p0.y * h00 + m0.y * h10 + p1.y * h01 + m1.y * h11,
           p0.z * h00 + m0.z * h10 + p1.z * h01 + m1.z * h11
end

--- Evaluate one Catmull-Rom segment from four control points.
---
--- `p1` and `p2` are the segment's endpoints; `p0` and `p3` are the neighbours
--- that shape the tangents. p0 and p3 may be nil, in which case the segment is
--- treated as an endpoint of an open path and its tangent becomes the plain
-- chord.
---
--- @param alpha number|nil  knot exponent: 0.5 centripetal (default), 0 uniform
--- @param t number          0 returns p1, 1 returns p2; not clamped
---@param p0
---@param p1
---@param p2
---@param p3
--- @return number, number, number  x, y, z
function CisCurve.catmullRom(p0, p1, p2, p3, t, alpha)
    alpha = alpha == nil and DEFAULT_ALPHA or alpha
    local ax, ay, az = px(p1)
    local bx, by, bz = px(p2)
    if not ax or not bx then
        return 0, 0, 0
    end
    p1 = { x = ax, y = ay, z = az }
    p2 = { x = bx, y = by, z = bz }

    -- A missing or unusable neighbour is replaced by the segment's own
    -- endpoint, which is the same "clone the ghost" rule newPath uses for the
    -- ends of an open path.
    local prev, nxt = p1, p2
    if p0 then
        local qx, qy, qz = px(p0)
        if qx then prev = { x = qx, y = qy, z = qz } end
    end
    if p3 then
        local rx, ry, rz = px(p3)
        if rx then nxt = { x = rx, y = ry, z = rz } end
    end

    local d0 = (dist(prev, p1)) ^ (alpha)
    local d1 = (dist(p1, p2)) ^ (alpha)
    local d2 = (dist(p2, nxt)) ^ (alpha)

    -- m1: the tangent leaving p1. Reduces to (p2 - p0) / 2 when the knot
    -- spacing is uniform, which is the classic uniform Catmull-Rom tangent.
    -- A zero knot interval means a duplicated control point, and the formula
    -- would collapse the tangent to zero and stall the curve there; the full
    -- chord is the correct limit in that case and is what keeps a 2-point path
    -- a straight line.
    local m1x, m1y, m1z
    if d0 <= 0 or (d0 + d1) <= 0 then
        m1x, m1y, m1z = p2.x - p1.x, p2.y - p1.y, p2.z - p1.z
    else
        m1x = ((p1.x - prev.x) * d1 + (p2.x - p1.x) * d0) / (d0 + d1)
        m1y = ((p1.y - prev.y) * d1 + (p2.y - p1.y) * d0) / (d0 + d1)
        m1z = ((p1.z - prev.z) * d1 + (p2.z - p1.z) * d0) / (d0 + d1)
    end
    local m2x, m2y, m2z
    if d2 <= 0 or (d1 + d2) <= 0 then
        m2x, m2y, m2z = p2.x - p1.x, p2.y - p1.y, p2.z - p1.z
    else
        m2x = ((p2.x - p1.x) * d2 + (nxt.x - p2.x) * d1) / (d1 + d2)
        m2y = ((p2.y - p1.y) * d2 + (nxt.y - p2.y) * d1) / (d1 + d2)
        m2z = ((p2.z - p1.z) * d2 + (nxt.z - p2.z) * d1) / (d1 + d2)
    end

    return CisCurve.hermite(p1, p2, { x = m1x, y = m1y, z = m1z },
        { x = m2x, y = m2y, z = m2z }, t)
end

-- Build a path. See the header for what a path is and why it exists.
--
-- opts:
--   closed  boolean  treat the last point as adjacent to the first. A loop
--            route. Segments = points, and pointAt wraps instead of clamping.
--   alpha   number   0.5 (default) centripetal, 0 uniform.
--   samples number   arc-length samples per segment, default 8. Higher is
--            smoother and costs memory once at build time; 8 is already well
--            under a centimetre of error on typical route chords.
--
-- Edge cases, all of which produce a path that answers rather than errors:
--   nil / {} / all-invalid   a path with 0 points; length 0; pointAt -> nil
--   1 point                   length 0; pointAt returns that point
--   2 points                  a straight line
--   3+ collinear points       a straight line, because the tangents are collinear
--
-- @param points table  list of point tables; entries that are not usable
--        points are dropped, so a route with one bad entry still works
-- @return table  the path; treat it as read-only
---@param points
---@param opts
--- @return table  a path handle: { points, closed, alpha, samples, segments, count, length, arcD }. A non-table or too-few points still yields a usable empty path rather than nil.
function CisCurve.newPath(points, opts)
    opts = opts or {}
    local closed = opts.closed and true or false
    local alpha = type(opts.alpha) == 'number' and opts.alpha or DEFAULT_ALPHA
    local samples = type(opts.samples) == 'number' and math.floor(opts.samples) or DEFAULT_SAMPLES
    if samples < 1 then samples = 1 end

    local clean = {}
    if type(points) == 'table' then
        for i = 1, #points do
            local x, y, z = px(points[i])
            if x then
                clean[#clean + 1] = { x = x, y = y, z = z }
            end
        end
    end

    local n = #clean
    local segments = 0
    if n >= 2 then
        segments = closed and n or (n - 1)
    end

    local path = {
        points = clean,
        closed = closed,
        alpha = alpha,
        samples = samples,
        segments = segments,
        count = n,
        length = 0,
        arcD = {},
        arcSeg = {},
        arcT = {},
        arcN = 0,
        -- Per-segment tangents, flat arrays. Precomputed because a path is
        -- sampled every frame by something and four sqrt() calls per query is
        -- four sqrt() calls per frame for a value that never changes.
        m1x = {}, m1y = {}, m1z = {},
        m2x = {}, m2y = {}, m2z = {},
    }

    if segments < 1 then
        return path
    end

    -- Control point accessor that wraps for a closed path and CLONES at the
    -- ends of an open one. Cloning (rather than reflecting) the endpoint means
    -- the curve leaves the first waypoint along the first chord instead of
    -- shooting off backwards past it, which is what a reflected ghost does.
    local function control(index)
        if closed then
            local wrapped = ((index - 1) % n) + 1
            return clean[wrapped]
        end
        if index < 1 then return clean[1] end
        if index > n then return clean[n] end
        return clean[index]
    end

    local total = 0
    for s = 1, segments do
        local p0 = control(s - 1)
        local p1 = control(s)
        local p2 = control(s + 1)
        local p3 = control(s + 2)

        local d0 = (dist(p0, p1)) ^ (alpha)
        local d1 = (dist(p1, p2)) ^ (alpha)
        local d2 = (dist(p2, p3)) ^ (alpha)

        local m1x, m1y, m1z
        if d0 <= 0 or (d0 + d1) <= 0 then
            m1x, m1y, m1z = p2.x - p1.x, p2.y - p1.y, p2.z - p1.z
        else
            m1x = ((p1.x - p0.x) * d1 + (p2.x - p1.x) * d0) / (d0 + d1)
            m1y = ((p1.y - p0.y) * d1 + (p2.y - p1.y) * d0) / (d0 + d1)
            m1z = ((p1.z - p0.z) * d1 + (p2.z - p1.z) * d0) / (d0 + d1)
        end
        local m2x, m2y, m2z
        if d2 <= 0 or (d1 + d2) <= 0 then
            m2x, m2y, m2z = p2.x - p1.x, p2.y - p1.y, p2.z - p1.z
        else
            m2x = ((p2.x - p1.x) * d2 + (p3.x - p2.x) * d1) / (d1 + d2)
            m2y = ((p2.y - p1.y) * d2 + (p3.y - p2.y) * d1) / (d1 + d2)
            m2z = ((p2.z - p1.z) * d2 + (p3.z - p2.z) * d1) / (d1 + d2)
        end

        path.m1x[s], path.m1y[s], path.m1z[s] = m1x, m1y, m1z
        path.m2x[s], path.m2y[s], path.m2z[s] = m2x, m2y, m2z

        -- Walk the segment, accumulating chord length. The first sample of
        -- every segment after the first repeats the last sample of the
        -- previous one, so the table is continuous and a lookup between
        -- samples i and i+1 never straddles a segment boundary.
        local prevX, prevY, prevZ
        for k = 0, samples do
            local t = k / samples
            local t2 = t * t
            local t3 = t2 * t
            local h00 = 2 * t3 - 3 * t2 + 1
            local h10 = t3 - 2 * t2 + t
            local h01 = -2 * t3 + 3 * t2
            local h11 = t3 - t2
            local x = p1.x * h00 + m1x * h10 + p2.x * h01 + m2x * h11
            local y = p1.y * h00 + m1y * h10 + p2.y * h01 + m2y * h11
            local z = p1.z * h00 + m1z * h10 + p2.z * h01 + m2z * h11
            if prevX then
                local dx, dy, dz = x - prevX, y - prevY, z - prevZ
                total = total + math.sqrt(dx * dx + dy * dy + dz * dz)
            end
            path.arcN = path.arcN + 1
            path.arcD[path.arcN] = total
            path.arcSeg[path.arcN] = s
            path.arcT[path.arcN] = t
            prevX, prevY, prevZ = x, y, z
        end
    end

    path.length = total
    return path
end

--- Number of control points, or 0 for a path built from nothing.
---@param path
--- @return number
function CisCurve.count(path)
    if type(path) ~= 'table' then
        return 0
    end
    return path.count or 0
end

--- Total arc length of the path in metres, measured along the CURVE and not
--- along the straight chords between waypoints. The two differ by a few
--- percent on a curvy route, and it is the curve that a vehicle drives.
---@param path
--- @return number  0 for a path with fewer than two points
function CisCurve.length(path)
    if type(path) ~= 'table' then
        return 0
    end
    return path.length or 0
end

-- The two arc-table indices that BRACKET `d`: the largest index whose
-- distance is <= d, and the one after it.
--
-- Both numbers matter, and the distinction is the whole function. The binary
-- search finds the LOWER bracket; the upper bracket is `lo + 1`, not whatever
-- bound the search happened to finish with. Returning the search bound instead
-- makes every query collapse onto a stored sample, and that failure is SILENT:
-- pointAt still returns a point on the path, just always the nearest sample
-- rather than the point at the distance asked for, so a constant-speed
-- traversal moves in visible jumps with no error anywhere.
local function locate(path, d)
    local n = path.arcN
    if n < 2 then
        return 1, 1
    end
    local lo, hi = 1, n
    while lo < hi do
        local mid = math.floor((lo + hi + 1) * 0.5)
        if path.arcD[mid] <= d then
            lo = mid
        else
            hi = mid - 1
        end
    end
    local upper = lo + 1
    if upper > n then
        upper = n
    end
    return lo, upper
end

--- The point at `distance` metres along the path.
---
--- Returns x, y, z as three numbers with NO allocation, because this is the
--- function a moving entity calls every frame and a fresh table per call is a
--- GC pause waiting for a firefight. Use `pointAt` when a table is what you
--- want.
---
--- @param path table
--- @param distance number  metres. Clamped to the path on an open path; WRAPS
---        modulo the length on a closed one, so something driving a loop never
---        stops dead at the seam.
--- @return number, number, number, number  x, y, z, ok
---         `ok` is false only when the path has no points at all
function CisCurve.pointAtXYZ(path, distance)
    if type(path) ~= 'table' or (path.count or 0) < 1 then
        return 0, 0, 0, false
    end
    if (path.segments or 0) < 1 then
        local p = path.points[1]
        return p.x, p.y, p.z, true
    end
    if type(distance) ~= 'number' or distance ~= distance then
        distance = 0
    end
    if path.closed and path.length > 0 then
        distance = distance % path.length
    elseif distance < 0 then
        distance = 0
    elseif distance > path.length then
        distance = path.length
    end

    local lo, hi = locate(path, distance)
    local dLo, dHi = path.arcD[lo], path.arcD[hi]
    local s, t
    if dHi > dLo then
        -- Linear interpolation of the LOCAL t between the two bracketing
        -- samples. This is where the `samples` option buys its accuracy: the
        -- error is the arc-length error of a straight chord across one sample
        -- interval, which shrinks as samples grows.
        local f = (distance - dLo) / (dHi - dLo)
        local tLo, tHi = path.arcT[lo], path.arcT[hi]
        t = tLo + (tHi - tLo) * f
        if path.arcSeg[lo] == path.arcSeg[hi] then
            s = path.arcSeg[lo]
        else
            s = f < 0.5 and path.arcSeg[lo] or path.arcSeg[hi]
        end
    else
        s, t = path.arcSeg[lo], path.arcT[lo]
    end
    if t > 1 then t = 1 end
    if t < 0 then t = 0 end

    local n = path.count
    local p1 = path.points[s]
    local p2 = path.points[(s % n) + 1]
    if not p2 then
        return p1.x, p1.y, p1.z, true
    end
    local t2 = t * t
    local t3 = t2 * t
    local h00 = 2 * t3 - 3 * t2 + 1
    local h10 = t3 - 2 * t2 + t
    local h01 = -2 * t3 + 3 * t2
    local h11 = t3 - t2
    return p1.x * h00 + path.m1x[s] * h10 + p2.x * h01 + path.m2x[s] * h11,
           p1.y * h00 + path.m1y[s] * h10 + p2.y * h01 + path.m2y[s] * h11,
           p1.z * h00 + path.m1z[s] * h10 + p2.z * h01 + path.m2z[s] * h11,
           true
end

--- The point at `distance` metres along the path, as a table.
--- @param out table|nil  write into this instead of allocating
---@param path
---@param distance
--- @return table|nil  { x, y, z }, or nil when the path has no points
function CisCurve.pointAt(path, distance, out)
    local x, y, z, ok = CisCurve.pointAtXYZ(path, distance)
    if not ok then
        return nil
    end
    out = out or {}
    out.x, out.y, out.z = x, y, z
    return out
end

--- The point at a fraction of the whole path, 0..1. This is a CONVENIENCE over
--- pointAt, not a separate parameterisation: it maps through arc length, so
--- even t += speed*dt is constant speed. Use pointAt with a real distance when
--- the caller is integrating a speed.
---@param path
---@param t
---@param out
--- @return table|nil
function CisCurve.pointAtT(path, t, out)
    local length = CisCurve.length(path)
    if type(t) ~= 'number' or t ~= t then
        t = 0
    end
    return CisCurve.pointAt(path, t * length, out)
end

--- Unit tangent (the direction of travel) at `distance` metres along the path.
---
--- A central difference with a small offset, not an analytic derivative. The
--- analytic derivative is available and is one line, but the finite difference
--- is immune to the arc-length table's sampling error near a segment boundary
--- and needs no extra per-segment storage. The offset is a fraction of the
--- segment sample spacing, so the cost is the same at every path size.
---
---@param path
---@param distance
--- @return number, number, number  x, y, z -- all zero for a degenerate path
---         or a point where the path doubles back on itself
function CisCurve.tangentAtXYZ(path, distance)
    local length = CisCurve.length(path)
    if length <= 0 then
        return 0, 0, 0
    end
    local eps = length * 1e-4
    if eps <= 0 then
        eps = 1e-4
    end
    local ax, ay, az = CisCurve.pointAtXYZ(path, distance - eps)
    local bx, by, bz = CisCurve.pointAtXYZ(path, distance + eps)
    local dx, dy, dz = bx - ax, by - ay, bz - az
    local d = math.sqrt(dx * dx + dy * dy + dz * dz)
    if d <= 0 then
        return 0, 0, 0
    end
    return dx / d, dy / d, dz / d
end

--- Evenly spaced samples along the path, for drawing a route, handing one to a
--- native, or spawning a trail.
---
--- @param count number|nil  number of POINTS; default is one per whole metre,
---        clamped to [1, 4096] because a caller asking for a million points has
---        a bug and allocating for it would hide the bug behind an OOM
---@param path
--- @return table  array of { x, y, z }; empty for a path with no points.
---         On an open path the first and last samples are the two endpoints.
---         On a closed path the samples do NOT repeat the start, so the list can
---         be fed straight to a line renderer without a doubled line.
function CisCurve.sample(path, count)
    local out = {}
    if type(path) ~= 'table' or (path.count or 0) < 1 then
        return out
    end
    if type(count) ~= 'number' or count ~= count or count < 1 then
        count = math.floor(CisCurve.length(path)) + 1
    end
    if count > 4096 then
        count = 4096
    end
    count = math.floor(count)
    local closed = path.closed and true or false
    local length = CisCurve.length(path)
    for i = 0, count - 1 do
        local d
        if closed or count <= 1 then
            d = (i / math.max(count, 1)) * length
        else
            d = (i / (count - 1)) * length
        end
        out[#out + 1] = CisCurve.pointAt(path, d)
    end
    return out
end
