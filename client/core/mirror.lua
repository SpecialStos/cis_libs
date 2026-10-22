-- The player-cache MIRROR, in a consumer's own VM.
--
-- cis_libs stays the single PRODUCER of player state: client/cache.lua makes one
-- native pass per client and keeps the only real cache. This file is the
-- consumer half. It takes ONE snapshot through one export on first use, then
-- follows every change cis_libs pushes as the local client event
-- `cis_libs:cache`, so `Cis.player.vehicle()` and friends read a local table and
-- cross nothing -- however often they are called.
--
-- Loaded only by init.lua, only in a consumer, only on the first player read or
-- listener: a resource that never asks pays for nothing. Not a client_script,
-- because cis_libs' own VM reads CisCache directly.
--
-- cfg:
--   resource      the producer's name ('cis_libs')
--   self          the consumer's own name
--   snapshot()    -> table|nil   the one export call
--   follow()      asks the producer to push heading (FollowCacheHeading)
--   heading()     -> number      the native read, while nothing follows it
--   log(level, message)

local M = {}

local EVENT = 'cis_libs:cache'

-- What may be listened to, and read. A typo is refused rather than accepted into
-- a list that never fires -- the same rule the producer applies.
local KEYS = {
    ped = true, heading = true, vehicle = true, seat = true, weapon = true,
    armed = true, aiming = true, shooting = true, playerId = true, serverId = true,
}
local KEY_LIST = 'aiming, armed, heading, ped, playerId, seat, serverId, shooting, vehicle and weapon'

-- A failed snapshot (cis_libs stopped, or not yet started) is retried at most
-- this often, so a read in a Wait(0) loop does not become an export per frame.
local RETRY_MS = 1000

local Mirror = {}
Mirror.__index = Mirror

local function noop() end

function M.new(cfg)
    local self = setmetatable({
        resource = cfg.resource,
        selfName = cfg.self,
        takeSnapshot = cfg.snapshot,
        follow = cfg.follow or noop,
        readHeading = cfg.heading,
        followingHeading = false,
        log = cfg.log or noop,
        values = {},
        snapped = false,
        lastTry = nil,
        listeners = {},
        listenerKey = {},
        seq = 0,
        snapshots = 0,
    }, Mirror)

    -- THE PUSH. Applied only when it comes from the producer: any client resource
    -- can TriggerEvent this name, and a forged vehicle in the mirror would be a
    -- forged vehicle in every consumer. A string invoker that is neither the
    -- producer nor this resource is refused.
    AddEventHandler(EVENT, function(key, value, seat, silent)
        local from = GetInvokingResource()
        if type(from) == 'string' and from ~= self.resource and from ~= self.selfName then
            return
        end
        self:apply(key, value, seat, silent)
    end)

    -- A RESTART OF THE PRODUCER re-snapshots. Its first pass then pushes every
    -- value that differs from its defaults, so the mirror converges either way.
    AddEventHandler('onClientResourceStart', function(resource)
        if resource == self.resource then
            self.snapped = false
            self.lastTry = nil
            -- A restarted producer has forgotten who follows the heading.
            if self.followingHeading then
                pcall(self.follow)
            end
            self:ensure()
        end
    end)
    -- While the producer is down nothing is pushed, so the mirror stops claiming
    -- to know: the next read retries a snapshot (throttled) and answers the
    -- fallback meanwhile.
    AddEventHandler('onResourceStop', function(resource)
        -- A real stop comes from the engine, with no script below this handler;
        -- one TriggerEvent'd by another script is ignored (shared/owned.lua).
        local by = GetInvokingResource()
        if resource == self.resource and (by == nil or by == resource) then
            self.snapped = false
            self.lastTry = nil
        end
    end)
    return self
end

function Mirror:emit(key, current, previous)
    local list = self.listeners[key]
    if not list then
        return
    end
    for i = 1, #list do
        local ok, err = pcall(list[i].cb, current, previous)
        if not ok then
            self.log('error', ('cache listener %s: %s'):format(key, tostring(err)))
        end
    end
end

-- One pushed change. `seat` rides on a 'vehicle' push so the two land together:
-- a vehicle listener reading the seat must see the NEW seat, which is the
-- ordering the producer guarantees and a second event could not. `silent` is a
-- value refresh with no change worth announcing (the same weapon, new ammo).
function Mirror:apply(key, value, seat, silent)
    if not KEYS[key] then
        return
    end
    local values = self.values
    if key == 'vehicle' then
        local prevVehicle, prevSeat = values.vehicle, values.seat
        values.vehicle = value
        values.seat = seat
        if prevVehicle ~= value then
            self:emit('vehicle', value, prevVehicle)
        end
        if prevSeat ~= seat then
            self:emit('seat', seat, prevSeat)
        end
        return
    end
    local previous = values[key]
    values[key] = value
    if not silent and previous ~= value then
        self:emit(key, value, previous)
    end
end

-- The snapshot, at most once per RETRY_MS while it keeps failing. Answers
-- whether the mirror now holds the producer's values.
function Mirror:ensure()
    if self.snapped then
        return true
    end
    local now = GetGameTimer()
    if self.lastTry ~= nil and now - self.lastTry < RETRY_MS then
        return false
    end
    self.lastTry = now
    local ok, snap = pcall(self.takeSnapshot)
    if not ok or type(snap) ~= 'table' then
        return false
    end
    self.snapped = true
    self.snapshots = self.snapshots + 1
    -- Through apply(), so a re-snapshot after a producer restart tells the
    -- listeners about every value that moved while it was down.
    self:apply('vehicle', snap.vehicle, snap.seat, false)
    for key in pairs(KEYS) do
        if key ~= 'vehicle' and key ~= 'seat' then
            self:apply(key, snap[key], nil, false)
        end
    end
    return true
end

-- NIL WHILE THE PRODUCER IS DOWN. The values are kept, so the re-snapshot after
-- a restart tells listeners only what moved, but they are not answered: a
-- mirror that went on returning the last vehicle handle while cis_libs was
-- stopped claimed a car the player may have left minutes ago.
function Mirror:get(key)
    -- Not pushed unless something listens for it, so read where it lives.
    if key == 'heading' and not self.followingHeading and self.readHeading then
        return self.readHeading()
    end
    if not self.snapped and not self:ensure() then
        return nil
    end
    return self.values[key]
end

--- Subscribe to one key. Answers the unsubscribe function and an id, or nil and
--- a reason. A real function, because it never crosses anything.
function Mirror:on(key, cb)
    if not KEYS[key] then
        return nil, ('unknown cache key %s; valid keys are %s'):format(tostring(key), KEY_LIST)
    end
    if type(cb) ~= 'function' and not (type(cb) == 'table' and rawget(cb, '__cfx_functionReference') ~= nil) then
        return nil, ('a listener must be a function, got %s'):format(type(cb))
    end
    -- A listener is only told about changes it can see, so the mirror has to be
    -- following the producer from now on.
    self:ensure()
    if key == 'heading' and not self.followingHeading then
        self.followingHeading = pcall(self.follow)
    end
    self.seq = self.seq + 1
    local id = self.seq
    local old = self.listeners[key] or {}
    -- Replaced, never edited in place: an emit walking the old array is not
    -- disturbed by a listener that unsubscribes from inside its own callback.
    local list = {}
    for i = 1, #old do list[i] = old[i] end
    list[#list + 1] = { id = id, cb = cb }
    self.listeners[key] = list
    self.listenerKey[id] = key
    return function() return self:off(id) end, id
end

function Mirror:off(id)
    local key = self.listenerKey[id]
    if not key then
        return false
    end
    self.listenerKey[id] = nil
    local old = self.listeners[key] or {}
    local list = {}
    for i = 1, #old do
        if old[i].id ~= id then list[#list + 1] = old[i] end
    end
    self.listeners[key] = list
    return true
end

M.EVENT = EVENT
M.KEYS = KEYS

return M
