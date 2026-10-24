-- Broken on purpose: `unreleased` equals `version`. The release it named has
-- shipped, so the line is stale and must be deleted at the bump.
--
-- Derived from the real manifest so the ONLY thing wrong with it is the one
-- thing this fixture is named for. The real manifest has entries that say
-- since 1.1.0; they are lowered to the version here, because otherwise the
-- since-ceiling rule would also fire and the fixture could not tell a validator
-- that checks `unreleased` from one that only checks `since`.
local real = assert(loadfile(CIS_API_REAL))()
local function lower(t, seen)
    if type(t) ~= 'table' or seen[t] then return end
    seen[t] = true
    for k, v in pairs(t) do
        if k == 'since' and v == real.unreleased then t[k] = real.version
        else lower(v, seen) end
    end
end
lower(real, {})
real.unreleased = real.version
return real
