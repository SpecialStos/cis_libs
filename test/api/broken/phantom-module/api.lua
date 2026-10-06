-- Broken on purpose: a module that cis_libs will happily LOAD, and which is
-- documented nowhere.
--
-- This is the failure the module cross-check exists to catch, and it is the one
-- that is invisible from the resource itself. Every other surface in this file
-- is discovered by SCANNING the source -- an export that is registered, an event
-- that is fired -- so a declaration drifts and the scan notices. A module is the
-- other way round: nothing scans for it, it exists only because a name appears
-- in REQUIRE_MODULES, and a name nobody declared is a module that loads, works,
-- and appears in no documentation at all.
--
-- The reverse direction matters just as much and is covered by the same check:
-- declared here, absent from the allow-list, and therefore a name that raises
-- for every caller. Both are one code, because they are one disagreement.
local real = assert(loadfile(CIS_API_REAL))()
real.modules.phantom = { path = 'shared/algo/phantom.lua', since = '1.0.0' }
return real