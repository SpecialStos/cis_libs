-- Broken on purpose: cis_libs:jobUpdated is fired by server/proxy.lua (in
-- PublishJobUpdate) and documented nowhere. It is the event the surface scanner
-- records as "registered and never declared" -- the failure mode that lets a
-- net event name drift away from its documentation, and the one this fixture
-- was written for before the split moved the doorlock events to cis_keys.
local real = assert(loadfile(CIS_API_REAL))()
real.events['cis_libs:jobUpdated'] = nil
return real
