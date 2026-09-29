-- Client entry point. Waits for a run trigger from the server, executes the
-- client suite, and submits the results back for aggregation.

local running = false
local debugCommandRegistered = false

local function runSuite()
    if running then
        return
    end
    running = true

    CreateThread(function()
        if not Cis.wait(20000) then
            print('[cis_libstest] cis_libs never became ready; client suite cannot run')
            running = false
            return
        end

        local report = CisTestReport.new()
        local ctx = CisTestReport.context(report, 'client')
        local suite = CisTestClientSuite.build(ctx, CisTestConfig)

        print(('[cis_libstest] running %d client tests...'):format(#suite.tests))

        local results = CisTestRunner.execute(suite, report, CisTestConfig, function(entry)
            if CisTestConfig.Verbose then
                local line = ('[client] %-9s %s'):format(entry.status, entry.name)
                if entry.status == 'failed' and entry.message then
                    line = line .. ' -- ' .. tostring(entry.message)
                end
                print(line)
            end
        end)

        local failed = 0
        for _, e in ipairs(results) do
            if e.status == 'failed' then
                failed = failed + 1
            end
        end
        print(('[cis_libstest] client done: %d tests, %d failed'):format(#results, failed))

        -- The report travels with the signal; the server needs the rows, not
        -- just a notification that they exist.
        TriggerServerEvent('cis_libstest:submit', results)
        running = false
    end)
end

RegisterNetEvent('cis_libstest:run', function()
    runSuite()
end)

-- Also let a tester drive the client half alone from their console.
RegisterCommand('cistest_client', function()
    runSuite()
end, false)

if not debugCommandRegistered then
    debugCommandRegistered = true
end
