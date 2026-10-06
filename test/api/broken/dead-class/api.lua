-- Broken on purpose: a class no type references.
--
-- The other direction of E064. A class nothing names is not free: it reads as
-- coverage in a review, it will drift away from the code that produces it, and
-- the next person to add a type to it is editing a document with no consumer.
local real = assert(loadfile(CIS_API_REAL))()
real.classes.CisVehicleProps = nil
return real
