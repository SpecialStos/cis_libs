-- Spatial hash used by zones and doors. No natives; safe to unit-test.

CisGrid = {
    CELL = 64,
    STRIDE = 65536,
}

local CELL = CisGrid.CELL
local STRIDE = CisGrid.STRIDE

-- The most cells one item may cover.
local MAX_CELLS = 4096

function CisGrid.cell(x, y)
    return math.floor(x / CELL), math.floor(y / CELL)
end

-- A negative cell coordinate is a normal case, not a boundary: a player in the
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
local function checkAabb(aabb)
    if type(aabb) ~= 'table' then
        return nil, ('an AABB is required, got %s'):format(type(aabb))
    end
    local minX, maxX = aabb.minX, aabb.maxX
    local minY, maxY = aabb.minY, aabb.maxY
    -- An array, not a keyed table: ipairs walks 1..n, and a table built with string
    for _, v in ipairs({ minX, maxX, minY, maxY }) do
        if type(v) ~= 'number' then
            return nil, ('an AABB bound is %s, not a number'):format(type(v))
        end
        -- NaN passes every ordinary test: `NaN > x` is false, so both an inverted-AABB
        if v ~= v then
            return nil, 'the AABB has a NaN bound'
        end
    end
    -- minZ and maxZ may be nil -- queryPoint reads a nil z as "do not test z" -- but
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

-- insert() re-inserts rather than updating, so a caller that grows an AABB does not
function CisGrid.insert(grid, id, aabb, data)
    local ok, why = checkAabb(aabb)
    if not ok then
        return false, why
    end

    -- The cell count is computed BEFORE the loop, not inside it, so the refusal happens
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

-- Both queries below are exact.
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
--- @return the box, or `nil, reason`. An EMPTY list is refused rather than
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

-- Crossing number. Points on an edge and points on a vertex are not guaranteed inside;
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
