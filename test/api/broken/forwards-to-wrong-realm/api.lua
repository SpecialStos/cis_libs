-- Broken on purpose: a client proxy that crosses to a server-only export.
--
-- The export exists and the NAME is right, which is why a check that only asks
-- "is there such an export" passes. The realms do not match: the server half of
-- this library is not in a client-side Lua state at all, so the call reaches a
-- nil and raises inside the caller's thread.
local real = assert(loadfile(CIS_API_REAL))()
real.functions['Cis.zones.box'].realm = 'client'
real.functions['Cis.zones.box'].forwardsTo = 'SyncCreate'
return real
