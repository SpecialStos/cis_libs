-- Broken on purpose: cis_libs:client:toggleDoor is registered by
-- client/doorlock.lua and documented nowhere. It is the event MEMORY.md
-- recorded as "registered and never documented".
local real = assert(loadfile(CIS_API_REAL))()
real.events['cis_libs:client:toggleDoor'] = nil
return real
