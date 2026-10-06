-- Broken on purpose: an `any` with no recorded reason.
--
-- `any` is not banned, because a ban is met by a confident wrong type, and a
-- wrong type is worse than an honest one. What IS required is the reason: a
-- reader deciding whether the seam has moved needs to know WHICH provider
-- decides this, and a reason nobody wrote is a promise nobody checked.
local real = assert(loadfile(CIS_API_REAL))()
real.functions['Cis.db.query'].params[2].type = 'any'
real.functions['Cis.db.query'].params[2].why = nil
return real
