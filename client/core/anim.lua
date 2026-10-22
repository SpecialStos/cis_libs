-- Play an animation, with the dictionary requested AND released.
--
-- Consumer-side only (`Cis.anim.play`, loaded by init.lua from `files {}`).
--
-- THE DICTIONARY IS RELEASED as soon as the task holds it. TaskPlayAnim takes its
-- own reference, so keeping the request alive after the call only pins a
-- dictionary in memory for the rest of the session -- one per animation a
-- resource ever played. ox_lib's playAnim does the same.
--
-- cfg: streaming (client/core/streaming.lua)

local M = {}

local Anim = {}
Anim.__index = Anim

function M.new(cfg)
    cfg = cfg or {}
    return setmetatable({ streaming = cfg.streaming }, Anim)
end

local function float(v, fallback)
    if type(v) == 'number' and v == v then
        return v + 0.0
    end
    return fallback
end

--- Play `clip` from `dict` on `ped`. opts: blendIn (8.0), blendOut (-8.0),
--- duration (-1), flag (0), playbackRate (0.0), lockX/lockY/lockZ (false),
--- timeout (ms for the dictionary request).
--- Answers true, or false and a reason.
function Anim:play(ped, dict, clip, opts)
    if type(ped) ~= 'number' or ped == 0 then
        return false, ('a ped handle is a non-zero number, got %s'):format(tostring(ped))
    end
    if type(dict) ~= 'string' or dict == '' then
        return false, 'an animation dictionary is a non-empty string'
    end
    if type(clip) ~= 'string' or clip == '' then
        return false, 'an animation clip is a non-empty string'
    end
    opts = type(opts) == 'table' and opts or {}
    local got, why = self.streaming.request('animDict', dict, opts.timeout)
    if not got then
        return false, why
    end
    TaskPlayAnim(ped, dict, clip,
        float(opts.blendIn, 8.0), float(opts.blendOut, -8.0),
        math.floor(tonumber(opts.duration) or -1), math.floor(tonumber(opts.flag) or 0),
        float(opts.playbackRate, 0.0),
        opts.lockX == true, opts.lockY == true, opts.lockZ == true)
    -- Released here, not later: the task holds what it needs.
    RemoveAnimDict(dict)
    return true
end

return M
