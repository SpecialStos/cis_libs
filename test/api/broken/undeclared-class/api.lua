-- Broken on purpose: a type that names a class nobody declared.
--
-- The failure mode this prevents is invisible in review. `CisSyncRecrd` reads as
-- a real type -- a typo, not a hole -- and the editor offers no completion for
-- it while a human reading api.lua sees nothing wrong.
local real = assert(loadfile(CIS_API_REAL))()
local p = real.functions['Cis.sync.ped'].params
p[1].type = 'CisSyncRecrd'
return real
