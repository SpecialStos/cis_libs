-- Skill check. Blocking: true if every round was hit, false otherwise.
--
-- The game keeps input focus (no NUI focus, no cursor). A thread that exists
-- only while a check is active disables the check's keys for everything else,
-- reads each press, and JUDGES IT HERE. Lua makes every round (where the zone
-- is, which key), owns the clock, and decides hit or miss; the page is sent
-- the round and only draws it.
--
-- It used to be the page that judged, from its own clock, when a forwarded
-- press arrived -- a frame or more after the press -- and it reported the
-- result back. So the verdict lagged by a frame-rate-dependent amount, any
-- script that could post to cis_libs could report success, and a page that
-- never reported (a JavaScript error, a forged stop) left the thread disabling
-- attack and aim for good. Now nothing the page does can decide a check, and
-- the thread ends by itself: every round fails once the needle is past the
-- zone, at most one turn of the needle after it starts.

local I = CisInterface

-- Key name -> control. Only keys with a stable keyboard control are offered.
local CONTROLS = {
    e = 38, q = 44, r = 45, f = 23, g = 47, w = 32, a = 34, s = 33, d = 35,
    ['1'] = 157, ['2'] = 158, ['3'] = 160, ['4'] = 164,
}
local ALSO_DISABLED = { 24, 25, 140, 141, 142, 257, 263 }
local PRESETS = {
    easy = { areaSize = 50, speedMultiplier = 1 },
    medium = { areaSize = 40, speedMultiplier = 1.5 },
    hard = { areaSize = 25, speedMultiplier = 1.75 },
}
local MAX_ROUNDS = 20
-- One turn of the needle at speed 1.
local BASE_TURN_MS = 2000
-- A press is only SEEN at the next script frame, so each edge of the zone is
-- widened by the time that frame took (bounded, so a hitch is not a free hit).
local MAX_FRAME_MS = 34

local current = nil -- { id, owner, keys, rounds, index, round, p }

local function readRound(d)
    if type(d) == 'string' then
        local p = PRESETS[d]
        return p and { areaSize = p.areaSize, speedMultiplier = p.speedMultiplier } or nil
    end
    if type(d) == 'table' and tonumber(d.areaSize) and tonumber(d.speedMultiplier) then
        return {
            areaSize = I.num(d.areaSize, 5, 180),
            speedMultiplier = I.num(d.speedMultiplier, 0.25, 5),
        }
    end
    return nil
end

-- Where this round's zone sits and which key it wants. The zone never starts
-- in the first quarter turn, and always ends before the last 10 degrees.
local function makeRound(diff, keys)
    local size = diff.areaSize
    local lo = 90
    local hi = math.max(lo, 360 - size - 10)
    return {
        start = math.floor(lo + math.random() * (hi - lo) + 0.5),
        size = size,
        key = keys[math.random(1, #keys)],
        degPerMs = (360 / BASE_TURN_MS) * diff.speedMultiplier,
    }
end

-- 'hit', 'miss' or nil (still going) for the round at `angle` degrees, with
-- `slack` degrees of allowance on each edge, given the key pressed (or nil).
local function judge(round, angle, slack, key)
    if key ~= nil then
        if key ~= round.key then return 'miss' end
        if angle >= round.start - slack and angle <= round.start + round.size + slack then
            return 'hit'
        end
        return 'miss'
    end
    if angle > round.start + round.size + slack then
        return 'miss'
    end
    return nil
end

local function settle(s, success)
    if current ~= s then
        return false
    end
    current = nil
    I.send('skill:stop', { id = s.id })
    s.p:resolve(success == true)
    return true
end

local function startRound(s)
    s.round = makeRound(s.rounds[s.index], s.keys)
    s.t0 = GetGameTimer()
    I.send('skill:round', {
        id = s.id,
        index = s.index,
        count = #s.rounds,
        start = s.round.start,
        size = s.round.size,
        key = s.round.key,
        degPerMs = s.round.degPerMs,
    })
end

-- One frame of the active check: read the keys, judge, move on or finish.
local function frame(s, now, frameMs)
    for i = 1, #ALSO_DISABLED do
        DisableControlAction(0, ALSO_DISABLED[i], true)
    end
    for _, key in ipairs(s.keys) do
        DisableControlAction(0, CONTROLS[key], true)
    end
    local pressed
    for _, key in ipairs(s.keys) do
        if IsDisabledControlJustPressed(0, CONTROLS[key]) then
            pressed = key
            break
        end
    end
    local round = s.round
    local slack = round.degPerMs * math.min(math.max(frameMs, 0), MAX_FRAME_MS)
    local verdict = judge(round, (now - s.t0) * round.degPerMs, slack, pressed)
    if verdict == 'miss' then
        settle(s, false)
    elseif verdict == 'hit' then
        if s.index >= #s.rounds then
            settle(s, true)
        else
            s.index = s.index + 1
            startRound(s)
        end
    end
end

--- @param difficulty string|table  'easy' | 'medium' | 'hard', { areaSize, speedMultiplier }, or a list of those
--- @param inputs table|nil  key names, e.g. { 'w', 'a', 's', 'd' }; default { 'e' }
local function skillCheck(difficulty, inputs)
    local rounds = {}
    if type(difficulty) == 'table' and #difficulty > 0 then
        for i = 1, math.min(#difficulty, MAX_ROUNDS) do
            rounds[i] = readRound(difficulty[i])
            if not rounds[i] then
                return false, ('round %d is not a difficulty'):format(i)
            end
        end
    else
        rounds[1] = readRound(difficulty)
        if not rounds[1] then
            return false, "difficulty must be 'easy', 'medium', 'hard' or { areaSize, speedMultiplier }"
        end
    end
    local keys = {}
    if inputs ~= nil then
        if type(inputs) ~= 'table' then
            return false, 'inputs must be a list of key names'
        end
        for _, k in ipairs(inputs) do
            local key = type(k) == 'string' and k:lower() or nil
            if not key or not CONTROLS[key] then
                return false, ('%s is not a supported skill check key'):format(tostring(k))
            end
            keys[#keys + 1] = key
        end
    end
    if #keys == 0 then
        keys = { 'e' }
    end
    local owner = I.caller()
    if current then
        return false, 'a skill check is already active'
    end
    if not I.waitReady() or current then
        return false, current and 'a skill check is already active' or 'ui not ready'
    end
    local s = { id = I.nextId(), owner = owner, keys = keys, rounds = rounds, index = 1, p = promise.new() }
    current = s
    startRound(s)
    CreateThread(function()
        local last = GetGameTimer()
        while current == s do
            local now = GetGameTimer()
            frame(s, now, now - last)
            last = now
            Wait(0)
        end
    end)
    return Citizen.Await(s.p)
end

local function skillCheckActive()
    return current ~= nil
end

local function cancelSkillCheck()
    if not current then
        return false
    end
    return settle(current, false)
end

I.onStop(function(resource, all)
    if current and (all or current.owner == resource) then
        settle(current, false)
    end
end)

I.onReset(function()
    if current then settle(current, false) end
end)

exports('SkillCheck', skillCheck)
exports('SkillCheckActive', skillCheckActive)
exports('CancelSkillCheck', cancelSkillCheck)

I.skillCheck = { start = skillCheck, active = skillCheckActive, cancel = cancelSkillCheck, judge = judge }
