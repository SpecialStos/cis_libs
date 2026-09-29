-- Executes registered tests in coroutines so a yield-based test (Await) can be
-- bounded by a deadline. FiveM-specific; report.lua stays native-free.
--
-- The test body receives its OWN context, already named after the test. That
-- matters: an earlier version handed bodies a capture callback, so a failing
-- assertion never reached the context and every test recorded as passed.

CisTestRunner = {}

local function clock()
    return GetGameTimer()
end

function CisTestRunner.new()
    return {
        tests = {},
    }
end

-- A test body may yield (Cis.callback.await). Run it in its own thread and
-- watch a deadline. Note: a FiveM thread cannot be killed, so an overrunning
-- body is abandoned rather than aborted. Keep test bodies bounded.
function CisTestRunner.run(fn, ctx, timeoutMs)
    local done, ok, err = false, true, nil

    CreateThread(function()
        ok, err = pcall(fn, ctx)
        done = true
    end)

    local deadline = clock() + (timeoutMs or 8000)
    while not done and clock() < deadline do
        Wait(20)
    end

    if not done then
        return ('timed out after %dms'):format(timeoutMs or 8000), true
    end
    -- Do not write this as `ok and nil or tostring(err)`: when ok is true,
    -- `ok and nil` is nil, so the `or` branch runs and a *passing* test is
    -- reported as a crash with the message "nil".
    if ok then
        return nil, false
    end
    return tostring(err), false
end

function CisTestRunner.register(runner, name, fn, options)
    options = options or {}
    runner.tests[#runner.tests + 1] = {
        name = name,
        fn = fn,
        timeoutMs = options.timeoutMs,
        -- Tags gate on config so a category can be switched off wholesale.
        mutating = options.mutating and true or false,
        probe = options.probe and true or false,
        teleport = options.teleport and true or false,
    }
end

function CisTestRunner.enabled(runner, test, config)
    if test.mutating and not config.RunMutating then
        return false, 'mutating tests disabled (set RunMutating = true to enable)'
    end
    if test.probe and not config.RunProbes then
        return false, 'boundary probes disabled (set RunProbes = true to enable)'
    end
    if test.teleport and not config.RunTeleport then
        return false, 'teleport tests disabled (set RunTeleport = false to run them)'
    end
    return true
end

function CisTestRunner.execute(runner, report, config, onProgress)
    local results = {}
    for i = 1, #runner.tests do
        local test = runner.tests[i]
        local started = clock()

        -- One context per test, named after the test. The body mutates this
        -- exact object, so a failure or a crash always lands on the right row.
        local ctx = CisTestReport.context(report, test.name)

        local allowed, reason = CisTestRunner.enabled(runner, test, config)
        if not allowed then
            ctx.skip(reason)
        else
            local err, timedOut = CisTestRunner.run(test.fn, ctx, test.timeoutMs)
            if err then
                ctx.fail(timedOut and 'timeout' or 'crash', err)
            end
        end

        local entry = CisTestReport.finish(report, ctx, clock() - started)
        results[#results + 1] = entry
        if onProgress then
            onProgress(entry, i, #runner.tests)
        end
    end
    return results
end
