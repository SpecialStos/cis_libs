-- Starting and stopping resources, from inside the harness.
--
-- WHY THIS IS THE TRICKY PART. A lifecycle case has to stop a resource and
-- watch what it left behind. Doing that by hand means a person at the console
-- for every case, which is not a test. So the harness stops resources itself,
-- with ExecuteCommand, and then polls GetResourceState until the resource is
-- actually in the expected state rather than assuming the command took.
--
-- THE ACE PROBLEM, AND WHAT HAPPENS WITHOUT IT. `ExecuteCommand('stop X')`
-- needs the resource to hold command.stop, and command ACEs DO NOT SURVIVE A
-- RESTART. So on a fresh session every one of these calls is refused, and a
-- harness that quietly carries on would report every lifecycle case as a
-- SKIP with no reason -- a run that looks like coverage and is not.
--
-- So a refusal is LOUD: the action is printed as `[cis_test] ACTION: <command>`
-- for a human to type, the case records that it was driven by hand rather than
-- by the harness, and the run's summary says how many cases that applied to.
-- Which mode was used is in the runbook.

CisTestControl = {}

-- How long a resource may take to reach the state we asked for. Generous: a
-- resource that has not started in ten seconds is not starting, and waiting
-- longer only turns a clear failure into a slow one.
local STATE_TIMEOUT_MS = 10000
local POLL_MS = 100

-- WHETHER THIS RESOURCE MAY RUN A COMMAND AT ALL.
--
-- `ExecuteCommand` does NOT raise when the caller lacks the ACE -- it does
-- nothing, and FiveM writes "Access denied for command X" to the console where
-- a resource cannot see it. So an unconditional call looks exactly like a
-- successful one until something times out, which is how the first lifecycle
-- run spent 42 seconds waiting for three resources that were never going to
-- move.
--
-- The permission is therefore checked FIRST. `IsPrincipalAceAllowed` asks the
-- same question the command will, and when the answer is no the harness says
-- so and hands the action to the operator instead of pretending it tried.
function CisTestControl.Can(command)
    if type(IsPrincipalAceAllowed) ~= 'function' then
        -- No way to ask. Assume allowed and let the state poll decide.
        return true, 'unknown'
    end
    -- IsPrincipalAceAllowed takes TWO arguments: the object whose permissions
    -- are being checked, and the principal.
    --
    -- The OBJECT is the resource ACE principal, which FiveM names
    -- 'resource.cis_test' -- NOT the bare resource name. add_ace registers
    -- 'resource.cis_test', so asking about 'cis_test' asks about a principal
    -- that was never created and the answer is always no -- which looks
    -- exactly like a missing ACE, and sent the first two lifecycle runs
    -- down the hand-driven path with the cfg looking correct.
    --
    -- Called with ONE argument it treats the principal as nil and raises,
    -- which the first run reported as a stack trace out of Can rather than
    -- as a permission problem.
    local ok, allowed = pcall(IsPrincipalAceAllowed,
        'resource.' .. GetCurrentResourceName(), 'command.' .. command)
    if not ok then
        -- Could not ask. Say so rather than guessing either way: a false
        -- 'denied' would block the tier forever, and a false 'granted' would
        -- go back to waiting for something that will never move.
        return true, 'unqueryable: ' .. tostring(allowed)
    end
    if allowed then return true, 'granted' end
    return false, 'denied'
end

-- Asks the server to run a command, and says whether it was allowed to.
--
-- Returns ok, mode, detail -- where mode is 'executed', 'refused' or 'unknown'.
-- It is not enough for ExecuteCommand to RETURN: an execution with no ACE does
-- not raise, it does nothing. So a refusal is detected by polling and never
-- arriving, which is why every caller polls afterwards rather than trusting the
-- return.
function CisTestControl.TryCommand(command)
    local ok, err = pcall(ExecuteCommand, command)
    if not ok then
        return false, 'refused', tostring(err)
    end
    return true, 'executed', nil
end

-- Waits for a resource to reach a state.
function CisTestControl.WaitForState(resource, want, timeoutMs)
    local deadline = GetGameTimer() + (timeoutMs or STATE_TIMEOUT_MS)
    while GetGameTimer() < deadline do
        if GetResourceState(resource) == want then return true end
        Wait(POLL_MS)
    end
    return GetResourceState(resource) == want
end

-- Starts a resource and waits for it.
--
-- `refresh` first, when asked, because FiveM caches the manifest: a resource
-- whose fxmanifest has changed is invisible to `ensure` until the cache is
-- dropped, and `restart` does not drop it. Getting that wrong is how a harness
-- ends up testing yesterday's build.
function CisTestControl.Start(resource, opts)
    opts = opts or {}
    local allowed = CisTestControl.Can('ensure')
    if not allowed then
        -- The plan's fallback: say exactly what a human has to type, and record
        -- that this run was hand-driven so the result does not read as
        -- automated coverage it is not.
        return false, CisTestControl.AskOperator('ensure ' .. resource)
    end
    if opts.refresh then
        if CisTestControl.Can('refresh') then
            CisTestControl.TryCommand('refresh')
            Wait(500)
        else
            CisTestControl.AskOperator('refresh')
            Wait(500)
        end
    end
    CisTestControl.TryCommand('ensure ' .. resource)
    return CisTestControl.WaitForState(resource, 'started')
end

function CisTestControl.Stop(resource, timeoutMs)
    if not CisTestControl.Can('stop') then
        return false, CisTestControl.AskOperator('stop ' .. resource)
    end
    CisTestControl.TryCommand('stop ' .. resource)
    -- 'stopped' is the resting state; 'stopping' means FiveM accepted it and is
    -- still tearing the resource down, which is a different answer.
    local ok = CisTestControl.WaitForState(resource, 'stopped', timeoutMs)
    if not ok then ok = CisTestControl.WaitForState(resource, 'stopped', 2000) end
    return ok
end

-- Asks for the operator to type something, when the ACEs are not in place.
--
-- Returns a marker string the case records, so a result carries "this was
-- driven by hand" instead of quietly reading as automated coverage.
function CisTestControl.AskOperator(command)
    print(('[cis_test] ACTION: %s'):format(command))
    return 'hand-driven: ' .. command
end

-- THE SPLIT RESTART.
--
-- Restarting cis_libs takes cis_test down with it, because cis_test depends on
-- it -- so a harness that restarted it from inside a running case would simply
-- vanish mid-run. The plan splits it into two phases for exactly this reason:
--
--   cis_test phase libs_restart_before   record what is about to change
--   (the operator restarts cis_libs, which stops cis_test)
--   cis_test phase libs_restart_after    assert what actually happened
--
-- The second phase runs in a FRESH cis_test, which has no memory of the first.
-- So the first phase writes what it saw to a file, and the second reads it.
function CisTestControl.WritePhase(name, payload)
    return SaveResourceFile(GetCurrentResourceName(), 'phase.json',
        CisTestJson.encode(payload), -1)
end

function CisTestControl.ReadPhase()
    local ok, text = pcall(LoadResourceFile, GetCurrentResourceName(), 'phase.json')
    if not ok or type(text) ~= 'string' or text == '' then
        return nil, 'no phase file'
    end
    -- The harness has a decoder only on the client, so the phase file is read
    -- as text and the two fields it needs are matched directly rather than
    -- pulling a JSON parser into the server realm for one file.
    return { raw = text }
end

-- Counts every resource the harness cares about, for the before/after compare.
function CisTestControl.ResourceStates()
    local out = {}
    for _, r in ipairs({ 'cis_libs', 'cis_test_providers', 'cis_test_b', 'cis_test_badmeta', 'cis_test' }) do
        out[r] = GetResourceState(r)
    end
    return out
end

return true