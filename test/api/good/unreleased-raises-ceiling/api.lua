-- Clean on purpose: an entry written before the next bump says `since` the
-- release it will ship in, and `unreleased` names that release, so the
-- validator must accept it. Without the `unreleased` line the same entry fails
-- E014 (see broken/since-after-version).
--
-- Derived from the real manifest so the ONLY difference is one entry moved to
-- the next minor release.
local real = assert(loadfile(CIS_API_REAL))()
local major, minor = real.version:match('^(%d+)%.(%d+)%.%d+$')
local nextRelease = major .. '.' .. (tonumber(minor) + 1) .. '.0'
local moved = false
local function raise(t, seen)
    if moved or type(t) ~= 'table' or seen[t] then return end
    seen[t] = true
    if type(t.since) == 'string' then
        t.since = nextRelease
        moved = true
        return
    end
    for _, v in pairs(t) do raise(v, seen) end
end
for _, k in ipairs({ 'exports', 'events', 'modules', 'classes' }) do raise(real[k], {}) end
assert(moved, 'no entry with a since field to move')
real.unreleased = nextRelease
return real
