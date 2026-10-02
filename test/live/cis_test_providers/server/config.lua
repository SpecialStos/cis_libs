-- The configuration the harness runs cis_libs under.
--
-- WHY THIS RESOURCE SUPPLIES IT RATHER THAN AN OPERATOR CONFIG FILE. The
-- allow-list has to name the harness, and an operator's config file is not
-- somewhere a test rig should be writing. SetConfig is first-supplier-wins, so
-- this runs after cis_libs has supplied its built-in defaults -- and those
-- defaults are NOT a supplier, because shared/registry.lua and server/proxy.lua
-- both carve cis_libs out of the conflict check for exactly this reason. So this
-- call is accepted, and a refusal here would mean that carve-out has regressed.
--
-- DropPlayer is FALSE and this is not negotiable from a test. The player safety
-- contract says the harness never removes the player, and the cheapest way to
-- make that true rather than merely intended is that nothing in the harness can.

CreateThread(function()
    local waited = 0
    while GetResourceState('cis_libs') ~= 'started' and waited < 100 do
        Wait(100)
        waited = waited + 100
    end
    if GetResourceState('cis_libs') ~= 'started' then
        print('[cis_test_providers] cis_libs never started; config not supplied')
        return
    end

    -- cis_test_b is deliberately NOT listed. It exists to be refused: the
    -- security cases need a resource that calls a mutating export and gets a
    -- refusal naming the fix, and an allow-list that named it would leave
    -- nothing to refuse.
    local ok, why = exports['cis_libs']:SetConfig({
        UpdateInterval = { Player = 500, Weapon = 500 },
    }, {
        EventPrefix = 'cis_libs',
        AuthorizedResources = { 'cis_test', 'cis_test_providers' },
        DropPlayer = false,
        CheckVersion = false,
    }, {
        DiscordLogsLinks = {},
    })

    if ok then
        print('[cis_test_providers] config supplied: cis_test, cis_test_providers authorized; DropPlayer off')
    else
        -- Printed, not raised. A harness that raises here takes the whole
        -- resource down and every slot with it, which turns one config problem
        -- into ten unexplained failures.
        print('[cis_test_providers] CONFIG REFUSED: ' .. tostring(why))
    end
end)