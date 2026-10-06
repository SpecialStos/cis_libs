-- Pure zone containment. No natives. Client zones.lua and server/zones.lua
-- share this so a server-side contains() cannot drift from the client one.
--
-- The math itself lives in CisGrid. This file is the ZONE RECORD shape:
-- kind, centre, half-extents, heading, radius, poly points, minZ/maxZ.

CisZoneGeom = {}

function CisZoneGeom.contains(zone, coords)
    if type(zone) ~= 'table' or coords == nil then
        return false
    end
    if type(coords.x) ~= 'number' or type(coords.y) ~= 'number' then
        return false
    end
    local z = coords.z
    if type(z) ~= 'number' then
        z = 0.0
    end
    if zone.kind == 'poly' then
        if z < (zone.minZ or -math.huge) or z > (zone.maxZ or math.huge) then
            return false
        end
        return CisGrid.pointInPolygon(coords.x, coords.y, zone.points)
    elseif zone.kind == 'sphere' then
        return CisGrid.pointInSphere(coords.x, coords.y, z, zone.cx, zone.cy, zone.cz, zone.radius)
    elseif zone.kind == 'box' then
        return CisGrid.pointInBox(coords.x, coords.y, z, zone.cx, zone.cy, zone.cz, zone.hx, zone.hy, zone.hz, zone.heading)
    end
    return false
end
