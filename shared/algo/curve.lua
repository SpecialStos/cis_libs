-- Catmull-Rom / cubic Hermite splines and arc-length parameterised paths.

local M = {}

local DEFAULT_ALPHA = 0.5
local DEFAULT_SAMPLES = 8

-- Accepts {x=,y=,z=} or {1,2,3}, matching shared/grid.lua.
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
function M.lengthOf(points)
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
--- @param p0
--- @param p1
--- @param m0
--- @param m1
--- @param t
--- @return number, number, number  x, y, z
function M.hermite(p0, p1, m0, m1, t)
    local t2 = t * t
    local t3 = t2 * t
    -- Cubic Hermite basis. h00 and h01 interpolate the endpoints; h10 and h11 apply the
    local h00 = 2 * t3 - 3 * t2 + 1
    local h10 = t3 - 2 * t2 + t
    local h01 = -2 * t3 + 3 * t2
    local h11 = t3 - t2
    return p0.x * h00 + m0.x * h10 + p1.x * h01 + m1.x * h11,
           p0.y * h00 + m0.y * h10 + p1.y * h01 + m1.y * h11,
           p0.z * h00 + m0.z * h10 + p1.z * h01 + m1.z * h11
end

-- chord.
--- Evaluate one Catmull-Rom segment from four control points.
--- @param alpha number|nil  knot exponent: 0.5 centripetal (default), 0 uniform
--- @param t number          0 returns p1, 1 returns p2; not clamped
--- @param p0
--- @param p1
--- @param p2
--- @param p3
--- @return number, number, number  x, y, z
function M.catmullRom(p0, p1, p2, p3, t, alpha)
    alpha = alpha == nil and DEFAULT_ALPHA or alpha
    local ax, ay, az = px(p1)
    local bx, by, bz = px(p2)
    if not ax or not bx then
        return 0, 0, 0
    end
    p1 = { x = ax, y = ay, z = az }
    p2 = { x = bx, y = by, z = bz }

    -- A missing or unusable neighbour is replaced by the segment's own endpoint, which
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

    -- m1: the tangent leaving p1. Reduces to (p2 - p0) / 2 when the knot spacing is
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

    return M.hermite(p1, p2, { x = m1x, y = m1y, z = m1z },
        { x = m2x, y = m2y, z = m2z }, t)
end

-- Build a path. See the header for what a path is and why it exists.
--- @param points
--- @param opts
--- @return table  a path handle: { points, closed, alpha, samples, segments, count, length, arcD }. A non-table or too-few points still yields a usable empty path rather than nil.
function M.newPath(points, opts)
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
        -- Per-segment tangents, flat arrays.
        m1x = {}, m1y = {}, m1z = {},
        m2x = {}, m2y = {}, m2z = {},
    }

    if segments < 1 then
        return path
    end

    -- Control point accessor that wraps for a closed path and CLONES at the ends of an
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

        -- Walk the segment, accumulating chord length.
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
--- @param path
--- @return number
function M.count(path)
    if type(path) ~= 'table' then
        return 0
    end
    return path.count or 0
end

--- Total arc length of the path in metres, measured along the CURVE and not along the
--- @param path
--- @return number  0 for a path with fewer than two points
function M.length(path)
    if type(path) ~= 'table' then
        return 0
    end
    return path.length or 0
end

-- The two arc-table indices that BRACKET `d`: the largest index whose distance is <= d,
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
--- @param path table
--- @param distance number  metres. Clamped to the path on an open path; WRAPS
--- @return number, number, number, number  x, y, z, ok
function M.pointAtXYZ(path, distance)
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
        -- Linear interpolation of the LOCAL t between the two bracketing samples.
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
--- @param path
--- @param distance
--- @return table|nil  { x, y, z }, or nil when the path has no points
function M.pointAt(path, distance, out)
    local x, y, z, ok = M.pointAtXYZ(path, distance)
    if not ok then
        return nil
    end
    out = out or {}
    out.x, out.y, out.z = x, y, z
    return out
end

--- The point at a fraction of the whole path, 0..1.
--- @param path
--- @param t
--- @param out
--- @return table|nil
function M.pointAtT(path, t, out)
    local length = M.length(path)
    if type(t) ~= 'number' or t ~= t then
        t = 0
    end
    return M.pointAt(path, t * length, out)
end

--- Unit tangent (the direction of travel) at `distance` metres along the path.
--- @param path
--- @param distance
--- @return number, number, number  x, y, z -- all zero for a degenerate path
function M.tangentAtXYZ(path, distance)
    local length = M.length(path)
    if length <= 0 then
        return 0, 0, 0
    end
    local eps = length * 1e-4
    if eps <= 0 then
        eps = 1e-4
    end
    local ax, ay, az = M.pointAtXYZ(path, distance - eps)
    local bx, by, bz = M.pointAtXYZ(path, distance + eps)
    local dx, dy, dz = bx - ax, by - ay, bz - az
    local d = math.sqrt(dx * dx + dy * dy + dz * dz)
    if d <= 0 then
        return 0, 0, 0
    end
    return dx / d, dy / d, dz / d
end

--- Evenly spaced samples along the path, for drawing a route, handing one to a native,
--- @param count number|nil  number of POINTS; default is one per whole metre,
--- @param path
--- @return table  array of { x, y, z }; empty for a path with no points.
function M.sample(path, count)
    local out = {}
    if type(path) ~= 'table' or (path.count or 0) < 1 then
        return out
    end
    if type(count) ~= 'number' or count ~= count or count < 1 then
        count = math.floor(M.length(path)) + 1
    end
    if count > 4096 then
        count = 4096
    end
    count = math.floor(count)
    local closed = path.closed and true or false
    local length = M.length(path)
    for i = 0, count - 1 do
        local d
        if closed or count <= 1 then
            d = (i / math.max(count, 1)) * length
        else
            d = (i / (count - 1)) * length
        end
        out[#out + 1] = M.pointAt(path, d)
    end
    return out
end

-- A MODULE, NOT A GLOBAL.
if ... ~= 'cis_require' then
    CisCurve = M
end

return M
