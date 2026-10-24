-- Broken on purpose: an event claims a release (9.9.9) newer than the product
-- version and newer than `unreleased`. Events carry `since` like exports do, and
-- the same ceiling applies to them.
--
-- Derived from the real manifest so the ONLY thing wrong with it is the one
-- thing this fixture is named for.
local real = assert(loadfile(CIS_API_REAL))()
local name = next(real.events)
real.events[name].since = '9.9.9'
return real
