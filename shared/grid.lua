-- Spatial hash used by zones and doors. No natives; safe to unit-test.

CisGrid = {
    CELL = 64,
    STRIDE = 65536,
}

local CELL = CisGrid.CELL
local STRIDE = CisGrid.STRIDE

function CisGrid.cell(x, y)
    return math.floor(x / CELL), math.floor(y / CELL)
end

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

function CisGrid.insert(grid, id, aabb, data)
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
-- queryPoint is the cheap path and is what the zones and doors use.
-- queryNeighbors is kept for callers that want a neighbourhood superset (for
-- example to pre-warm something outside the exact AABB test); it costs nine
-- bucket lookups and a per-call `seen` table for a set that is identical to
-- queryPoint's once the AABB test is applied.
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

function CisGrid.aabbFromPoints(points, minZ, maxZ, pad)
    pad = pad or 0
    local minX, minY = math.huge, math.huge
    local maxX, maxY = -math.huge, -math.huge
    for i = 1, #points do
        local p = points[i]
        local px, py = p.x or p[1], p.y or p[2]
        if px < minX then minX = px end
        if py < minY then minY = py end
        if px > maxX then maxX = px end
        if py > maxY then maxY = py end
    end
    if minX == math.huge then
        -- No points: hand back an empty box rather than infinities, which
        -- would make the box uninsertable and the arithmetic below useless.
        return { minX = 0, minY = 0, maxX = 0, maxY = 0, minZ = minZ or -1000, maxZ = maxZ or 10000 }
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
