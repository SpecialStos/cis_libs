-- Counters and named probes, shared by both realms.

CisDiagnostics = {}

-- A CLOCK THAT ALWAYS EXISTS. shared/** is loaded by the pure-module suites with no
local function now()
    if type(GetGameTimer) == 'function' then
        return GetGameTimer()
    end
    return os.clock() * 1000
end

local startedAt = now()
local counters = {}
local probes = {}

-- Counters are named constants rather than free strings, because a typo in a counter
CisDiagnostics.NAMES = {
    ERRORS = 'errors',
    WARNINGS = 'warnings',
    RATE_LIMITED = 'rateLimited',
    NET_REFUSED = 'netRefused',
    CALLBACK_ERRORS = 'callbackErrors',
    PROVIDER_ERRORS = 'providerErrors',
    ZONE_ERRORS = 'zoneErrors',
    TICK_ERRORS = 'tickErrors',
    -- A caller-supplied filter that raised inside client/world.lua.
    WORLD_FILTER_ERRORS = 'worldFilterErrors',
    NET_SCHEMA_REFUSED = 'netSchemaRefused',
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

-- Registers a probe. `realm` is 'server' or 'client'; a probe only runs when the realm
function CisDiagnostics.Register(realm, name, fn)
    probes[#probes + 1] = { realm = realm, name = name, fn = fn }
end

-- Every registered probe name, so a caller can tell "this build reports no zone count"
function CisDiagnostics.ProbeNames(realm)
    local out = {}
    for _, p in ipairs(probes) do
        if p.realm == realm then out[#out + 1] = p.name end
    end
    table.sort(out)
    return out
end

-- Runs the probes and assembles the snapshot.
local function runProbe(p, out)
    local ok, value = pcall(p.fn)
    if ok then
        out[p.name] = value
    else
        out[p.name .. 'Error'] = tostring(value)
    end
end

function CisDiagnostics.Collect(realm, opts)
    realm = realm or 'server'
    -- A collect in ANOTHER resource's VM does not collect this one. Soak used
    -- to pcall collectgarbage in cis_test, then read cis_libs' count, so the
    -- 512 KB budget compared unreclaimed garbage. Collect here, in this state.
    if type(opts) == 'table' and opts.collect then
        pcall(collectgarbage, 'collect')
    end
    local out = {
        realm = realm,
        uptimeMs = now() - startedAt,
        -- Lua kilobytes, not bytes. collectgarbage's unit is what it is, and labelling
        memoryKb = 0,
        counters = {},
        probes = {},
    }
    -- fengari has no lua_gc. A snapshot that raises is worse than memoryKb = 0.
    local okMem, count = pcall(collectgarbage, 'count')
    if okMem and type(count) == 'number' then
        out.memoryKb = count
    end
    for k, v in pairs(counters) do out.counters[k] = v end
    for _, p in ipairs(probes) do
        if p.realm == realm then runProbe(p, out.probes) end
    end
    -- Sibling of probes, not a probe.
    if CisTiming and type(CisTiming.snapshot) == 'function' then
        out.timings = CisTiming.snapshot()
    else
        out.timings = {}
    end
    return out
end

-- A stable, comparable FORM of a snapshot, for a test that says "these two are equal".
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
