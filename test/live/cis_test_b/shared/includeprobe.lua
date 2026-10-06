-- WHAT A MANIFEST INCLUDE PASSES, MEASURED RATHER THAN ASSUMED.
--
-- WHAT A MANIFEST INCLUDE PASSES, MEASURED RATHER THAN ASSUMED.
--
-- Stage 5.1 branches on a marker: a module installs its legacy global when the
-- chunk did NOT receive the string cis_require. The plan for that task said to
-- verify live that a plain include receives NO vararg at all.
--
-- MEASURED ON run-20261005-010506: it receives ONE, and its value is 2. The
-- premise is false.
--
-- Nothing breaks, and the reason matters. The branch tests for the MARKER, not
-- for emptiness -- so an undocumented extra argument is simply not the marker,
-- and the direct-include path installs the global as intended. Had the branch
-- been written the other way round, install-when-there-IS-something, every
-- consumer @including a cis_libs module would have silently got nil.
--
-- This file exists because that premise was worth measuring rather than
-- believing, and because the number is now recorded where the next person can
-- see it instead of rediscovering it.
local probe = {
    varargCount = select('#', ...),
    firstVararg = (select(1, ...)),
}

exports('VarargProbe', function()
    return probe
end)

print(('[cis_test_b] include probe: %d vararg(s), first=%s'):format(
    probe.varargCount, tostring(probe.firstVararg)))
