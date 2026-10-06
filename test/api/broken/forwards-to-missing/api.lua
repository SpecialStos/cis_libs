-- Broken on purpose: a proxy that crosses to an export nobody declares.
--
-- `forwardsTo` is the link between what a consumer calls and the export that
-- does the work. A name that is not an export is a proxy that calls nothing --
-- and the failure surfaces at runtime, in the consumer, as whatever the proxy
-- does with a nil.
local real = assert(loadfile(CIS_API_REAL))()
real.functions['Cis.zones.box'].forwardsTo = 'CreateZoneV2'
return real
