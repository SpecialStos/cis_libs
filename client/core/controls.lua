-- Controls disabled every frame while anybody holds them -- REFCOUNTED.
--
-- Consumer-side only (`Cis.controls.*`, loaded by init.lua from `files {}`).
-- DisableControlAction lasts one frame, so it has to be issued every frame by
-- the VM that wants it, and two features of one resource that both disable
-- "attack" must not have the first one's release re-enable it for the second.
-- Each disable() is a hold; a control stays disabled while any hold names it.
--
-- ONE THREAD, and only while a hold exists. No allocation per frame: the pass
-- walks a count table and calls one native per held control.
--
-- cfg: guard(name, body) -> tick

local M = {}

local Controls = {}
Controls.__index = Controls

function M.new(cfg)
    cfg = cfg or {}
    return setmetatable({
        guard = cfg.guard or function(_, body) return body end,
        -- control -> how many holds name it
        counts = {},
        -- hold id -> the list of controls it holds
        holds = {},
        holdCount = 0,
        nextId = 0,
        driving = false,
    }, Controls)
end

--- Hold one or more controls disabled. Accepts numbers or one list of numbers:
--- disable(24, 25) or disable({ 24, 25 }). Answers a hold id, or false and a reason.
function Controls:disable(...)
    local list = ...
    if type(list) ~= 'table' then
        list = { ... }
    end
    local controls = {}
    for i = 1, #list do
        local c = list[i]
        if type(c) ~= 'number' or c ~= c or c < 0 or c % 1 ~= 0 then
            return false, ('control %d is %s; a control is a non-negative integer'):format(i, tostring(c))
        end
        controls[#controls + 1] = c
    end
    if #controls == 0 then
        return false, 'no controls were named'
    end
    self.nextId = self.nextId + 1
    local id = self.nextId
    self.holds[id] = controls
    self.holdCount = self.holdCount + 1
    local counts = self.counts
    for i = 1, #controls do
        counts[controls[i]] = (counts[controls[i]] or 0) + 1
    end
    self:drive()
    return id
end

--- Release a hold. A control is enabled again once no hold names it.
function Controls:enable(id)
    local controls = self.holds[id]
    if not controls then
        return false
    end
    self.holds[id] = nil
    self.holdCount = self.holdCount - 1
    local counts = self.counts
    for i = 1, #controls do
        local c = controls[i]
        local n = (counts[c] or 1) - 1
        counts[c] = n > 0 and n or nil
    end
    return true
end

--- Whether a control is held disabled right now.
function Controls:isDisabled(control)
    return (self.counts[control] or 0) > 0
end

function Controls:pass()
    for control in pairs(self.counts) do
        DisableControlAction(0, control, true)
    end
    return 0
end

function Controls:drive()
    if self.driving then
        return
    end
    self.driving = true
    CreateThread(function()
        local tick = self.guard('controls.pass', function() return self:pass() end)
        while self.holdCount > 0 do
            tick()
            Wait(0)
        end
        self.driving = false
    end)
end

return M
