-- Broken on purpose: a declared parameter name is not the name in the code.
--
-- A renamed parameter is harmless. A parameter ADDED, REMOVED or REORDERED is
-- not, and the shift lands silently in exactly the way the `self` trap does --
-- the call succeeds and every argument is one place out. This is the check that
-- makes api.lua a contract rather than a comment, and it reads the source
-- rather than believing the declaration.
--
-- It used to mutate `signature`, which no longer exists: the type is the one
-- answer now, and a fixture pointing at a field the manifest does not have
-- would have gone on passing long after the rule it covered was gone.
local real = assert(loadfile(CIS_API_REAL))()
-- server/proxy.lua registers InventoryAdd(src, item, amount, metadata)
local p = real.exports.InventoryAdd.params
p[2].name = 'metadata'
p[3].name = 'amount'
return real
