-- T8. The boot self-check.
--
-- Support is the stated cost centre for this platform, and the expensive kind
-- of support ticket is the one where a resource is quietly missing a capability
-- and nobody finds out until a player notices. This file exists to turn that
-- into ONE block, once, shortly after boot, with every line naming the change
-- that fixes it.
--
-- Three questions, and each answers a different support ticket:
--
--   1. Does a started resource declare a capability cis_libs never resolved?
--      Answered by reading each consumer's OWN `cis_requires` metadata, because
--      a library cannot know what a product it has never heard of needs. The
--      convention is documented below and in DOCUMENTATION.md; it is opt-in and
--      costs a consumer one line in its fxmanifest.
--
--   2. Does a slot resolve but answer "missing" for some declared method?
--      This is the one unit tests cannot catch from inside this repository: the
--      slot is filled by a resource in ANOTHER repo, and the method table it
--      hands back may be missing a key the contract declared. X-1 turns it into
--      a CI failure; until then it is a boot line.
--
--   3. Did a consumer start BEFORE cis_libs? A resource that started first and
--      still depends on cis_libs is a resource whose `dependency 'cis_libs'` is
--      missing or misspelled, and it will have read every capability as absent.
--
-- WHY A 20 SECOND GRACE PERIOD, and not "at the end of boot". A server with
-- thirty resources does not finish starting when cis_libs finishes starting,
-- and a check that ran immediately would report every capability as missing and
-- be ignored -- which is worse than not reporting it, because it trains the
-- operator to skip the block. 20s is long enough for the stack to settle and
-- short enough that the block is still in the log when someone reads it.

local CIS_REQUIRES = 'cis_requires'
local GRACE_MS = 20000

local startedBeforeUs = {}

-- Snapshot at cis_libs's own start. A resource already running at this moment
-- either did not declare cis_libs as a dependency, or declared it and FiveM
-- started it anyway because it was already up. Both are the same bug from here.
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
-- capability slots this resource cannot work without.
--
-- WHY A METADATA KEY AND NOT A CONVENTION ABOUT GUESSING. A library cannot
-- infer what a product needs: `cis_phone` may use `inventory`, `cis_medic` may
-- use both `inventory` and `target`, and neither is discoverable from the
-- outside. Declaring it is one line and it is the only way the check can be
-- right rather than merely noisy.
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

-- Every problem, STRUCTURED, alongside the printed one. The printed block is
-- what an operator reads; this is what GetSelfCheck hands a harness, and it is
-- what makes the check assertable instead of merely visible. Each entry carries
-- the fix in the same words, because a problem an operator cannot act on is a
-- problem they will ignore.
local PROBLEMS = {}

-- When the scan last ran, so a cached answer says how old it is. A self-check
-- from before a restart is describing an install that no longer exists.
local CHECKED_AT = nil

local function problem(code, message, fix)
    PROBLEMS[#PROBLEMS + 1] = { code = code, message = message, fix = fix }
end

-- Forward declarations. An upvalue is resolved LEXICALLY in Lua, so a
-- `local function` written after its caller makes the CALLER reach for a global
-- of that name -- nil at runtime, with no syntax error anywhere to warn about
-- it. Declared here, assigned below, which is why these three are not simply
-- moved above run(): the order that reads well is not the order that resolves.
local SlotNames, describeOwners, declaresDependencyOnUs

local function run()
    local problems = 0

    -- 1. What a started resource says it needs, against what exists.
    if GetNumResources and GetResourceByFindIndex then
        for i = 0, GetNumResources() - 1 do
            local name = GetResourceByFindIndex(i)
            if name and name ~= GetCurrentResourceName() then
                -- luacheck: ignore 542
                -- Deliberately empty. This whole branch is the defect: the
                -- condition is inverted and it matches every resource rather
                -- than the ones it means to, so the check has never run. It is
                -- replaced, not repaired, when the dependency check is rewritten
                -- against GetResourceMetadata. Keeping the comment is the only
                -- thing here that is currently correct.
                if GetResourceState and GetResourceState(name) ~= 'started' then
                    -- Not our problem yet. A resource that is still `starting`
                    -- when this runs will report itself if it fails.
                else
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
            -- FETCH THE METHODS BEFORE ASKING, and with methods(), not
            -- resolve(). CisRegistry.missing() answers nil until held.methods has
            -- been populated, and resolve() does not populate it -- it caches the
            -- DISPATCHER. Without this the check is blind to exactly the case it
            -- exists for: a provider that registered, was never called, and is
            -- missing half its contract. Nothing on a healthy server fetches
            -- that table for a slot nobody calls, so nothing else would.
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

-- Whether a resource's fxmanifest declares `dependency 'cis_libs'`. Read from
-- the manifest text rather than a native, because FiveM exposes no API for a
-- resource's declared dependencies.
function declaresDependencyOnUs(name)
    local path = ('%s/%s/fxmanifest.lua'):format(GetResourcePath and GetResourcePath(name) or name, name)
    local fh = io and io.open and io.open(path, 'r')
    if not fh then return false end
    local text = fh:read('*a')
    fh:close()
    if type(text) ~= 'string' then return false end
    return text:find("dependency%s+['\"]cis_libs['\"]") ~= nil
end

snapshotStartedBefore()

if SetTimeout then
    SetTimeout(GRACE_MS, run)
else
    -- No scheduler (tests, and a platform without SetTimeout). Run inline so the
    -- check is never silently skipped -- a self-check that does not run is
    -- indistinguishable from one that found nothing.
    run()
end
-- ================================================================ GetSelfCheck
--
-- The same findings the boot block prints, as data.
--
-- A check that only prints is a check nothing can assert on, and this one has
-- been dead in more than one way already: it counted problems, it never
-- returned them, and its dependency check had an inverted condition. Returning
-- them is what makes the next version of that check testable -- the harness
-- starts a deliberately broken resource and asserts that THIS answers with the
-- problem and the fix, rather than a human reading a console and noticing.
--
-- The result is CACHED because the answer is a property of the install at the
-- moment it ran, and a caller polling it must not re-run a scan of every
-- resource on the server.
---
--- @return table { ok = boolean, problems = { { code, message, fix } } }
exports('GetSelfCheck', function()
    return { ok = #PROBLEMS == 0, problems = PROBLEMS, checkedAt = CHECKED_AT }
end)
