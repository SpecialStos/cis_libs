-- Skill check. Blocking: true if every round was hit, false otherwise.
--
-- The game keeps input focus (no NUI focus, no cursor). A thread that exists
-- only while a check is active disables the check's keys for everything else
-- and forwards each press to the page, which owns the clock and the verdict
-- and reports the result once. The page cannot report for a check that is
-- not the active one: the id has to match.

local I = CisInterface

-- Key name -> control. Only keys with a stable keyboard control are offered.
local CONTROLS = {
    e = 38, q = 44, r = 45, f = 23, g = 47, w = 32, a = 34, s = 33, d = 35,
    ['1'] = 157, ['2'] = 158, ['3'] = 160, ['4'] = 164,
}
local ALSO_DISABLED = { 24, 25, 140, 141, 142, 257, 263 }
local PRESETS = { easy = true, medium = true, hard = true }
local MAX_ROUNDS = 20

local current = nil -- { id, owner, keys, p }

local function readRound(d)
    if type(d) == 'string' then
        return PRESETS[d] and d or nil
    end
    if type(d) == 'table' and tonumber(d.areaSize) and tonumber(d.speedMultiplier) then
        return {
            areaSize = I.num(d.areaSize, 5, 180),
            speedMultiplier = I.num(d.speedMultiplier, 0.25, 5),
        }
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
    local s = { id = I.nextId(), owner = owner, keys = keys, p = promise.new() }
    current = s
    I.send('skill:start', { id = s.id, rounds = rounds, keys = keys })
    CreateThread(function()
        while current == s do
            for i = 1, #ALSO_DISABLED do
                DisableControlAction(0, ALSO_DISABLED[i], true)
            end
            for _, key in ipairs(s.keys) do
                DisableControlAction(0, CONTROLS[key], true)
            end
            for _, key in ipairs(s.keys) do
                if IsDisabledControlJustPressed(0, CONTROLS[key]) then
                    I.send('skill:key', { key = key })
                    break
                end
            end
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

I.on('skill', { id = 'integer', success = 'boolean' }, function(data)
    if current and current.id == data.id then
        settle(current, data.success)
    end
end)

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

I.skillCheck = { start = skillCheck, active = skillCheckActive, cancel = cancelSkillCheck }
