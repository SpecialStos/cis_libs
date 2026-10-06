-- T8. The boot self-check.

local CIS_REQUIRES = 'cis_requires'
local GRACE_MS = 20000

local startedBeforeUs = {}

-- Snapshot at cis_libs's own start.
local function snapshotStartedBefore()
    if not GetNumResources or not GetResourceByFindIndex then
        return
    end
    for i = 0, GetNumResources() - 1 do
        local name = GetResourceByFindIndex(i)
        if name then startedBeforeUs[name] = true end
    end
end

-- `fxmeta { cis_requires = 'database, target' }` -- a comma-separated list of
local function declaredRequirements(name)
    if not GetResourceMetadata then return {} end
    local raw = GetResourceMetadata(name, CIS_REQUIRES)
    if type(raw) ~= 'string' or raw == '' then return {} end
    local out = {}
    for piece in raw:gmatch('[^,%s]+') do
        out[#out + 1] = piece
    end
    return out
end

local function line(...)
    print('[cis_libs] ' .. table.concat({ ... }, ' '))
end

-- Every problem, STRUCTURED, alongside the printed one.
local PROBLEMS = {}

-- When the scan last ran, so a cached answer says how old it is.
local CHECKED_AT = nil

local function problem(code, message, fix)
    PROBLEMS[#PROBLEMS + 1] = { code = code, message = message, fix = fix }
end

-- Forward declarations. An upvalue is resolved LEXICALLY in Lua, so a `local function`
local SlotNames, describeOwners, declaresDependencyOnUs
local includesLibraryInit, statefulInternalInclude

local function run()
    local problems = 0

    -- 1. What a started resource says it needs, against what exists.
    if GetNumResources and GetResourceByFindIndex then
        for i = 0, GetNumResources() - 1 do
            local name = GetResourceByFindIndex(i)
            if name and name ~= GetCurrentResourceName() then
                -- THE CONDITION WAS INVERTED. It read `~= 'started'` for the "not our
                if GetResourceState and GetResourceState(name) == 'started' then
                    -- 3b. Includes cis_libs without declaring it.
                    if includesLibraryInit(name) and not declaresDependencyOnUs(name) then
                        problems = problems + 1
                        problem('missing_dependency',
                            ('%s includes @cis_libs/init.lua but does not declare '
                                .. 'cis_libs as a dependency'):format(name),
                            ("add dependency 'cis_libs' to " .. name
                                .. '/fxmanifest.lua, so FiveM starts cis_libs first'))
                        line(('[x] %s includes @cis_libs/init.lua but does not declare '
                            .. 'cis_libs as a dependency'):format(name))
                        line(("    fix: add dependency 'cis_libs' to " .. name
                            .. '/fxmanifest.lua, so FiveM starts cis_libs first'))
                    end

                    -- 3c. Pulling in a stateful internal file.
                    local internal = statefulInternalInclude(name)
                    if internal then
                        problems = problems + 1
                        problem('internal_include',
                            ('%s includes cis_libs\'s internal %s, which carries '
                                .. 'STATE. It gets its own copy, separate from the one '
                                .. 'cis_libs uses.'):format(name, internal),
                            ("remove that line from " .. name .. '/fxmanifest.lua and '
                                .. 'include @cis_libs/init.lua instead. Cis.require(name) '
                                .. 'loads a module in the CONSUMER\'s VM on purpose.'))
                        line(("[x] %s includes cis_libs's internal %s, which carries "
                            .. 'STATE. It gets its own copy, separate from the one '
                            .. 'cis_libs uses.'):format(name, internal))
                        line(("    fix: remove that line from " .. name
                            .. "/fxmanifest.lua and include @cis_libs/init.lua "
                                .. "instead. Cis.require(name) loads a module in "
                                .. "the CONSUMER's VM on purpose."))
                    end

                    for _, slot in ipairs(declaredRequirements(name)) do
                        if not CisRegistry.SLOTS[slot] then
                            problems = problems + 1
                            problem('unknown_slot',
                                ('%s requires capability %q, which is not a slot this library knows'):format(name, slot),
                                ('check the spelling against CisRegistry.SLOTS. Known slots: %s'):format(table.concat(SlotNames(), ', ')))
                            line(('[x] %s requires capability %q, which is not a slot this library knows')
                                :format(name, slot))
                            line(('    fix: check the spelling against CisRegistry.SLOTS. '
                                .. 'Known slots: %s'):format(table.concat(SlotNames(), ', ')))
                        elseif not CisRegistry.has(slot) then
                            problems = problems + 1
                            line(('[x] %s requires capability %q and no provider is registered for it')
                                :format(name, slot))
                            line(('    fix: start the product that provides %q, or add it to '
                                .. 'Config.Framework in cis_core. Current owners: %s')
                                :format(slot, describeOwners()))
                        end
                    end
                end
            end
        end
    end

    -- 2. A slot that resolved but is missing a declared method.
    for slot in pairs(CisRegistry.SLOTS) do
        if CisRegistry.has(slot) then
            -- FETCH THE METHODS BEFORE ASKING, and with methods(), not resolve().
            CisRegistry.methods(slot)
            local missing = CisRegistry.missing(slot)
            if missing and #missing > 0 then
                problems = problems + 1
                problem('incomplete_provider',
                    ('capability %q is registered by %s but is missing: %s'):format(slot, tostring(CisRegistry.owner(slot)), table.concat(missing, ', ')),
                    'the provider is out of date. Update it, or run the contract test so this fails in CI instead of at boot.')
                line(('[x] capability %q is registered by %s but is missing: %s')
                    :format(slot, tostring(CisRegistry.owner(slot)), table.concat(missing, ', ')))
                line(('    fix: the provider is out of date. Update it, or run the '
                    .. 'contract test (Phase 8) so this fails in CI instead of at boot.'))
            end
        end
    end

    -- 3. Consumers that started before us.
    for name in pairs(startedBeforeUs) do
        if name ~= GetCurrentResourceName() and declaresDependencyOnUs(name) then
            problems = problems + 1
            problem('started_before_dependency',
                ('%s started before cis_libs but declares it as a dependency'):format(name),
                "add dependency 'cis_libs' to its fxmanifest, so FiveM starts it after. It read every capability as absent.")
            line(('[x] %s started before cis_libs but declares it as a dependency')
                :format(name))
            line("    fix: add `dependency 'cis_libs'` to its fxmanifest, so FiveM "
                .. 'starts it after. It read every capability as absent.')
        end
    end

    CHECKED_AT = GetGameTimer()

    if problems == 0 then
        line('self-check: no capability problems found.')
    else
        line(('self-check: %d problem(s) above. Each one names the line to change.')
            :format(problems))
    end
    line('self-check: if a line above is wrong for your install, that is a bug in '
        .. 'this check -- tell us rather than ignoring the block.')
end

function SlotNames()
    local out = {}
    for slot in pairs(CisRegistry.SLOTS) do out[#out + 1] = slot end
    table.sort(out)
    return out
end

function describeOwners()
    local snapshot = CisRegistry.snapshot()
    local parts = {}
    for slot, info in pairs(snapshot) do
        parts[#parts + 1] = ('%s=%s'):format(slot, tostring(info.owner))
    end
    if #parts == 0 then return 'none' end
    table.sort(parts)
    return table.concat(parts, ', ')
end

-- The internal files that carry STATE.
local STATEFUL_INTERNALS = {
    ['registry'] = true, ['grid'] = true, ['pending'] = true,
    ['histogram'] = true, ['timing'] = true, ['config'] = true, ['ready'] = true,
    ['owned'] = true, ['detect'] = true, ['defaults'] = true,
    ['diagnostics'] = true, ['loopguard'] = true,
}

--- Every value in a resource's fxmanifest metadata, whichever key it arrived under.
local MANIFEST_KEYS = {
    '', 'dependency', 'dependencies',
    'shared_script', 'shared_scripts',
    'client_script', 'client_scripts',
    'server_script', 'server_scripts',
    'files', 'provide', 'provides',
}

function manifestEntries(name)
    local out, seen = {}, {}
    if type(GetNumResourceMetadata) ~= 'function' or type(GetResourceMetadata) ~= 'function' then
        return out
    end
    local ok, total = pcall(GetNumResourceMetadata, name)
    if not ok or type(total) ~= 'number' then
        return out
    end
    for _, key in ipairs(MANIFEST_KEYS) do
        for i = 0, total - 1 do
            local readOk, value = pcall(GetResourceMetadata, name, key, i)
            if readOk and type(value) == 'string' and not seen[value] then
                seen[value] = true
                out[#out + 1] = value
            end
        end
    end
    return out
end

--- Whether a resource's manifest declares cis_libs.
function declaresDependencyOnUs(name)
    for _, value in ipairs(manifestEntries(name)) do
        if value == GetCurrentResourceName() then
            return true
        end
    end
    return false
end

--- Whether a resource pulls in cis_libs's own entry point at all.
function includesLibraryInit(name)
    for _, value in ipairs(manifestEntries(name)) do
        if value == '@cis_libs/init.lua' or value == 'cis_libs/init.lua' then
            return true
        end
    end
    return false
end

--- The first STATEFUL internal this resource includes, or nil.
function statefulInternalInclude(name)
    for _, value in ipairs(manifestEntries(name)) do
        if type(value) == 'string' then
            local rel = value:match('^@?cis_libs/(.+)$')
            if rel then
                local base = rel:match('([^/]+)%.lua$')
                if base and STATEFUL_INTERNALS[base] then
                    return value
                end
            end
        end
    end
    return nil
end

snapshotStartedBefore()

if SetTimeout then
    SetTimeout(GRACE_MS, run)
else
    -- No scheduler (tests, and a platform without SetTimeout).
    run()
end
-- The same findings the boot block prints, as data.
--- @return table { ok = boolean, problems = { { code, message, fix } } }
exports('GetSelfCheck', function()
    return { ok = #PROBLEMS == 0, problems = PROBLEMS, checkedAt = CHECKED_AT }
end)
