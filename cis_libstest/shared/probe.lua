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

-- Returns a STRING summary, not the table. A table mixing numeric and string
-- keys does not survive the return trip: measured live, returning one makes
-- the awaiting export throw, so anything that needs to know what arrived must
-- ask through `cis_test:lastArgs` rather than read the return value. A scalar
-- crosses reliably, and a test should not depend on a return shape that does
-- not.
exports('cis_test:capture', function(...)
    local n = select('#', ...)
    local flat = { n = n }
    local parts = {}
    for i = 1, n do
        flat[i] = select(i, ...)
        parts[#parts + 1] = tostring(flat[i])
    end
    captures[#captures + 1] = flat
    CisTestProbe.last = flat
    return ('n=%d [%s]'):format(n, table.concat(parts, '|'))
end)

exports('cis_test:capturedCount', function()
    return #captures
end)

exports('cis_test:resetCaptures', function()
    captures = {}
    CisTestProbe.last = nil
    return true
end)

-- The argument count the LAST capture actually received, as a bare number.
-- A number cannot be mangled by table encoding on the way back across the
-- boundary, which a `{ n = n, ... }` table can be: measured live, the string
-- key `n` does not survive, so reading `.n` off the returned table reports -1
-- for a handler that in fact received two arguments. Anything that needs the
-- count must ask here, not off a returned table.
exports('cis_test:lastArgCount', function()
    local last = CisTestProbe.last
    return (type(last) == 'table' and last.n) or -1
end)

-- The last capture, rendered as one string: "n=2|A|B". Scalars cross the
-- boundary intact; a table does not keep its string keys, so a table is the
-- wrong shape to answer a question with.
exports('cis_test:lastArgs', function()
    local last = CisTestProbe.last
    if type(last) ~= 'table' then
        return 'nothing recorded'
    end
    local parts = {}
    for i = 1, (last.n or 0) do
        parts[#parts + 1] = tostring(last[i])
    end
    return ('n=%d [%s]'):format(last.n or 0, table.concat(parts, '|'))
end)

-- Settles, in-VM and with no boundary ambiguity, how the exports table has to
-- be called: does the bracket form drop an argument, or is the lookup already
-- bound? Every other statement about this in the repository is an inference
-- from the bracket CALL form, which is a different question from the bracket
-- LOOKUP that server/callback.lua actually performs.
--
-- `mode` is 'bracket' (fn(a,b,c)) or 'explicit' (fn(self,a,b,c)). Returns one
-- string describing what the target recorded, so the answer crosses cleanly.
exports('cis_test:probeBinding', function(mode)
    local self = exports['cis_libstest']
    local fn = self and self['cis_test:capture']
    if type(fn) ~= 'function' and not (type(fn) == 'table' and rawget(fn, '__cfx_functionReference')) then
        return ('%s: could not resolve the export (got %s)'):format(tostring(mode), type(fn))
    end
    captures = {}
    CisTestProbe.last = nil

    local ok, err
    if mode == 'bracket' then
        ok, err = pcall(fn, 'A', 'B', 'C')
    else
        ok, err = pcall(fn, self, 'A', 'B', 'C')
    end
    if not ok then
        return ('%s: THREW %s'):format(tostring(mode), tostring(err))
    end

    local last = CisTestProbe.last
    if type(last) ~= 'table' then
        return ('%s: the handler recorded nothing (isCallable said yes)'):format(tostring(mode))
    end
    local parts = {}
    for i = 1, (last.n or 0) do
        parts[#parts + 1] = tostring(last[i])
    end
    return ('%s: n=%d [%s]'):format(tostring(mode), last.n or 0, table.concat(parts, '|'))
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
