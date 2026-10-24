-- Broken on purpose: DbQuery claims a release (9.9.9) newer than the product
-- version and newer than `unreleased`. An entry cannot be since a release that
-- does not exist.
--
-- Derived from the real manifest so the ONLY thing wrong with it is the one
-- thing this fixture is named for.
local real = assert(loadfile(CIS_API_REAL))()
real.exports.DbQuery.since = '9.9.9'
return real
