-- Broken on purpose: the declared signature does not match the source.
--
-- A renamed parameter is harmless. A parameter ADDED, REMOVED or REORDERED is
-- not, and the shift lands silently in exactly the way the `self` trap does --
-- the call succeeds and every argument is one place out. This is the check that
-- makes api.lua a contract rather than a comment.
local real = assert(loadfile(CIS_API_REAL))()
-- server/inventory.lua registers InventoryAdd(src, item, amount, metadata)
real.exports.InventoryAdd.signature = '(src, item)'
return real
