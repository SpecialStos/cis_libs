-- Broken on purpose: DbQuery has no `since`.
--
-- `since` is the field a declaration cannot do without. Without it there is no
-- way to say when a consumer may start relying on the entry, and a consumer
-- reading the manifest has nothing to compare its own pinned version against.
--
-- Derived from the real manifest so the ONLY thing wrong with it is the one
-- thing this fixture is named for. A fixture that fails for some other reason
-- proves nothing about the check it claims to exercise.
local real = assert(loadfile(CIS_API_REAL))()
real.exports.DbQuery.since = nil
return real
