-- The recording ring every fake writes to, and the fault table it consults.
--
-- Loaded into both realms, so a test can compare what the SERVER fake saw with
-- what the CLIENT fake saw for the same logical call.
--
-- A RING, NOT A LIST, because a harness that leaks a record per call fails on
-- the wrong thing: the soak tier runs for thirty minutes and a list grows
-- without bound until the resource runs out of memory, which reads as a leak in
-- cis_libs rather than in the test rig. The ring is bounded, so a leak in the
-- library shows up in GetDiagnostics() and a leak in the rig does not.
--
-- NOTHING HERE IS A CIS_LIBS FILE. It is test/live/, it never ships (see the
-- release packer), and it is not covered by the boundary contract, which scans
-- the files the cis_libs manifest loads.

CisTestRing = {}

local RING_CAP = 512
local rings = {}
local faults = {}

-- Why a cap and not an unbounded log: the plan's soak gate is "memory growth
-- under 512 KB" and "no count drift". A recorder that grows with the call count
-- makes the first of those unmeasurable, because the growth is the rig's.
local RING_BYTES_ESTIMATE = 200

function CisTestRing.Record(slot, method, args, extra)
    local ring = rings[slot]
    if not ring then
        ring = {}
        rings[slot] = ring
    end
    -- The argument COUNT comes from the table the caller already built, not from
    -- `select('#', ...)`: this is not a vararg function, so `...` is not in
    -- scope here. And the count matters -- a provider call that lost an argument
    -- on the way through has the same values in a shorter list, and `args.n` is
    -- the only thing that tells the two apart.
    local entry = {
        method = method,
        args = args,
        n = args and args.n or 0,
        at = GetGameTimer(),
    }
    for k, v in pairs(extra or {}) do entry[k] = v end
    ring[#ring + 1] = entry
    -- Drop from the front once over the cap, so a long run cannot grow.
    while #ring > RING_CAP do table.remove(ring, 1) end
    return entry
end

-- Every call the fake for `slot` has seen, newest last.
function CisTestRing.GetCalls(slot, method)
    local ring = rings[slot] or {}
    if not method then return ring end
    local out = {}
    for _, e in ipairs(ring) do
        if e.method == method then out[#out + 1] = e end
    end
    return out
end

function CisTestRing.ResetCalls(slot)
    if slot then
        rings[slot] = {}
    else
        for k in pairs(rings) do rings[k] = {} end
    end
end

-- A rough size, so the soak tier can tell a library leak from a rig leak
-- without the rig being the thing that grows.
function CisTestRing.EstimateBytes()
    local total = 0
    for _, ring in pairs(rings) do
        total = total + #ring * RING_BYTES_ESTIMATE
    end
    return total
end

-- FAULTS.
--
-- mode is one of:
--   raise          the provider raises, which is what a broken third-party
--                  library does on a bad day
--   nil            the provider answers nothing at all
--   false_reason   the provider answers `false, 'reason'`, the shape a real
--                  refusal uses and the one cis_libs has to pass through
--   slow:<ms>      the provider blocks, which is how a database timeout and a
--                  stalled provider look from the caller
--   wrong_shape    the provider answers something of the right arity and the
--                  wrong type, which is the failure no return-value assertion
--                  catches and every type check does
-- Keyed by the mode NAME. `nil` cannot be a table key -- `{ nil = true }` is a
-- syntax error, and it is the obvious way to write this table, because nil is
-- one of the modes. The list is compared by value instead.
local FAULT_MODES = {
    raise = true,
    false_reason = true,
    wrong_shape = true,
}

function CisTestRing.SetFault(slot, method, mode)
    if mode ~= nil and mode ~= false then
        if type(mode) ~= 'string' then
            error(("SetFault: mode must be a string, got %s"):format(type(mode)), 2)
        end
        if not FAULT_MODES[mode] and not mode:match('^slow:%d+$') then
            error(("SetFault: unknown mode %q"):format(mode), 2)
        end
    end
    faults[slot] = faults[slot] or {}
    if mode == nil or mode == false then
        faults[slot][method] = nil
    else
        faults[slot][method] = mode
    end
    return true
end

function CisTestRing.ClearFaults(slot)
    if slot then
        faults[slot] = {}
    else
        faults = {}
    end
    return true
end

-- Called by every fake before it does anything else. Returns the fault mode, or
-- nil when this call should behave normally.
function CisTestRing.Fault(slot, method)
    local byMethod = faults[slot]
    return byMethod and byMethod[method] or nil
end

-- Runs the fault, if any, and reports whether the fake should return now.
-- `handled` means the fault already answered; the caller returns immediately.
function CisTestRing.ApplyFault(slot, method)
    local mode = CisTestRing.Fault(slot, method)
    if not mode then return false end

    if mode == 'raise' then
        -- A real raise, not error()'d text: the point is that cis_libs catches
        -- it, and a provider that returns nil instead would test something else.
        error(('cis_test_providers: injected fault on %s.%s'):format(slot, method), 0)
    end
    if mode == 'nil' then
        return true
    end
    if mode == 'false_reason' then
        return 'false_reason'
    end
    if mode == 'wrong_shape' then
        return 'wrong_shape'
    end
    local ms = tonumber(mode:match('^slow:(%d+)$'))
    if ms then
        -- Blocked rather than merely slow, because cis_libs answers a timeout
        -- by refusing and a test has to be able to see which side gave up.
        Wait(ms)
    end
    return false
end