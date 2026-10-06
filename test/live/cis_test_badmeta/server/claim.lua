-- cis_test_badmeta's claim, which is expected to be REFUSED.
--
-- If this ever succeeds, the contract check is broken and every result that
-- depended on it is about nothing. So the claim is recorded either way, and the
-- harness asserts on the recorded outcome.

CisTestBadMeta = { attempts = {} }

CreateThread(function()
    local waited = 0
    while GetResourceState('cis_libs') ~= 'started' and waited < 100 do
        Wait(100)
        waited = waited + 100
    end
    if GetResourceState('cis_libs') ~= 'started' then
        print('[cis_test_badmeta] cis_libs never started')
        return
    end

    -- The capability whose slot the harness releases first. Claiming it while
    -- nothing holds it is the one moment this resource could plausibly succeed,
    -- which is exactly why the case exists.
    local ok, why = exports['cis_libs']:RegisterCapability(
        'migration', 'cis_test_badmeta:CisBadMetaMigration')
    CisTestBadMeta.attempts[#CisTestBadMeta.attempts + 1] = {
        slot = 'migration', ok = ok, why = why,
    }
    print(('[cis_test_badmeta] RegisterCapability(migration) -> ok=%s why=%s')
        :format(tostring(ok), tostring(why)))
end)

exports('Attempts', function() return CisTestBadMeta.attempts end)