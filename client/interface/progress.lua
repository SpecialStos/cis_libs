-- Progress bar and circle. Blocking: returns true on completion, false on
-- cancel or interruption.
--
-- ONE THREAD, AND ONLY WHILE ACTIVE. The per-frame work (disabled controls,
-- the cancel key, the interruption checks, re-applying an animation something
-- else stopped, the clock) runs in a thread started by the call and ended by
-- `finish`. Nothing runs when no progress is active.
--
-- EVERY EXIT PATH GOES THROUGH `finish`, and `finish` is the only thing that
-- cleans up: completion, the cancel key, CancelProgress, an interruption
-- (death, ragdoll, cuffs, falling, swimming), an error while starting, the
-- calling resource stopping, cis_libs stopping. Cleanup deletes every prop it
-- spawned and stops the animation or scenario it started, and it is
-- idempotent, so two exits racing cannot double-delete.

local I = CisInterface

local CONTROLS = {
    mouse = { 1, 2, 106 },
    move = { 21, 22, 30, 31, 36, 44 },
    sprint = { 21 },
    car = { 63, 64, 71, 72, 75 },
    combat = { 24, 25, 37, 47, 58, 140, 141, 142, 143, 257, 263, 264 },
}
-- INPUT_VEH_DUCK, X on a keyboard: the conventional cancel key.
local CANCEL_CONTROL = 73
local LOAD_TIMEOUT = 3000
local DEFAULT_BONE = 60309

local current = nil

local function vec(v)
    if type(v) == 'table' or type(v) == 'vector3' then
        return tonumber(v.x) or 0.0, tonumber(v.y) or 0.0, tonumber(v.z) or 0.0
    end
    return 0.0, 0.0, 0.0
end

local function interrupted(s, ped)
    if not s.useWhileDead and IsEntityDead(ped) then return 'dead' end
    if not s.allowRagdoll and IsPedRagdoll(ped) then return 'ragdoll' end
    if not s.allowCuffed and IsPedCuffed(ped) then return 'cuffed' end
    if not s.allowFalling and IsPedFalling(ped) then return 'falling' end
    if not s.allowSwimming and IsPedSwimming(ped) then return 'swimming' end
    return nil
end

-- A dictionary that is not in the game (a typo, or one from a pack that is
-- not streamed) is refused at once: RequestAnimDict on it never loads, and the
-- action used to sit on a frozen ped for the whole LOAD_TIMEOUT.
local function loadDict(dict)
    if not DoesAnimDictExist(dict) then
        I.log('warn', ('progress: animation dictionary %s does not exist'):format(dict))
        return false
    end
    RequestAnimDict(dict)
    local deadline = GetGameTimer() + LOAD_TIMEOUT
    while not HasAnimDictLoaded(dict) and GetGameTimer() < deadline do
        Wait(0)
    end
    return HasAnimDictLoaded(dict)
end

local function loadModel(hash)
    if not IsModelValid(hash) then
        return false
    end
    RequestModel(hash)
    local deadline = GetGameTimer() + LOAD_TIMEOUT
    while not HasModelLoaded(hash) and GetGameTimer() < deadline do
        Wait(0)
    end
    return HasModelLoaded(hash)
end

local function playAnim(s, ped)
    local a = s.anim
    TaskPlayAnim(ped, a.dict, a.clip, a.blendIn, a.blendOut, a.duration, a.flag, a.playbackRate,
        a.lockX, a.lockY, a.lockZ)
end

local function startAnim(s, ped)
    local a = s.anim
    if a.scenario then
        TaskStartScenarioInPlace(ped, a.scenario, 0, a.playEnter)
        s.scenarioStarted = true
    elseif loadDict(a.dict) and current == s then
        playAnim(s, ped)
        s.animStarted = true
    end
end

local function spawnProps(s, ped)
    for _, p in ipairs(s.props) do
        if current ~= s then return end
        local hash = type(p.model) == 'string' and joaat(p.model) or p.model
        if loadModel(hash) and current == s then
            local c = GetEntityCoords(ped)
            local obj = CreateObject(hash, c.x, c.y, c.z + 0.2, true, true, true)
            -- Recorded before anything else can fail, so cleanup sees it.
            s.spawned[#s.spawned + 1] = obj
            local px, py, pz = vec(p.pos)
            local rx, ry, rz = vec(p.rot)
            AttachEntityToEntity(obj, ped, GetPedBoneIndex(ped, p.bone), px, py, pz, rx, ry, rz,
                true, true, false, true, p.rotOrder, true)
            SetModelAsNoLongerNeeded(hash)
        end
    end
end

-- Safe to call more than once: props are deleted every time (a load that was
-- in flight when the progress ended may have spawned one since), the task is
-- stopped once.
local function cleanup(s)
    local ped = PlayerPedId()
    for i = 1, #s.spawned do
        local obj = s.spawned[i]
        if DoesEntityExist(obj) then
            DetachEntity(obj, true, true)
            DeleteEntity(obj)
        end
    end
    s.spawned = {}
    if s.taskStopped then
        return
    end
    s.taskStopped = true
    if s.scenarioStarted then
        ClearPedTasks(ped)
    elseif s.animStarted then
        StopAnimTask(ped, s.anim.dict, s.anim.clip, 1.0)
        RemoveAnimDict(s.anim.dict)
    end
end

local function finish(s, completed)
    if current ~= s then
        return false
    end
    current = nil
    local ok, err = pcall(cleanup, s)
    if not ok then
        I.log('error', ('progress cleanup raised: %s'):format(tostring(err)))
    end
    I.send('progress:stop', { completed = completed })
    s.p:resolve(completed)
    return true
end

-- One frame of an active progress.
local function frame(s)
    local ped = PlayerPedId()
    if interrupted(s, ped) then
        return finish(s, false)
    end
    if s.canCancel and IsControlJustPressed(0, CANCEL_CONTROL) then
        return finish(s, false)
    end
    if GetGameTimer() >= s.endsAt then
        return finish(s, true)
    end
    for i = 1, #s.controls do
        DisableControlAction(0, s.controls[i], true)
    end
    if s.disableCombat then
        DisablePlayerFiring(PlayerId(), true)
    end
    if s.animStarted and not IsEntityPlayingAnim(ped, s.anim.dict, s.anim.clip, 3) then
        playAnim(s, ped)
    end
end

local function readAnim(anim)
    if type(anim) ~= 'table' then
        return nil
    end
    if type(anim.scenario) == 'string' and anim.scenario ~= '' then
        return { scenario = anim.scenario, playEnter = anim.playEnter ~= false }
    end
    if type(anim.dict) ~= 'string' or type(anim.clip) ~= 'string' then
        return nil
    end
    return {
        dict = anim.dict,
        clip = anim.clip,
        flag = math.floor(I.num(anim.flag, 0, 0x7FFFFFFF, 49)),
        blendIn = I.num(anim.blendIn, 0, 100, 3.0),
        blendOut = I.num(anim.blendOut, 0, 100, 1.0),
        duration = math.floor(I.num(anim.duration, -1, 0x7FFFFFFF, -1)),
        playbackRate = I.num(anim.playbackRate, 0, 1, 0),
        lockX = anim.lockX == true,
        lockY = anim.lockY == true,
        lockZ = anim.lockZ == true,
    }
end

local function readProps(prop)
    if type(prop) ~= 'table' then
        return {}
    end
    local list = (prop.model ~= nil) and { prop } or prop
    local out = {}
    for _, p in ipairs(list) do
        if type(p) == 'table' and (type(p.model) == 'string' or type(p.model) == 'number') and #out < 8 then
            out[#out + 1] = {
                model = p.model,
                bone = math.floor(I.num(p.bone, 0, 0xFFFF, DEFAULT_BONE)),
                pos = p.pos,
                rot = p.rot,
                rotOrder = math.floor(I.num(p.rotOrder, 0, 5, 0)),
            }
        end
    end
    return out
end

local function readControls(disable)
    local list, seen, combat = {}, {}, false
    if type(disable) == 'table' then
        for group, ids in pairs(CONTROLS) do
            if disable[group] == true then
                combat = combat or group == 'combat'
                for _, id in ipairs(ids) do
                    if not seen[id] then
                        seen[id] = true
                        list[#list + 1] = id
                    end
                end
            end
        end
    end
    table.sort(list)
    return list, combat
end

local function run(kind, data)
    if type(data) ~= 'table' then
        return false, ('progress needs a table, got %s'):format(type(data))
    end
    local duration = I.num(data.duration, 0, 3600000)
    if not duration then
        return false, 'progress needs a duration in milliseconds'
    end
    -- The bar is the only sign an action is running: without the page it would
    -- freeze the ped for the whole duration with nothing on screen.
    if not I.waitReady() then
        return false, 'ui not ready'
    end
    if current then
        return false, 'a progress is already running'
    end
    local controls, combat = readControls(data.disable)
    local s = {
        owner = I.caller(),
        duration = math.floor(duration),
        useWhileDead = data.useWhileDead == true,
        allowRagdoll = data.allowRagdoll == true,
        allowCuffed = data.allowCuffed == true,
        allowFalling = data.allowFalling == true,
        allowSwimming = data.allowSwimming == true,
        canCancel = data.canCancel == true,
        anim = readAnim(data.anim),
        props = readProps(data.prop),
        spawned = {},
        controls = controls,
        disableCombat = combat,
        p = promise.new(),
    }
    local ped = PlayerPedId()
    if interrupted(s, ped) then
        return false, 'interrupted'
    end
    -- Claimed BEFORE anything waits, so a second call while the dictionary
    -- loads is refused rather than racing this one.
    current = s
    local ok, err = pcall(function()
        if s.anim then startAnim(s, ped) end
        if #s.props > 0 then spawnProps(s, ped) end
    end)
    if not ok then
        I.log('error', ('progress start raised: %s'):format(tostring(err)))
        finish(s, false)
        return false, 'progress failed to start'
    end
    if current ~= s then
        -- Cancelled (or its owner stopped) while loading. finish already ran;
        -- this sweeps anything that finished loading after it.
        cleanup(s)
        return false, 'cancelled'
    end
    s.endsAt = GetGameTimer() + s.duration
    I.send('progress:start', {
        kind = kind,
        label = I.str(data.label, 256),
        duration = s.duration,
        position = (data.position == 'middle' or data.position == 'bottom') and data.position
            or I.defaults.progressPosition,
        canCancel = s.canCancel,
    })
    CreateThread(function()
        while current == s do
            frame(s)
            Wait(0)
        end
    end)
    return Citizen.Await(s.p)
end

--- @param data table  { duration, label, position, useWhileDead, allowRagdoll, allowCuffed,
---   allowFalling, allowSwimming, canCancel, anim, prop, disable }
local function progressBar(data)
    return run('bar', data)
end

local function progressCircle(data)
    return run('circle', data)
end

local function progressActive()
    return current ~= nil
end

local function cancelProgress()
    if not current then
        return false
    end
    return finish(current, false)
end

I.onStop(function(resource, all)
    if current and (all or current.owner == resource) then
        finish(current, false)
    end
end)

exports('ProgressBar', progressBar)
exports('ProgressCircle', progressCircle)
exports('ProgressActive', progressActive)
exports('CancelProgress', cancelProgress)

I.progress = { bar = progressBar, circle = progressCircle, active = progressActive, cancel = cancelProgress }
