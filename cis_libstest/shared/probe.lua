-- Boundary probes.
--
-- Everything here exists because a behaviour was DOCUMENTED but never MEASURED.
-- Each probe records what actually arrived, so the report states the truth
-- rather than repeating an assumption. A probe that disagrees with the
-- documented model FAILS, because that disagreement is the finding.
--
-- The important one is `CisTestProbe.binding`. Defect 9.3 asks whether
-- `exports[resource][name]` yields an unbound method (as `exports[resource][name](...)`
-- does) or an already-bound callable reference. Nobody has measured it, and
-- cis_libs's remote-handler dispatch path depends on the answer.

CisTestProbe = {}

-- Every export below records its arguments and returns a summary. Registered
-- on the cis_libstest resource, so cis_libs reaches them as a remote handler.
local function recorder(name)
    return function(...)
        local n = select('#', ...)
        local flat = { n = n, name = name }
        for i = 1, n do
            flat[i] = select(i, ...)
        end
        return flat
    end
end

-- Raw capture for tests that need to inspect rather than round-trip.
CisTestProbe.last = nil

local captures = {}

-- Under fengari there is no FiveM runtime. Provide a no-op registration
-- target so this module still loads and its pure helpers stay unit-testable
-- in CI. In a real runtime `exports` already exists and is left untouched.
if type(exports) ~= 'table' then
    exports = setmetatable({}, {
        -- both call forms appear: exports('name', fn) and exports[res][name](...)
        __call = function() return true end,
        __index = function() return function() end end,
    })
end

exports('cis_test:capture', function(...)
    local n = select('#', ...)
    local flat = { n = n }
    for i = 1, n do
        flat[i] = select(i, ...)
    end
    captures[#captures + 1] = flat
    CisTestProbe.last = flat
    return flat
end)

exports('cis_test:capturedCount', function()
    return #captures
end)

exports('cis_test:resetCaptures', function()
    captures = {}
    CisTestProbe.last = nil
    return true
end)

-- Remote handlers used to prove that a handler owned by another resource is
-- reachable at all, and to measure how its arguments arrive.
exports('cis_test:echo', function(...)
    return recorder('echo')(...)
end)

exports('cis_test:echoArgs', function(...)
    return recorder('echoArgs')(...)
end)

exports('cis_test:recordSource', function(src, ...)
    local flat = recorder('recordSource')(...)
    flat[1] = src
    return flat
end)

-- Returns nothing. Used to measure whether a remote handler's RETURN VALUE
-- survives the reference call, which the current harness could not determine.
exports('cis_test:returnsNothing', function()
    return nil
end)

exports('cis_test:returnsValue', function()
    return 'a value'
end)

exports('cis_test:returnsSeveral', function()
    return 'first', 'second', 'third'
end)

-- ---------------------------------------------------------------------------
-- Client-side helpers: the same recorder, callable from the client suite.
-- ---------------------------------------------------------------------------
function CisTestProbe.capture(...)
    local n = select('#', ...)
    local flat = { n = n }
    for i = 1, n do
        flat[i] = select(i, ...)
    end
    CisTestProbe.last = flat
    return flat
end

local function describe(v)
    local t = type(v)
    if t == 'table' then
        if rawget(v, '__cfx_functionReference') then
            return 'functionReference'
        end
        if v.x ~= nil and v.y ~= nil then
            return ('vector(%s,%s,%s)'):format(tostring(v.x), tostring(v.y), tostring(v.z))
        end
        local n = 0
        for _ in pairs(v) do
            n = n + 1
        end
        return 'table(' .. n .. ')'
    end
    if t == 'function' then
        return 'function'
    end
    return ('%s(%s)'):format(t, tostring(v))
end
CisTestProbe.describe = describe

-- Is this value a callable function reference? A returned function arrives as
-- a table carrying __cfx_functionReference, so type() == 'function' is the
-- wrong test and rejects handlers that work.
function CisTestProbe.isCallable(v)
    if type(v) == 'function' then
        return true, 'function'
    end
    if type(v) == 'table' and rawget(v, '__cfx_functionReference') then
        return true, '__cfx_functionReference'
    end
    return false, type(v)
end
