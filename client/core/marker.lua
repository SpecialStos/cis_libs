-- Markers, drawn by ONE thread per consumer, and only while any exist.
--
-- Consumer-side only (`Cis.marker.*`, loaded by init.lua from `files {}`): a
-- DrawMarker has to be issued every frame by whoever wants it seen, so it can
-- only ever run in the VM that owns it. Crossing into cis_libs per marker per
-- frame is the cost this file exists to remove.
--
-- CULLED. A marker further than its own `distance` from the player is not drawn,
-- and a pass that draws nothing sleeps SLEEP_MS rather than a frame: a resource
-- with markers across the map costs a distance check five times a second, not a
-- DrawMarker sixty times a second.
--
-- NO ALLOCATION PER FRAME. Every marker is stored as flat numbers at add time;
-- the pass reads fields and calls one native.
--
-- cfg: coords() the player's coords, guard(name, body) -> tick, log(level, message)

local M = {}

local SLEEP_MS = 200
local DEFAULT_DISTANCE = 50.0

local Markers = {}
Markers.__index = Markers

local function noop() end

local function num(v, fallback)
    if type(v) == 'number' and v == v and v ~= math.huge and v ~= -math.huge then
        return v
    end
    return fallback
end

-- A vector3, a vector4, { x, y, z } or { 1, 2, 3 }; nil for anything else.
local function xyz(v)
    if type(v) == 'number' then
        return v, v, v
    end
    if type(v) == 'vector3' or type(v) == 'vector4' or type(v) == 'table' then
        local x, y, z = v.x or v[1], v.y or v[2], v.z or v[3]
        if type(x) == 'number' and type(y) == 'number' and type(z) == 'number' then
            return x, y, z
        end
    end
    return nil
end

function M.new(cfg)
    cfg = cfg or {}
    return setmetatable({
        coordsOf = cfg.coords,
        guard = cfg.guard or function(_, body) return body end,
        log = cfg.log or noop,
        markers = {},
        count = 0,
        nextId = 0,
        driving = false,
        -- The last pass's verdict, for a test or a debug view.
        drawn = 0,
    }, Markers)
end

--- Add a marker. Answers its id, or false and a reason.
--- opts: coords (required), type (default 1), size|scale (number or xyz, default 1.0),
--- color { r, g, b, a } (default 255, 255, 255, 180), distance (cull radius, default 50),
--- dir, rot (xyz), bob, faceCamera, rotate, drawOnEnts, textureDict, textureName.
function Markers:add(opts)
    if type(opts) ~= 'table' then
        return false, ('options arrived as %s, not a table'):format(type(opts))
    end
    local x, y, z = xyz(opts.coords)
    if not x then
        return false, 'a marker needs coords: a vector3 or { x, y, z }'
    end
    local sx, sy, sz = xyz(opts.size or opts.scale or 1.0)
    if not sx then
        return false, 'size must be a number or an { x, y, z }'
    end
    local distance = num(opts.distance, DEFAULT_DISTANCE)
    if distance <= 0 then
        return false, ('distance must be greater than zero, got %s'):format(tostring(opts.distance))
    end
    local dx, dy, dz = xyz(opts.dir or 0.0)
    local rx, ry, rz = xyz(opts.rot or 0.0)
    local color = type(opts.color) == 'table' and opts.color or {}
    self.nextId = self.nextId + 1
    local id = self.nextId
    self.markers[id] = {
        kind = math.floor(num(opts.type, 1)),
        x = x, y = y, z = z,
        dx = dx or 0.0, dy = dy or 0.0, dz = dz or 0.0,
        rx = rx or 0.0, ry = ry or 0.0, rz = rz or 0.0,
        sx = sx + 0.0, sy = sy + 0.0, sz = sz + 0.0,
        r = math.floor(num(color.r or color[1], 255)),
        g = math.floor(num(color.g or color[2], 255)),
        b = math.floor(num(color.b or color[3], 255)),
        a = math.floor(num(color.a or color[4], 180)),
        bob = opts.bob == true,
        faceCamera = opts.faceCamera == true,
        rotate = opts.rotate == true,
        drawOnEnts = opts.drawOnEnts == true,
        textureDict = type(opts.textureDict) == 'string' and opts.textureDict or nil,
        textureName = type(opts.textureName) == 'string' and opts.textureName or nil,
        distance2 = distance * distance,
    }
    self.count = self.count + 1
    self:drive()
    return id
end

--- Remove one marker. Answers whether there was one.
function Markers:remove(id)
    if self.markers[id] == nil then
        return false
    end
    self.markers[id] = nil
    self.count = self.count - 1
    return true
end

--- Remove every marker; the thread ends on its next pass.
function Markers:clear()
    local n = self.count
    self.markers = {}
    self.count = 0
    return n
end

-- One frame. Answers the wait before the next one: 0 while anything is in range.
function Markers:pass()
    local coords = self.coordsOf()
    local px, py, pz = coords.x, coords.y, coords.z
    local drawn = 0
    for _, m in pairs(self.markers) do
        local ddx, ddy, ddz = m.x - px, m.y - py, m.z - pz
        if ddx * ddx + ddy * ddy + ddz * ddz <= m.distance2 then
            -- DRAW_MARKER: type, pos, dir, rot, scale, r, g, b, a, bobUpAndDown,
            -- faceCamera, p19 (2), rotate, textureDict, textureName, drawOnEnts.
            DrawMarker(m.kind, m.x, m.y, m.z, m.dx, m.dy, m.dz, m.rx, m.ry, m.rz,
                m.sx, m.sy, m.sz, m.r, m.g, m.b, m.a,
                m.bob, m.faceCamera, 2, m.rotate, m.textureDict, m.textureName, m.drawOnEnts)
            drawn = drawn + 1
        end
    end
    self.drawn = drawn
    return drawn > 0 and 0 or SLEEP_MS
end

-- THE THREAD EXISTS ONLY WHILE A MARKER DOES. Started by the first add, ended by
-- the pass after the last remove.
function Markers:drive()
    if self.driving then
        return
    end
    self.driving = true
    CreateThread(function()
        local tick = self.guard('marker.pass', function() return self:pass() end)
        while self.count > 0 do
            Wait(tick() or SLEEP_MS)
        end
        self.driving = false
    end)
end

M.SLEEP_MS = SLEEP_MS

return M
