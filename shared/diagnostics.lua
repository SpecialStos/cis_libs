-- Counters and named probes, shared by both realms.
--
-- WHY THIS EXISTS. Every lifecycle claim this library makes is a claim that
-- something was cleaned up: a zone removed when its owner stops, a pending
-- callback dropped when its player leaves, a sync record deleted when the
-- resource that made it stops. Those claims cannot be checked by asserting that
-- nothing threw. They can only be checked by counting before and after, and a
-- count of the wrong thing is worse than no count -- so the things counted here
-- are the things that must return to their baseline.
--
-- COUNTS ONLY. No player names, no identifiers, no coordinates, no IPs. This
-- table is read by an operator pasting it into a support channel, and it is also
-- what a test asserts against, so anything sensitive in here would end up in
-- both. Where a count needs a grouping key it is a RESOURCE NAME or a SLOT NAME,
-- both of which are already in the audit log by design.
--
-- A PROBE, NOT A FUNCTION, FOR EACH REALM'S STATE. The server's sync records and
-- the client's zone table live in files that know nothing about each other, and
-- neither is reachable from shared code. So each side registers a probe that
-- knows how to count its own, and Collect() runs whichever belong to the realm
-- asking.

CisDiagnostics = {}

-- A CLOCK THAT ALWAYS EXISTS. shared/** is loaded by the pure-module suites
-- with no FiveM at all -- that is the whole point of those suites -- so a
-- direct GetGameTimer() at load time raises there and takes every suite with
-- it. os.clock is standard and is only used when there is no game timer, where
-- uptime is meaningless anyway and only the counters matter.
local function now()
    if type(GetGameTimer) == 'function' then
        return GetGameTimer()
    end
    return os.clock() * 1000
end

local startedAt = now()
local counters = {}
local probes = {}

-- Counters are named constants rather than free strings, because a typo in a
-- counter name is a counter that always reads zero -- which looks exactly like
-- a resource that never leaked.
CisDiagnostics.NAMES = {
    ERRORS = 'errors',
    WARNINGS = 'warnings',
    RATE_LIMITED = 'rateLimited',
    NET_REFUSED = 'netRefused',
    CALLBACK_ERRORS = 'callbackErrors',
    PROVIDER_ERRORS = 'providerErrors',
    ZONE_ERRORS = 'zoneErrors',
    TICK_ERRORS = 'tickErrors',
}

function CisDiagnostics.Inc(name, by)
    counters[name] = (counters[name] or 0) + (by or 1)
    return counters[name]
end

function CisDiagnostics.Count(name)
    return counters[name] or 0
end

function CisDiagnostics.ResetCounters()
    counters = {}
end

-- Registers a probe. `realm` is 'server' or 'client'; a probe only runs when
-- the realm asking matches, so a server asking never tries to count a zone
-- table that does not exist in its VM.
function CisDiagnostics.Register(realm, name, fn)
    probes[#probes + 1] = { realm = realm, name = name, fn = fn }
end

-- Every registered probe name, so a caller can tell "this build reports no zone
-- count" from "this build reports zero zones". The first is a build that cannot
-- answer; the second is a build with nothing to clean up.
function CisDiagnostics.ProbeNames(realm)
    local out = {}
    for _, p in ipairs(probes) do
        if p.realm == realm then out[#out + 1] = p.name end
    end
    table.sort(out)
    return out
end

-- Runs the probes and assembles the snapshot.
--
-- EVERY PROBE IS WRAPPED. A probe that raises takes the whole snapshot with it,
-- and a diagnostics call that raises is worse than no diagnostics at all: the
-- harness calls it before and after every case, so one bad probe turns every
-- case into an ERROR and reports a library that is completely broken. A probe
-- that fails reports itself instead.
local function runProbe(p, out)
    local ok, value = pcall(p.fn)
    if ok then
        out[p.name] = value
    else
        out[p.name .. 'Error'] = tostring(value)
    end
end

function CisDiagnostics.Collect(realm)
    realm = realm or 'server'
    local out = {
        realm = realm,
        uptimeMs = now() - startedAt,
        -- Lua kilobytes, not bytes. collectgarbage's unit is what it is, and
        -- labelling it anything else is how a soak gate ends up measuring the
        -- wrong quantity.
        memoryKb = collectgarbage('count'),
        counters = {},
        probes = {},
    }
    for k, v in pairs(counters) do out.counters[k] = v end
    for _, p in ipairs(probes) do
        if p.realm == realm then runProbe(p, out.probes) end
    end
    return out
end

-- A stable, comparable FORM of a snapshot, for a test that says "these two are
-- equal". Two snapshots taken either side of a case must be identical, and the
-- ones that must move are the ones a test names explicitly.
function CisDiagnostics.Diff(before, after)
    local changed = {}
    for k, v in pairs(after.counters or {}) do
        if before.counters[k] ~= v then
            changed[#changed + 1] = ('counter %s: %s -> %s'):format(k, tostring(before.counters[k]), tostring(v))
        end
    end
    for k, v in pairs(after.probes or {}) do
        if type(v) == 'table' then
            for pk, pv in pairs(v) do
                local b = before.probes and before.probes[k] and before.probes[k][pk]
                if b ~= pv then
                    changed[#changed + 1] = ('probe %s.%s: %s -> %s'):format(
                        k, pk, tostring(b), tostring(pv))
                end
            end
        else
            local b = before.probes and before.probes[k]
            if b ~= v then
                changed[#changed + 1] = ('probe %s: %s -> %s'):format(k, tostring(b), tostring(v))
            end
        end
    end
    return changed
end