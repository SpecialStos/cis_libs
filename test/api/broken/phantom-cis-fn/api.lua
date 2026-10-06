-- Broken on purpose: a `Cis.*` function declared in api.lua that init.lua does not define.
--
-- The other direction, and it is the worse one. A consumer reading this in
-- their completions calls it, gets "attempt to call a nil value", and reads
-- that as cis_libs being broken rather than as a documentation error -- because
-- nothing in the failure names the file that lied.
local real = assert(loadfile(CIS_API_REAL))()
real.functions['Cis.zones.spiral'] = {
    since = '1.0.0', realm = 'client',
    params = {},
    returns = { { type = 'boolean', doc = 'nothing, because nothing exists' } },
}
return real
