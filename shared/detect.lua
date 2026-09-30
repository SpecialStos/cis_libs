-- Framework and database detection.
--
-- PURE. No natives, no exports, no globals. Everything the detection needs
-- about the running server arrives as a function argument, which is what makes
-- it unit-testable under fengari with no FiveM server at all -- and a
-- detection path that cannot be tested is a detection path that will
-- eventually pick the wrong answer silently.
--
-- Why this exists: an operator configuring `Type = "QBCORE"` on a server
-- running qbx_core got a library that reported itself ready and then returned
-- nil for every player, with nothing in the console saying why. Asking the
-- server what it is actually running is the whole point.

CisDetect = {}

-- Known frameworks, MOST SPECIFIC FIRST. The order is load-bearing: a
-- qbx_core server also has qb-* resources on disk, and a plain "is anything
-- started" scan would report whichever it happened to find first.
--
-- `probe` names the export that proves the resource is the real thing rather
-- than a lookalike. A missing export raises when called, so a probe is an
-- honest existence test rather than a guess.
CisDetect.FRAMEWORKS = {
    { name = 'QBOX',   resource = 'qbx_core',     probe = 'GetPlayer'  },
    { name = 'QBCORE', resource = 'qb-core',      probe = 'GetCoreObject' },
    { name = 'ESX',    resource = 'es_extended',  probe = 'getSharedObject' },
}

-- Databases, same shape. oxmysql first: it is the most common and the only
-- one that supports `Cis.db.transaction`, so preferring it means a server that
-- happens to have two drivers installed gets the better one.
CisDetect.DATABASES = {
    { name = 'oxmysql',       resource = 'oxmysql' },
    { name = 'mysql-async',   resource = 'mysql-async' },
    { name = 'ghmattimysql',  resource = 'ghmattimysql' },
    { name = 'mongodb',       resource = 'mongodb' },
}

-- Compare dotted version strings. Returns true when `have` is at least `want`.
-- Missing components count as zero, so '1.9' >= '1.9.0' and '2' >= '1.9.0'.
-- Tolerant of a non-numeric tail ('1.9.0-beta3'), because that is what real
-- resource versions look like and a hard failure here would be worse than a
-- slightly wrong ordering.
function CisDetect.versionAtLeast(have, want)
    if type(have) ~= 'string' or type(want) ~= 'string' then
        return false
    end
    local function parts(v)
        local out = {}
        for piece in tostring(v):gmatch('[^%.%-]+') do
            out[#out + 1] = tonumber(piece) or 0
        end
        return out
    end
    local a, b = parts(have), parts(want)
    for i = 1, math.max(#a, #b) do
        local x, y = a[i] or 0, b[i] or 0
        if x ~= y then
            return x > y
        end
    end
    return true
end

--- Decide which framework to use.
---
--- @param configured string|nil  Config.Framework.Type, uppercased by the caller
--- @param custom table|nil       Config.Framework.Custom, the operator's own adapter
--- @param isStarted function     isStarted(resource) -> boolean: true if running
--- @param version function       version(resource) -> string|nil
--- @param probe function         probe(resource, exportName) -> boolean
--- @return table { name, resource, version, how, reason }
function CisDetect.framework(configured, custom, isStarted, version, probe)
    configured = (configured or 'AUTO'):upper()

    -- A custom adapter wins over everything, including an explicit Type. If an
    -- operator wired up their own framework, guessing at a known one instead
    -- is never what they meant.
    if type(custom) == 'table' and type(custom.resource) == 'string' and custom.resource ~= '' then
        local res = custom.resource
        if not isStarted(res) then
            return {
                name = 'NONE', resource = nil, version = nil, how = 'custom',
                reason = ('custom framework %q is not started'):format(res),
            }
        end
        local exportName = custom.getPlayer or custom.probe
        if type(exportName) == 'string' and exportName ~= '' and not probe(res, exportName) then
            return {
                name = 'NONE', resource = nil, version = nil, how = 'custom',
                reason = ('custom framework %q is started but exposes no %q export')
                    :format(res, tostring(exportName)),
            }
        end
        return {
            name = (custom.name or 'CUSTOM'):upper(), resource = res,
            version = version(res), how = 'custom',
            reason = ('custom framework %q'):format(res),
        }
    end

    -- An explicit, known Type is honoured even if nothing is started yet: the
    -- caller may legitimately be configured ahead of the resource, and the
    -- boot path waits for it. Report the name but say plainly that it is not
    -- up yet, so the console never implies a framework that is absent.
    if configured ~= 'AUTO' and configured ~= 'NONE' then
        for _, known in ipairs(CisDetect.FRAMEWORKS) do
            if known.name == configured then
                local up = isStarted(known.resource) and true or false
                return {
                    name = known.name,
                    resource = up and known.resource or nil,
                    version = up and version(known.resource) or nil,
                    how = 'configured',
                    reason = up and ('configured as %s'):format(known.name)
                        or ('configured as %s but %q is not started'):format(known.name, known.resource),
                    wanted = true,
                }
            end
        end
        -- Configured with a name we do not know. That is not an error -- it may
        -- be a custom framework configured by resource name rather than through
        -- Custom -- but it is worth saying out loud rather than silently
        -- falling back.
        if configured ~= 'NONE' then
            local up = isStarted(configured) and true or false
            return {
                name = up and configured or 'NONE',
                resource = up and configured or nil,
                version = up and version(configured) or nil,
                how = 'configured',
                reason = up and ('configured as %s'):format(configured)
                    or ('configured as %s, which is not a known framework and is not started')
                        :format(configured),
            }
        end
    end

    if configured == 'NONE' then
        return {
            name = 'NONE', resource = nil, version = nil, how = 'configured',
            reason = 'configured as NONE; no framework is used',
        }
    end

    -- AUTO: ask the server what is actually running, most specific first.
    for _, known in ipairs(CisDetect.FRAMEWORKS) do
        if isStarted(known.resource) and probe(known.resource, known.probe) then
            return {
                name = known.name, resource = known.resource, version = version(known.resource),
                how = 'detected',
                reason = ('detected %s (%s) running'):format(known.resource, tostring(version(known.resource))),
            }
        end
    end

    return {
        name = 'NONE', resource = nil, version = nil, how = 'detected',
        reason = 'no supported framework is started',
    }
end

--- Decide which database driver to use. Same contract as CisDetect.framework.
function CisDetect.database(configured, isStarted, version)
    configured = (configured or 'AUTO'):upper()

    if configured == 'NONE' then
        return {
            name = 'NONE', resource = nil, version = nil, how = 'configured',
            reason = 'configured as NONE; no database is used',
        }
    end

    if configured ~= 'AUTO' then
        for _, known in ipairs(CisDetect.DATABASES) do
            if known.name == configured then
                local up = isStarted(known.resource) and true or false
                return {
                    name = known.name, resource = up and known.resource or nil,
                    version = up and version(known.resource) or nil,
                    how = 'configured',
                    reason = up and ('configured as %s'):format(known.name)
                        or ('configured as %s but %q is not started'):format(known.name, known.resource),
                }
            end
        end
        return {
            name = 'NONE', resource = nil, version = nil, how = 'configured',
            reason = ('configured as %s, which is not a supported driver'):format(configured),
        }
    end

    for _, known in ipairs(CisDetect.DATABASES) do
        if isStarted(known.resource) then
            return {
                name = known.name, resource = known.resource, version = version(known.resource),
                how = 'detected',
                reason = ('detected %s running'):format(known.resource),
            }
        end
    end

    return {
        name = 'NONE', resource = nil, version = nil, how = 'detected',
        reason = 'no supported database driver is started',
    }
end
