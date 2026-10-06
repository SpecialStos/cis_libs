-- Broken on purpose: a `Cis.*` proxy parameter that is not the name in init.lua.
--
-- The proxy is hand-written and the name is what a consumer types. Renaming one
-- is not a rename: the exports boundary matches POSITIONALLY, so a swapped pair
-- compiles, runs, and puts the second argument where the first belongs -- with
-- nothing logging, because nothing failed.
local real = assert(loadfile(CIS_API_REAL))()
real.functions['Cis.db.query'].params[1].name = 'statement'
return real
