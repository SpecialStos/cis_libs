-- Client entry point. Waits for a run trigger, executes the client suite, and
-- submits the results to the server for aggregation.

local running = false

local function runSuite()
    if running then
        return
    end
    running = true

    CreateThread(function()
        if not Cis.wait(20000) then
            print('[cis_libstest] cis_libs never became ready; the client suite cannot run')
            running = false
            return
        end

        local report = CisTestReport.new()
        local ctx = CisTestReport.context(report, 'client')
        local suite = CisTestClientSuite.build(ctx, CisTestConfig)

        print(('[cis_libstest] running %d client tests...'):format(#suite.tests))

        local results = CisTestRunner.execute(suite, report, CisTestConfig, function(entry)
            if not CisTestConfig.Verbose then
                return
            end
            local line = ('[client] %-9s %s'):format(entry.status, entry.name)
            if entry.status == 'failed' then
                line = line .. ' -- ' .. tostring(entry.message)
                if entry.detail then
                    line = line .. ' (' .. tostring(entry.detail) .. ')'
                end
            elseif entry.status == 'skipped' then
                line = line .. ' (' .. tostring(entry.message) .. ')'
            end
            print(line)
        end)

        local failed, skipped = 0, 0
        for _, e in ipairs(results) do
            if e.status == 'failed' then
                failed = failed + 1
            elseif e.status == 'skipped' then
                skipped = skipped + 1
            end
        end
        print(('[cis_libstest] client done: %d tests, %d failed, %d skipped')
            :format(#results, failed, skipped))

        -- The report travels with the signal; the server needs the rows, not
        -- just a notification that they exist.
        TriggerServerEvent('cis_libstest:submit', results)
        running = false
    end)
end

RegisterNetEvent('cis_libstest:run', function()
    runSuite()
end)

RegisterCommand('cistest_client', function()
    runSuite()
end, false)
