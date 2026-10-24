-- State bag watchers that hand you the ENTITY (or the player), not the bag name.
--
-- A bag name is `entity:<netId>`, `localEntity:<handle>` or `player:<serverId>`.
-- None of those numbers is an entity handle on a client: a netId handed to
-- DoesEntityExist names some unrelated script handle, or nothing. So the bag is
-- RESOLVED, with the natives that exist for exactly this:
--   GetEntityFromStateBagName  -- entity and localEntity bags; 0 until the entity
--                                 exists in this VM
--   GetPlayerFromStateBagName  -- the source on the server, a player HANDLE on a
--                                 client
--
-- A client often hears about a bag before the entity has been created locally
-- (the bag replicates with the entity's creation, and the handler can run first).
-- Those changes wait in ONE bounded queue, coalesced per watcher and bag so the
-- newest value wins, drained by ONE thread that exists only while the queue is
-- non-empty. The old shape was a polling coroutine per change: a busy key on a
-- busy server stacked them without limit.

local IS_SERVER = IsDuplicityVersion()

local DEFAULT_WAIT_MS = 2000
local STEP_MS = 50
-- The most changes waiting for an entity at once. The oldest is dropped (and
-- counted) past this, so churn on entities this client never streams cannot grow
-- the queue without bound.
local MAX_PENDING = 256

-- cookie -> { key, handler, owner, resolve, timeoutMs }
local watchers = {}
local owned = CisOwned.new()

-- slot -> entry; slot is cookie .. '\0' .. bagName.
local pending = {}
local pendingCount = 0
local pendingSeq = 0
local pumping = false
local stats = { dropped = 0, expired = 0, raised = 0 }

local function log(level, message)
    if CisLog then
        CisLog(level, message)
    end
end

-- A player bag: the server id on either side. The client native answers a HANDLE,
-- which is turned back into the server id the handler is documented to take; a
-- player this client does not know (out of scope) still has the id its bag name
-- carries, and the name format is the documented one.
local function playerFromBag(bagName)
    if type(bagName) ~= 'string' or bagName:sub(1, 7) ~= 'player:' then
        return nil
    end
    local p = GetPlayerFromStateBagName(bagName)
    if IS_SERVER then
        p = tonumber(p)
        return (p and p > 0) and p or nil
    end
    if type(p) == 'number' and p >= 0 then
        local sid = GetPlayerServerId(p)
        if type(sid) == 'number' and sid > 0 then
            return sid
        end
    end
    local parsed = tonumber(bagName:match('^player:(%d+)$'))
    return (parsed and parsed > 0) and parsed or nil
end

-- An entity bag resolves to the entity; a PLAYER bag resolves to that player's
-- ped, which is the entity a watcher asking for entities wants. nil means "not in
-- this VM yet" and is retried until the watcher's deadline.
local function entityFromBag(bagName)
    if type(bagName) ~= 'string' then
        return nil
    end
    if bagName:sub(1, 7) == 'player:' then
        local ped
        if IS_SERVER then
            local src = playerFromBag(bagName)
            ped = src and GetPlayerPed(src)
        else
            local handle = GetPlayerFromStateBagName(bagName)
            ped = (type(handle) == 'number' and handle >= 0) and GetPlayerPed(handle) or nil
        end
        return (type(ped) == 'number' and ped ~= 0) and ped or nil
    end
    local entity = GetEntityFromStateBagName(bagName)
    if type(entity) == 'number' and entity ~= 0 then
        return entity
    end
    return nil
end

local function deliver(cookie, w, target, value, replicated)
    -- A delete is a change to nil. That is what the runtime sends for
    -- `state:set(key, nil)`, and it is the only shape a delete has.
    local ok, err = pcall(w.handler, target, value, replicated, value == nil)
    if not ok then
        stats.raised = stats.raised + 1
        log('error', ('cis_libs: statebag %s handler (watcher %s, owner %s) raised: %s')
            :format(w.key, tostring(cookie), tostring(w.owner), tostring(err)))
    end
end

local function unpend(slot)
    if pending[slot] then
        pending[slot] = nil
        pendingCount = pendingCount - 1
    end
end

local function dropOldest()
    local oldestSlot, oldestSeq
    for slot, e in pairs(pending) do
        if not oldestSeq or e.seq < oldestSeq then
            oldestSlot, oldestSeq = slot, e.seq
        end
    end
    if oldestSlot then
        unpend(oldestSlot)
        stats.dropped = stats.dropped + 1
    end
end

-- ONE drain loop for every watcher. Ready entries are collected first and handled
-- after the walk, because a handler can yield or set a bag itself, and neither
-- may happen in the middle of a `pairs` over the table it changes.
local function pump()
    while pendingCount > 0 do
        Wait(STEP_MS)
        local now = GetGameTimer()
        local ready = nil
        for slot, e in pairs(pending) do
            local w = watchers[e.cookie]
            if not w then
                ready = ready or {}
                ready[#ready + 1] = { slot = slot }
            else
                local target = w.resolve(e.bagName)
                if target then
                    ready = ready or {}
                    ready[#ready + 1] = { slot = slot, e = e, w = w, target = target }
                elseif now >= e.deadline then
                    ready = ready or {}
                    ready[#ready + 1] = { slot = slot, expired = true, e = e, w = w }
                end
            end
        end
        if ready then
            for i = 1, #ready do
                local r = ready[i]
                -- Only if the slot still holds THIS entry: a newer value for the same
                -- bag may have replaced it while an earlier handler ran.
                if r.e == nil or pending[r.slot] == r.e then
                    unpend(r.slot)
                    if r.expired then
                        stats.expired = stats.expired + 1
                        log('warn', ('cis_libs: statebag %s on %s: the entity did not exist after %dms; '
                            .. 'the bag replicated for something this client never streamed')
                            :format(r.w.key, tostring(r.e.bagName), r.w.timeoutMs))
                    elseif r.e then
                        deliver(r.e.cookie, r.w, r.target, r.e.value, r.e.replicated)
                    end
                end
            end
        end
    end
    pumping = false
end

local function enqueue(cookie, w, bagName, value, replicated)
    local slot = cookie .. '\0' .. bagName
    if not pending[slot] then
        if pendingCount >= MAX_PENDING then
            dropOldest()
        end
        pendingCount = pendingCount + 1
    end
    pendingSeq = pendingSeq + 1
    pending[slot] = {
        cookie = cookie, bagName = bagName, value = value, replicated = replicated,
        deadline = GetGameTimer() + w.timeoutMs, seq = pendingSeq,
    }
    if not pumping then
        pumping = true
        CreateThread(pump)
    end
end

local function watch(key, handler, resolve, timeoutMs, waits)
    if type(key) ~= 'string' or key == '' then
        return nil, ('key must be a non-empty string; the "*" wildcard is allowed: got %s'):format(tostring(key))
    end
    if not CisCallable(handler) then
        return nil, ('handler must be a function; got %s'):format(type(handler))
    end
    local wait = tonumber(timeoutMs) or DEFAULT_WAIT_MS
    if wait ~= wait or wait < 0 then
        wait = DEFAULT_WAIT_MS
    end

    local w = {
        key = key, handler = handler, resolve = resolve, timeoutMs = math.floor(wait),
        owner = GetInvokingResource() or 'cis_libs',
    }
    local cookie
    -- `*` is this API's wildcard; the native's is an absent filter, exactly as
    -- the bag filter is (the documented idiom passes nil for both). Passing `*`
    -- through would watch a key literally named `*`.
    local filter = key ~= '*' and key or nil
    cookie = AddStateBagChangeHandler(filter, nil, function(bagName, _key, value, _reserved, replicated)
        if watchers[cookie] ~= w then
            return
        end
        local target = resolve(bagName)
        if target then
            -- A newer value supersedes one still waiting for the same bag.
            unpend(cookie .. '\0' .. tostring(bagName))
            deliver(cookie, w, target, value, replicated)
        elseif waits and type(bagName) == 'string' then
            enqueue(cookie, w, bagName, value, replicated)
        end
    end)
    watchers[cookie] = w
    CisOwned.track(owned, w.owner, 'statebag', cookie)
    return cookie
end

-- The server holds every entity, so a bag that does not resolve there is gone
-- rather than late: only a client waits.
function CisStatebagOnEntity(key, handler, timeoutMs)
    return watch(key, handler, entityFromBag, timeoutMs, not IS_SERVER)
end

-- A player's server id is known from the bag on either side, so nothing waits.
function CisStatebagOnPlayer(key, handler, timeoutMs)
    return watch(key, handler, playerFromBag, timeoutMs, false)
end

local function release(cookie)
    watchers[cookie] = nil
    CisOwned.forget(owned, 'statebag', cookie)
    local prefix = tostring(cookie) .. '\0'
    for slot in pairs(pending) do
        if slot:sub(1, #prefix) == prefix then
            unpend(slot)
        end
    end
    RemoveStateBagChangeHandler(cookie)
end

-- A watcher belongs to the resource that registered it. Its handler is a function
-- reference INTO that resource, which dies with it: a watcher left behind raises
-- on every change for the rest of the session.
-- A forged stop is ignored on either realm (CisOnResourceStop, shared/owned.lua).
CisOnResourceStop(function(resource)
    local freed = CisOwned.release(owned, resource)
    for i = 1, #freed do
        if freed[i].kind == 'statebag' then
            release(freed[i].id)
        end
    end
end)

-- Per realm: Collect runs the probes registered for the realm it is asked about.
if CisDiagnostics and CisDiagnostics.Register then
    CisDiagnostics.Register(IS_SERVER and 'server' or 'client', 'statebag', function()
        local n = 0
        for _ in pairs(watchers) do n = n + 1 end
        return {
            watchers = n, pending = pendingCount, dropped = stats.dropped,
            expired = stats.expired, raised = stats.raised,
        }
    end)
end

exports('StatebagOnEntity', CisStatebagOnEntity)
exports('StatebagOnPlayer', CisStatebagOnPlayer)
exports('RemoveStatebagHandler', function(cookie)
    if type(cookie) ~= 'number' then
        return false, ('cookie must be the number the watcher returned; got %s'):format(type(cookie))
    end
    local w = watchers[cookie]
    if not w then
        return false, ('no watcher with cookie %s'):format(tostring(cookie))
    end
    local who = GetInvokingResource() or 'cis_libs'
    if w.owner ~= who and who ~= 'cis_libs' then
        return false, 'not the owner'
    end
    release(cookie)
    return true
end)
