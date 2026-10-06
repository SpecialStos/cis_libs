-- Broken on purpose: a `Cis.*` function that api.lua does not declare.
--
-- This is the surface a consumer actually calls. init.lua is copied into their
-- Lua state by one manifest line, and the ONLY description of what those
-- functions take and answer is api.lua. A function defined there and absent
-- here has no completions, no types and no contract, and nobody finds out
-- until a consumer writes the call from memory and it is wrong.
local real = assert(loadfile(CIS_API_REAL))()
real.functions['Cis.log.debug'] = nil
return real
