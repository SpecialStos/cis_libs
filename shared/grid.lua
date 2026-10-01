-- Spatial hash used by zones and doors. No natives; safe to unit-test.
--
-- PURE. A consumer may `shared_script` this file for a private grid -- it is
-- the cheapest way to get spatial logic with zero boundary crossings, and
-- COMPATIBILITY.md §10.2 lists it as safe to duplicate. The cost is the
-- memory and the fact that the copy indexes nothing the library knows about.

CisGrid = {
    CELL = 64,
    STRIDE = 65536,
}

local CELL = CisGrid.CELL
local STRIDE = CisGrid.STRIDE

-- The most cells one item may cover.
--
-- insert() walks every cell an AABB overlaps, in a nested loop, on the main
-- thread. The loop is driven by the caller's NUMBERS, so a size written in
-- metres that arrives here as a cell count, or a zone covering "the whole map",
-- is one config typo away from a freeze -- and a Lua loop cannot be interrupted
-- once it starts, so nothing downstream can save it.
--
-- 4096 cells is 64 by 64, which at CELL = 64 is a four-kilometre box. Every
-- zone in a real map is orders of magnitude smaller than that, so nothing
-- legitimate is refused; the cap is set by what is absurd rather than by what is
-- large. A caller who genuinely needs a bigger box wants a different structure,
-- and gets told so.
local MAX_CELLS = 4096

function CisGrid.cell(x, y)
    return math.floor(x / CELL), math.floor(y / CELL)
end

-- A negative cell coordinate is a normal case, not a boundary: a player in the
-- bottom-left of the map is at a negative x, and the STRIDE offset is what keeps
-- a negative cx from colliding with the same cy at a positive cx. STRIDE has to
-- exceed the usable cell range, not the map size.
function CisGrid.key(cx, cy)
    return cx + cy * STRIDE
end

function CisGrid.keyFromWorld(x, y)
    local cx, cy = CisGrid.cell(x, y)
    return CisGrid.key(cx, cy), cx, cy
end

function CisGrid.new()
    return {
        cells = {},
        items = {},
    }
end

-- Validate an AABB before anything walks it.
--
-- NaN gets its own line because it passes every ordinary test: `NaN > x` is
-- false, so an inverted-AABB check and a bounds check both wave it through, and
-- the cell loops then cover nothing at all -- the item is inserted and can never
-- be found. Silent in both directions, which is why it is named here.
local function checkAabb(aabb)
    if type(aabb) ~= 'table' then
        return nil, ('an AABB is required, got %s'):format(type(aabb))
    end
    local minX, maxX = aabb.minX, aabb.maxX
    local minY, maxY = aabb.minY, aabb.maxY
    -- An array, not a keyed table: ipairs walks 1..n, and a table built with
    -- string keys has an empty array part, so the loop would not run at all.
    for _, v in ipairs({ minX, maxX, minY, maxY }) do
        if type(v) ~= 'number' then
            return nil, ('an AABB bound is %s, not a number'):format(type(v))
        end
        -- NaN passes every ordinary test: `NaN > x` is false, so both an
        -- inverted-AABB check and a range check wave it through, and the cell
        -- loops then cover nothing. The item inserts and can never be found.
        if v ~= v then
            return nil, 'the AABB has a NaN bound'
        end
    end
    -- minZ and maxZ may be nil -- queryPoint reads a nil z as "do not test z" --
    -- but not NaN.
    for _, v in ipairs({ aabb.minZ, aabb.maxZ }) do
        if v ~= nil and v ~= v then
            return nil, 'the AABB has a NaN z bound'
        end
    end
    if minX > maxX or minY > maxY then
        return nil, ('the AABB is inverted: minX %s > maxX %s, minY %s > maxY %s')
            :format(tostring(minX), tostring(maxX), tostring(minY), tostring(maxY))
    end
    return true
end

local function eachOverlappingCells(aabb, fn)
    local minCx = math.floor(aabb.minX / CELL)
    local maxCx = math.floor(aabb.maxX / CELL)
    local minCy = math.floor(aabb.minY / CELL)
    local maxCy = math.floor(aabb.maxY / CELL)
    for cy = minCy, maxCy do
        for cx = minCx, maxCx do
            fn(CisGrid.key(cx, cy), cx, cy)
        end
    end
end

-- insert() re-inserts rather than updating, so a caller that grows an AABB
-- does not have to remove first. The `keys` list is what makes remove() exact:
-- without it, removal would have to rescan every cell in the grid.
--
-- @return boolean|nil  true on success; `false, reason` when the AABB is
--   malformed or covers more cells than MAX_CELLS. Nothing is inserted on a
--   refusal, so a caller that ignores the return has no half-inserted item it
--   could go on to query.
function CisGrid.insert(grid, id, aabb, data)
    local ok, why = checkAabb(aabb)
    if not ok then
        return false, why
    end

    -- The cell count is computed BEFORE the loop, not inside it, so the refusal
    -- happens before any work rather than after most of it. Both dimensions are
    -- checked as well as the product: a single huge axis has to be caught even
    -- when the product has already overflowed to infinity and stopped meaning
    -- anything.
    local minCx = math.floor(aabb.minX / CELL)
    local maxCx = math.floor(aabb.maxX / CELL)
    local minCy = math.floor(aabb.minY / CELL)
    local maxCy = math.floor(aabb.maxY / CELL)
    local cols = maxCx - minCx + 1
    local rows = maxCy - minCy + 1
    if cols > MAX_CELLS or rows > MAX_CELLS or cols * rows > MAX_CELLS then
        return false, ('the AABB covers %.0fx%.0f cells; at most %d are allowed. '
            .. 'A size in metres read as a cell count lands here.')
            :format(cols, rows, MAX_CELLS)
    end

    CisGrid.remove(grid, id)
    local keys = {}
    eachOverlappingCells(aabb, function(key)
        local bucket = grid.cells[key]
        if not bucket then
            bucket = {}
            grid.cells[key] = bucket
        end
        bucket[id] = true
        keys[#keys + 1] = key
    end)
    grid.items[id] = {
        aabb = aabb,
        data = data,
        keys = keys,
    }
    return true
end

function CisGrid.remove(grid, id)
    local item = grid.items[id]
    if not item then
        return
    end
    for i = 1, #item.keys do
        local key = item.keys[i]
        local bucket = grid.cells[key]
        if bucket then
            bucket[id] = nil
            if next(bucket) == nil then
                grid.cells[key] = nil
            end
        end
    end
    grid.items[id] = nil
end

function CisGrid.clear(grid)
    grid.cells = {}
    grid.items = {}
end

-- Both queries below are exact. Because insert() registers an id in every cell
-- its AABB overlaps, an AABB that contains (x,y) must cover the cell containing
-- (x,y), so the single-cell bucket is provably sufficient.
--
-- That proof is why the zones and the doors call queryPoint and not
-- queryNeighbors: a 3x3 neighbour scan returns the identical set for nine
-- bucket lookups instead of one, plus a fresh `seen` table per call to
-- de-duplicate ids that the AABB test would have rejected anyway. On a frame
-- where the player is inside several zones that is nine times the work for the
-- same answer.
--
-- It is not inferred. test/run.lua seeds 250 fuzzed AABBs and 3000 random query
-- points and asserts all three of: queryPoint == brute force, queryNeighbors ==
-- brute force, and queryPoint == queryNeighbors. Change insert() and those
-- three are the assertions that tell you.
--
-- queryNeighbors is kept for callers that want a neighbourhood SUPERSET -- for
-- example to pre-warm something outside the exact AABB test. It stays correct
-- because the AABB test is applied per item, not because the extra eight cells
-- are needed.
function CisGrid.queryPoint(grid, x, y, z, fn)
    local key = CisGrid.keyFromWorld(x, y)
    local bucket = grid.cells[key]
    if not bucket then
        return
    end
    for id in pairs(bucket) do
        local item = grid.items[id]
        if item then
            local aabb = item.aabb
            if x >= aabb.minX and x <= aabb.maxX and y >= aabb.minY and y <= aabb.maxY then
                if z == nil or (z >= aabb.minZ and z <= aabb.maxZ) then
                    fn(id, item)
                end
            end
        end
    end
end

function CisGrid.queryNeighbors(grid, x, y, z, fn)
    local cx, cy = CisGrid.cell(x, y)
    local seen = {}
    for oy = -1, 1 do
        for ox = -1, 1 do
            local bucket = grid.cells[CisGrid.key(cx + ox, cy + oy)]
            if bucket then
                for id in pairs(bucket) do
                    if not seen[id] then
                        seen[id] = true
                        local item = grid.items[id]
                        if item then
                            local aabb = item.aabb
                            if x >= aabb.minX and x <= aabb.maxX and y >= aabb.minY and y <= aabb.maxY then
                                if z == nil or (z >= aabb.minZ and z <= aabb.maxZ) then
                                    fn(id, item)
                                end
                            end
                        end
                    end
                end
            end
        end
    end
end

--- The smallest box containing every point.
---
--- @return the box, or `nil, reason`. An EMPTY list is refused rather than
---   answered with a zero-size box at the world origin, which is what it used
---   to return. That was not a neutral answer: a poly zone configured with no
---   points registered a box covering (0,0), so it fired its enter event for
---   any player who spawned or respawned near the origin and nothing else ever
---   heard about it. A config mistake with a shape is a support ticket; a
---   config mistake with a location is a bug report about the wrong zone.
function CisGrid.aabbFromPoints(points, minZ, maxZ, pad)
    if type(points) ~= 'table' then
        return nil, ('a point list is required, got %s'):format(type(points))
    end
    pad = pad or 0
    local minX, minY = math.huge, math.huge
    local maxX, maxY = -math.huge, -math.huge
    for i = 1, #points do
        local p = points[i]
        local px, py = p.x or p[1], p.y or p[2]
        if px ~= px or py ~= py then
            return nil, ('point %d has a NaN coordinate'):format(i)
        end
        if px < minX then minX = px end
        if py < minY then minY = py end
        if px > maxX then maxX = px end
        if py > maxY then maxY = py end
    end
    if minX == math.huge then
        return nil, 'the point list is empty, so there is no box to build'
    end
    return {
        minX = minX - pad,
        minY = minY - pad,
        maxX = maxX + pad,
        maxY = maxY + pad,
        minZ = (minZ or -1000) - pad,
        maxZ = (maxZ or 10000) + pad,
    }
end

function CisGrid.aabbFromCenter(x, y, z, hx, hy, hz)
    return {
        minX = x - hx,
        minY = y - hy,
        maxX = x + hx,
        maxY = y + hy,
        minZ = z - hz,
        maxZ = z + hz,
    }
end

-- Crossing number. Points on an edge and points on a vertex are not guaranteed
-- inside; the fuzz reference uses the same AABB semantics, so a disagreement at
-- the boundary would show up as a test failure rather than as a zone that
-- flickers.
function CisGrid.pointInPolygon(x, y, points)
    local inside = false
    local j = #points
    for i = 1, #points do
        local pi, pj = points[i], points[j]
        local xi, yi = pi.x or pi[1], pi.y or pi[2]
        local xj, yj = pj.x or pj[1], pj.y or pj[2]
        if (yi > y) ~= (yj > y) then
            local denom = yj - yi
            if denom ~= 0 then
                local intersect = ((xj - xi) * (y - yi) / denom) + xi
                if x < intersect then
                    inside = not inside
                end
            end
        end
        j = i
    end
    return inside
end

function CisGrid.pointInSphere(x, y, z, cx, cy, cz, radius)
    local dx, dy, dz = x - cx, y - cy, z - cz
    return (dx * dx + dy * dy + dz * dz) <= (radius * radius)
end

function CisGrid.pointInBox(x, y, z, cx, cy, cz, hx, hy, hz, heading)
    local dx, dy, dz = x - cx, y - cy, z - cz
    if dz < -hz or dz > hz then
        return false
    end
    if not heading or heading == 0 then
        return dx >= -hx and dx <= hx and dy >= -hy and dy <= hy
    end
    local rad = heading * math.pi / 180.0
    local c, s = math.cos(-rad), math.sin(-rad)
    local lx = dx * c - dy * s
    local ly = dx * s + dy * c
    return lx >= -hx and lx <= hx and ly >= -hy and ly <= hy
end
