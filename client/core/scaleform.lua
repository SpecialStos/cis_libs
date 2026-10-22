-- Scaleform movies as objects: request by name, call methods with typed
-- parameters, draw fullscreen or in the world, dispose.
--
-- Consumer-side only (`Cis.scaleform.new`, loaded by init.lua from `files {}`).
-- A scaleform handle is per script and has to be drawn every frame by its owner,
-- so it can only live in the VM that draws it.
--
-- RELEASED. dispose() hands the movie back with SetScaleformMovieAsNoLongerNeeded,
-- and releaseAll() -- run by init.lua when the consumer stops -- does that for
-- every movie still held, so a stopped resource leaves no movie resident.
--
-- cfg: streaming (client/core/streaming.lua), guard(name, body) -> tick

local M = {}

local Factory = {}
Factory.__index = Factory

local Movie = {}
Movie.__index = Movie

function M.new(cfg)
    cfg = cfg or {}
    return setmetatable({
        streaming = cfg.streaming,
        guard = cfg.guard or function(_, body) return body end,
        live = {},
        nextId = 0,
    }, Factory)
end

--- Request a movie and wait for it. Answers the object, or nil and a reason.
function Factory:create(name, timeout)
    if type(name) ~= 'string' or name == '' then
        return nil, ('a scaleform is named by a non-empty string, got %s'):format(type(name))
    end
    local got, handleOrWhy = self.streaming.request('scaleform', name, timeout)
    if not got then
        return nil, handleOrWhy
    end
    self.nextId = self.nextId + 1
    local movie = setmetatable({
        id = self.nextId,
        name = name,
        handle = handleOrWhy,
        factory = self,
        drawing = false,
    }, Movie)
    self.live[movie.id] = movie
    return movie
end

--- Dispose every movie still held. Answers how many.
function Factory:releaseAll()
    local n = 0
    for _, movie in pairs(self.live) do
        if movie:dispose() then n = n + 1 end
    end
    return n
end

-- One parameter. A plain Lua value is typed by what it is -- an integer is an
-- int, any other number a float, a boolean a bool, a string a string -- and a
-- `{ type = 'int'|'float'|'bool'|'string'|'literal'|'playerName', value = v }`
-- says so explicitly, which is how `1.0` reaches a movie as a float on a runtime
-- that cannot tell 1.0 from 1.
local function pushParam(value)
    local kind, v = nil, value
    if type(value) == 'table' then
        kind, v = value.type, value.value
    elseif type(value) == 'number' then
        local mtype = math.type and math.type(value)
        if mtype == 'integer' or (mtype == nil and value % 1 == 0) then
            kind = 'int'
        else
            kind = 'float'
        end
    elseif type(value) == 'boolean' then
        kind = 'bool'
    elseif type(value) == 'string' then
        kind = 'string'
    end
    if kind == 'int' then
        ScaleformMovieMethodAddParamInt(math.floor(tonumber(v) or 0))
    elseif kind == 'float' then
        ScaleformMovieMethodAddParamFloat((tonumber(v) or 0) + 0.0)
    elseif kind == 'bool' then
        ScaleformMovieMethodAddParamBool(v and true or false)
    elseif kind == 'string' then
        ScaleformMovieMethodAddParamTextureNameString(tostring(v))
    elseif kind == 'literal' then
        ScaleformMovieMethodAddParamLiteralString(tostring(v))
    elseif kind == 'playerName' then
        ScaleformMovieMethodAddParamPlayerNameString(tostring(v))
    else
        return false, ('a scaleform parameter cannot be a %s'):format(type(value))
    end
    return true
end

--- Call a method on the movie. Answers true, or false and a reason; nothing is
--- sent when a parameter cannot be typed, so a half-built call never runs.
function Movie:call(method, ...)
    if not self.handle then
        return false, 'this scaleform was disposed'
    end
    if type(method) ~= 'string' or method == '' then
        return false, 'a method name is a non-empty string'
    end
    local n = select('#', ...)
    for i = 1, n do
        local v = select(i, ...)
        local t = type(v)
        if t ~= 'number' and t ~= 'boolean' and t ~= 'string'
            and not (t == 'table' and v.type ~= nil) then
            return false, ('parameter %d is a %s; use a number, boolean, string or { type, value }')
                :format(i, t)
        end
    end
    if not BeginScaleformMovieMethod(self.handle, method) then
        return false, ('the movie refused method %s'):format(method)
    end
    for i = 1, n do
        pushParam((select(i, ...)))
    end
    EndScaleformMovieMethod()
    return true
end

--- Draw over the whole screen for THIS frame. Call it every frame, or use
--- startDrawing().
function Movie:draw(r, g, b, a)
    if not self.handle then return false end
    DrawScaleformMovieFullscreen(self.handle, r or 255, g or 255, b or 255, a or 255, 0)
    return true
end

--- Draw in the world for THIS frame. coords, rot and scale are xyz.
function Movie:draw3d(coords, rot, scale)
    if not self.handle or coords == nil then return false end
    rot = rot or { x = 0.0, y = 0.0, z = 0.0 }
    scale = scale or { x = 1.0, y = 1.0, z = 1.0 }
    DrawScaleformMovie_3d(self.handle, coords.x + 0.0, coords.y + 0.0, coords.z + 0.0,
        rot.x + 0.0, rot.y + 0.0, rot.z + 0.0, 2.0, 2.0, 1.0,
        scale.x + 0.0, scale.y + 0.0, scale.z + 0.0, 2)
    return true
end

--- Draw fullscreen every frame on a thread of its own until stopDrawing() or
--- dispose(). A second call does not start a second thread.
function Movie:startDrawing(r, g, b, a)
    if not self.handle or self.drawing then
        return false
    end
    self.drawing = true
    CreateThread(function()
        local tick = self.factory.guard('scaleform.draw', function() return self:draw(r, g, b, a) end)
        while self.drawing and self.handle do
            tick()
            Wait(0)
        end
        self.drawing = false
    end)
    return true
end

function Movie:stopDrawing()
    self.drawing = false
end

--- Release the movie. Answers whether it was held.
function Movie:dispose()
    local handle = self.handle
    if not handle then
        return false
    end
    self.handle = nil
    self.drawing = false
    self.factory.live[self.id] = nil
    SetScaleformMovieAsNoLongerNeeded(handle)
    return true
end

return M
