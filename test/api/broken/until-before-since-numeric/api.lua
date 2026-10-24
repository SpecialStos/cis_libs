-- Broken on purpose: until (9.0.0) is before since (10.0.0). Compared as
-- strings '9.0.0' sorts AFTER '10.0.0', so the old check let this through; the
-- versions have to be compared as numbers. (E014 fires too, for the same
-- since; the fixture requires E011.)
--
-- Derived from the real manifest so the ONLY thing wrong with it is the one
-- thing this fixture is named for.
local real = assert(loadfile(CIS_API_REAL))()
real.exports.DbQuery.since = '10.0.0'
real.exports.DbQuery['until'] = '9.0.0'
return real
