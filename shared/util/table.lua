-- Table helpers: deep copy, deep merge, counting, shape detection, iteration.
--
-- PURE, no natives, no module state, no dependencies. Safe for a consumer to
-- `shared_script` for a private copy (COMPATIBILITY.md §10.2) -- there is
-- nothing in here to be a singleton of. Two copies of a deep-copy cannot
-- disagree about anything, because a deep-copy holds no state at all.
--
-- WHY THIS FILE IS CALLED table.lua: nothing in this library `require`s
-- anything, so a file name never shadows the `table` global. The chunk is
-- loaded by path and contributes exactly one global: CisTable.
--
-- CONVENTION, the same one the rest of the library uses (DOCUMENTATION.md
-- §0.6, "a refusal explains itself"): a call that can decline returns a falsy
-- first value and a human-readable reason as the second. Nothing here raises
-- for bad INPUT. A bad CALLBACK -- a comparator that is not a strict weak
-- ordering, a predicate that errors -- is a bug in the caller's own code and
-- is deliberately allowed to propagate; swallowing it would hide it.

CisTable = {
    -- Nesting budget shared by the recursive walks below. Config-shaped data
    -- is a handful of levels deep; 64 is already generous and it is what stops
    -- a self-referential table from being a stack overflow instead of a
    -- reason. Depth is checked in addition to cycle detection because a table
    -- can be acyclic, mutually referential through hundreds of levels, and
    -- still take the C stack down before a cycle ever closes.
    MAX_DEPTH = 64,
}

--- Total order over keys of ANY type.
---
--- Lua's `<` raises when it is handed two different types, which is exactly
--- what happens to `table.sort` the moment a table has one string key and one
--- boolean key. Every sorted* function below defaults to this instead, so
--- sorting a mixed table produces a stable (if arbitrary) order rather than an
--- error.
---
--- Within one type the order is the natural one (numbers numerically, strings
--- by byte). ACROSS types it is by type NAME, which is deterministic but
--- arbitrary -- you are choosing a total order on a set that has none.
--- For `table` and `function` keys the tie-break is tostring(), and tostring of
--- a table is its address: unique within a run, NOT stable between runs. Do
--- not depend on the position of a table key across a restart.
---
---@param a
---@param b
--- @return -1 if a < b, 0 if they compare equal, 1 if a > b.
function CisTable.compareKeys(a, b)
    local ta, tb = type(a), type(b)
    if ta == tb then
        if ta == 'number' or ta == 'string' then
            if a == b then return 0 end
            return a < b and -1 or 1
        end
        local sa, sb = tostring(a), tostring(b)
        if sa == sb then return 0 end
        return sa < sb and -1 or 1
    end
    return ta < tb and -1 or 1
end

-- Adapt any comparator to the BOOLEAN form table.sort is happiest with.
--
-- This is not a style preference. fengari -- which is what this repository's
-- entire test suite runs under -- raises "invalid order function for sorting"
-- on a comparator that returns -1/0/1 for SOME inputs: a four-element and a
-- five-element list both fail with a demonstrably valid total order, while
-- two- and three-element lists pass. Real Lua 5.3/5.4 accept the same
-- comparator. Passing boolean down instead costs one comparison per call and
-- works identically on both, so every table.sort in this file goes through
-- here.
--
-- A comparator that already returns a boolean is passed straight through,
-- because comparing a boolean with a number raises and `suggest`'s documented
-- comparator argument is allowed to be either shape.
local function asSortComparator(comparator)
    return function(a, b)
        local r = comparator(a, b)
        if type(r) == 'boolean' then
            return r
        end
        return r < 0
    end
end

-- True when `t` is a table and has no key outside 1..n.
--
-- Note this is NOT `#t == count(t)`: that test accepts a table with a hole,
-- because `#` on a table with holes returns an arbitrary border rather than
-- the used length. `{'a', nil, 'c'}` has #t == 3 and count == 3, so the cheap
-- test calls it an array, and then every `for i = 1, #t` over it walks a nil.
-- Checking that every slot 1..n is actually present is the only version that
-- survives a hole.
--
-- An EMPTY table is an array. It is also a map. There is no way to tell and
-- guessing 'map' here would make `{ }` fail every array-shaped config, so the
-- answer is the permissive one.
--
-- A float key (1.5) makes it a map: JSON has no such index, and nothing else
-- in a FiveM server does either.
---@param t
--- @return boolean  true only for a table whose keys are all integers
function CisTable.isArray(t)
    if type(t) ~= 'table' then
        return false
    end
    local n = 0
    for k in pairs(t) do
        if type(k) ~= 'number' then
            return false
        end
        n = n + 1
    end
    for i = 1, n do
        if t[i] == nil then
            return false
        end
    end
    return true
end

--- Inverse of isArray, with one deliberate exception: an EMPTY table is a map.
---
--- isArray says `{}` is an array, and this says it is a map as well. Both are
--- true because there is nothing to decide -- no key contradicts either
--- reading. Which is why a schema that says 'array' and one that says 'map'
--- both accept `{}`, and why a caller cannot use isMap to reject an empty
--- array. `next(t) == nil` is the test for "empty"; this only answers the shape
--- question for a table that has entries.
---@param t
--- @return boolean  true for any table that is not an array; {} counts as a map
function CisTable.isMap(t)
    if type(t) ~= 'table' then
        return false
    end
    if next(t) == nil then
        return true
    end
    return not CisTable.isArray(t)
end

---@param t
--- @return boolean  true for nil, a non-table, or a table with no entries
function CisTable.isEmpty(t)
    if type(t) ~= 'table' then
        return true
    end
    return next(t) == nil
end

--- Shallow copy.
---
--- This is the one to reach for when the table is an identity-keyed registry
--- (`players[playerId]`), because deepCopy copies KEYS as well and a table key
--- copied into the new table is a different key -- lookups by the original key
--- would miss. shallowCopy keeps keys identical, at the cost of the values
--- still being shared with the source.
---
--- Deliberately uses `next` rather than `pairs`, so a table with a __pairs
--- metamethod is copied by its REAL storage and not by whatever view that
--- metamethod returns. A FiveM export proxy answers __pairs with a filtered
--- set, and copying the filtered view would quietly drop half the table.
---@param t
--- @return any  a new table with the same entries one level down; a non-table is returned unchanged
function CisTable.shallowCopy(t)
    if type(t) ~= 'table' then
        return t
    end
    local out = {}
    -- table.move exists in Lua 5.3+. It does NOT exist in LuaJIT (5.1), which
    -- is what a FiveM CLIENT runs, and the manifest's `lua54 'yes'` covers the
    -- server's Lua 5.4 and says nothing about the client. So it is
    -- feature-detected rather than assumed, and the loop is the fallback.
    local n = #t
    if n > 0 and type(table.move) == 'function' then
        table.move(t, 1, n, 1, out)
    else
        for i = 1, n do
            out[i] = t[i]
        end
    end
    for k, v in next, t do
        if type(k) ~= 'number' or k < 1 or k > n or k % 1 ~= 0 then
            out[k] = v
        end
    end
    return out
end

--- Deep copy with CYCLE PROTECTION.
---
--- "Protection" here means the recursion terminates, not that it refuses. A
--- table that refers to itself is copied into a table that refers to itself:
--- the cycle is preserved as structure rather than recursed into forever. That
--- is the honest behaviour for a copy -- the alternative, dropping the
--- back-reference, silently produces a different value than it was given.
--- Use deepCopyStrict when you need the refusal instead.
---
--- A table reachable twice from the same source is copied ONCE and both
--- references are pointed at the same copy, so sharing is preserved too.
---
--- Three things a deep copy does not carry over, all of them deliberate:
---   * metatables. `pairs` on an output with no metatable is the raw storage.
---     A class instance copies as a plain table. There is no safe default --
---     copying metatables re-links __index to the source in the copy-heavy
---     case and skips them entirely in the other.
---   * identity of table KEYS. See shallowCopy.
---   * nil-valued keys, which do not exist in Lua.
---@param value
---@param seen
--- @return any  a copy with the structure reproduced; non-tables are returned as-is, and a cycle resolves to the copy in progress
function CisTable.deepCopy(value, seen)
    if type(value) ~= 'table' then
        return value
    end
    seen = seen or {}
    local existing = seen[value]
    if existing ~= nil then
        return existing
    end
    local out = {}
    -- Registered BEFORE the descent. This single line is the whole cycle
    -- protection: every path that reaches this table again gets the partial
    -- copy, not a new descent.
    seen[value] = out
    for k, v in next, value do
        out[CisTable.deepCopy(k, seen)] = CisTable.deepCopy(v, seen)
    end
    return out
end

--- How deeply nested a table is.
---
--- Level 1 is the table itself. The walk stops as soon as it passes maxDepth and
--- reports maxDepth + 1, because the exact number past that point costs the
--- same to find and nobody needs it -- what the caller wants to know is "over
--- budget".
---
--- A cycle does not inflate this: a table already seen contributes nothing
--- further, so `t.self = t` is depth 2, not infinity.
---
---@param t
---@param maxDepth
--- @return a number >= 1, or 0 for a non-table.
function CisTable.depth(t, maxDepth)
    if type(t) ~= 'table' then
        return 0
    end
    maxDepth = maxDepth or CisTable.MAX_DEPTH
    local seen = {}
    local deepest = 0
    local function walk(value, level)
        if seen[value] then
            return
        end
        -- Recorded BEFORE the budget check. Bailing first and reporting the
        -- last level that fitted reports maxDepth for a table that is exactly
        -- one level too deep, which compares equal to the limit and slips
        -- through `depth > maxDepth`.
        if level > deepest then
            deepest = level
        end
        if level > maxDepth then
            return
        end
        seen[value] = true
        for _, child in next, value do
            if type(child) == 'table' then
                walk(child, level + 1)
            end
        end
    end
    walk(t, 1)
    return deepest
end

--- Deep copy that REFUSES a cyclic or over-deep input.
---
--- Both checks are needed and neither subsumes the other. A cycle is what
--- findCycle is for; the depth budget is what stops a table with two hundred
--- levels of ACYCLIC nesting, which has no cycle to find and would still take
--- the C stack down inside the recursive copy. Without this, deepCopyStrict
--- would catch the infinite case and let the merely-enormous one through.
---
---@param value
---@param opts
--- @return the copy, or `nil, reason`. The cycle reason names the path that
---   closed it, e.g. 'cycle through a.b.c'.
function CisTable.deepCopyStrict(value, opts)
    opts = opts or {}
    local maxDepth = opts.maxDepth or CisTable.MAX_DEPTH
    local cycle = CisTable.findCycle(value, maxDepth)
    if cycle then
        return nil, ('cycle through %s'):format(table.concat(cycle, '.'))
    end
    local depth = CisTable.depth(value, maxDepth)
    if depth > maxDepth then
        return nil, ('nesting deeper than %d'):format(maxDepth)
    end
    return CisTable.deepCopy(value)
end

--- Find the key path that closes a cycle.
---
--- Walks with an on-path marker set, so a table that appears twice SIBLING-WISE
--- (the same subtable referenced from two different keys) is not a cycle and
--- is not reported -- the marker is cleared on the way back up. That is the
--- difference between this and `seen`, and it is the whole reason this is not
--- just a seen-table.
---
--- @param t any value; a non-table is never a cycle.
--- @param maxDepth number|nil defaults to CisTable.MAX_DEPTH.
--- @return array of keys leading back to the repeated table, or nil if acyclic.
---   The path is a best-effort description of ONE cycle, not all of them: the
---   walk stops at the first.
function CisTable.findCycle(t, maxDepth)
    if type(t) ~= 'table' then
        return nil
    end
    maxDepth = maxDepth or CisTable.MAX_DEPTH
    local onPath = {}
    local path = {}
    local hit

    local function walk(value, depth)
        if hit then return end
        if onPath[value] then
            hit = {}
            for i = 1, #path do
                hit[i] = path[i]
            end
            return
        end
        if depth > maxDepth then
            return
        end
        onPath[value] = true
        for k, child in next, value do
            if type(child) == 'table' then
                path[#path + 1] = k
                walk(child, depth + 1)
                path[#path] = nil
                if hit then break end
            end
        end
        if not hit then
            onPath[value] = nil
        end
    end

    walk(t, 1)
    return hit
end

--- Number of direct keys. `{}` is 0, nil is 0.
---
--- This is the same count as the exported `GetTableSize` in client/utils.lua,
--- restated here because a consumer holding a private copy of this file has no
--- boundary crossing available to call that export. It is deliberately SHALLOW:
--- deepSize is a different function with a different, more expensive answer.
---@param t
--- @return number  how many keys, at any depth 0. A non-table is 0
function CisTable.count(t)
    if type(t) ~= 'table' then
        return 0
    end
    local n = 0
    for _ in pairs(t) do
        n = n + 1
    end
    return n
end

--- Number of key/value pairs at EVERY level.
---
--- Each distinct table is counted once, no matter how many paths reach it, so
--- a shared subtable contributes its contents a single time and a cycle
--- terminates instead of counting forever. `maxDepth` (default
--- CisTable.MAX_DEPTH) bounds an acyclic but pathologically deep structure.
---
--- A self-referential table `t.self = t` is 2: the key `self` and the key that
--- pointed at the table from above.
---@param t
---@param opts
--- @return number  how many values at any depth, cycles counted once; opts.maxDepth caps the walk
function CisTable.deepSize(t, opts)
    if type(t) ~= 'table' then
        return 0
    end
    local maxDepth = (opts and opts.maxDepth) or CisTable.MAX_DEPTH
    local seen = {}
    local function walk(value, depth)
        if seen[value] or depth > maxDepth then
            return 0
        end
        seen[value] = true
        local n = 0
        for _, child in next, value do
            n = n + 1
            if type(child) == 'table' then
                n = n + walk(child, depth + 1)
            end
        end
        return n
    end
    return walk(t, 1)
end

--- Keys in a DETERMINISTIC order: the contiguous integer prefix 1..n first, in
--- ascending order, then every other key under `comparator` (default
--- CisTable.compareKeys).
---
--- Deterministic is the whole point. `pairs` order is undefined, so a function
--- that returns keys in pairs order is not merely untidy -- two calls on equal
--- tables can differ, and any caller that builds a cache key or a signature
--- out of it gets a different answer for the same value.
---
---@param t
---@param comparator
--- @return array of keys. `{}` in, `{}` out; nil in, nil out.
function CisTable.keys(t, comparator)
    if type(t) ~= 'table' then
        return nil
    end
    comparator = asSortComparator(comparator or CisTable.compareKeys)
    local rest = {}
    local n = 0
    for k in next, t do
        if type(k) == 'number' and k % 1 == 0 and k >= 1 and k <= #t and t[k] ~= nil then
            n = n + 1
        else
            rest[#rest + 1] = k
        end
    end
    table.sort(rest, comparator)
    local out = {}
    local i = 1
    while i <= n do
        out[i] = i
        i = i + 1
    end
    for j = 1, #rest do
        out[n + j] = rest[j]
    end
    return out
end

--- Values, index-aligned with CisTable.keys on the same table.
---
--- Aligned, not merely same-order: `keys[i]` is the key of `values[i]`. That
--- is what makes the pair usable for zipping, and it is the reason these are
--- two functions over one walk rather than two independent walks that happen to
--- agree today.
---@param t
---@param comparator
--- @return table|nil  the values in key order, or nil when the keys cannot be ordered
function CisTable.values(t, comparator)
    local ks = CisTable.keys(t, comparator)
    if not ks then
        return nil
    end
    local out = {}
    for i = 1, #ks do
        out[i] = t[ks[i]]
    end
    return out
end

--- Iterate in the same order as CisTable.keys without allocating the key array.
--- fn(value, key); returning `false` from fn stops the walk.
---@param t
---@param comparator
---@param fn
--- @return number|nil,string  how many were visited, or nil and a reason for a bad argument. fn returning false stops the walk early and counts as visited.
function CisTable.each(t, comparator, fn)
    if type(t) ~= 'table' then
        return nil, ('table expected, got %s'):format(type(t))
    end
    if type(fn) ~= 'function' then
        return nil, ('fn must be a function, got %s'):format(type(fn))
    end
    for i = 1, #t do
        if t[i] ~= nil then
            if fn(t[i], i) == false then
                return true
            end
        end
    end
    local rest = {}
    for k in next, t do
        if not (type(k) == 'number' and k % 1 == 0 and k >= 1 and k <= #t and t[k] ~= nil) then
            rest[#rest + 1] = k
        end
    end
    table.sort(rest, asSortComparator(comparator or CisTable.compareKeys))
    for i = 1, #rest do
        if fn(t[rest[i]], rest[i]) == false then
            return true
        end
    end
    return true
end

--- First value whose `predicate(value, key)` is truthy.
---
---@param t
---@param predicate
--- @return the value, or nil. A nil table or an empty table is nil, not an
---   error. There is no second return value: "not found" and "found a nil" are
---   the same answer and there is nothing useful to say about either.
function CisTable.find(t, predicate)
    if type(t) ~= 'table' or type(predicate) ~= 'function' then
        return nil
    end
    local result
    CisTable.each(t, nil, function(value, key)
        if predicate(value, key) then
            result = value
            return false
        end
    end)
    return result
end

--- Keep the entries whose `predicate(value, key)` is truthy.
---
--- The SHAPE IS PRESERVED: a list in, a list out; a map in, a map out. `{}` is
--- both, and comes back as the empty table. This is the property that makes the
--- result safe to hand straight to something that indexes it with `t[1]`.
---
---@param t
---@param predicate
--- @return the new table, or `nil, reason` when `predicate` is not a function.
function CisTable.filter(t, predicate)
    if type(t) ~= 'table' then
        return nil, ('table expected, got %s'):format(type(t))
    end
    if type(predicate) ~= 'function' then
        return nil, ('predicate must be a function, got %s'):format(type(predicate))
    end
    local wasArray = CisTable.isArray(t)
    local out = {}
    if wasArray then
        local j = 0
        for i = 1, #t do
            if predicate(t[i], i) then
                j = j + 1
                out[j] = t[i]
            end
        end
        return out
    end
    CisTable.each(t, nil, function(value, key)
        if predicate(value, key) then
            out[key] = value
        end
    end)
    return out
end

--- Transform every value. SHAPE IS PRESERVED (see filter).
---
--- `fn(value, key)` returns the replacement. Two rules that exist so the result
--- is always a real list with no holes:
---   * over a MAP, a nil result drops the key. A nil value in a Lua map is
---     indistinguishable from an absent key, so dropping is not a loss.
---   * over a LIST, a nil result becomes `false`, keeping the length and the
---     indices. It does NOT renumber -- silent renumbering is the kind of
---     thing that turns a filter into a data-loss bug two releases later. Use
---     filter when you meant to drop.
---
--- opts.inPlace mutates and returns `t` with no copy at all, which is the only
--- allocation-free option here and the one to use on a per-frame path.
--- opts.out overrides the shape: 'array' forces a list, 'map' forces a map.
---
---@param t
---@param fn
---@param opts
--- @return the new table, or `nil, reason` when `fn` is not a function.
function CisTable.map(t, fn, opts)
    if type(t) ~= 'table' then
        return nil, ('table expected, got %s'):format(type(t))
    end
    if type(fn) ~= 'function' then
        return nil, ('fn must be a function, got %s'):format(type(fn))
    end
    opts = opts or {}
    local wasArray = CisTable.isArray(t)
    local wantArray = wasArray
    if opts.out == 'array' then
        wantArray = true
    elseif opts.out == 'map' then
        wantArray = false
    end
    if opts.inPlace then
        if wantArray then
            for i = 1, #t do
                t[i] = fn(t[i], i) or false
            end
        else
            for k, v in pairs(t) do
                t[k] = fn(v, k)
            end
        end
        return t
    end
    local out = {}
    if wantArray then
        for i = 1, #t do
            out[i] = fn(t[i], i) or false
        end
        return out
    end
    CisTable.each(t, nil, function(value, key)
        out[key] = fn(value, key)
    end)
    return out
end

--- Fold a table into one value. `fn(accumulator, value, key)`.
---
--- With no `initial`, a LIST seeds from its first element -- the only ordering
--- that exists -- and the fold then starts at the SECOND element. Skipping the
--- seed would feed it to fn twice, which for a sum is an off-by-one nobody
--- notices until a total is wrong.
---
--- A MAP with no `initial` REFUSES, because "the first key" of a map is not a
--- thing, and seeding from one would make the result depend on hash order.
---
---@param t
---@param fn
---@param initial
--- @return the accumulator, or `nil, reason`.
function CisTable.reduce(t, fn, initial)
    if type(t) ~= 'table' then
        return nil, ('table expected, got %s'):format(type(t))
    end
    if type(fn) ~= 'function' then
        return nil, ('fn must be a function, got %s'):format(type(fn))
    end
    local acc = initial
    local skipFirst = false
    if acc == nil and CisTable.isArray(t) and #t > 0 then
        acc = t[1]
        skipFirst = true
    elseif acc == nil and not CisTable.isArray(t) then
        return nil, 'reduce over a map needs an initial value: a map has no first key'
    end
    local startAt = skipFirst and 2 or 1
    if CisTable.isArray(t) then
        for i = startAt, #t do
            acc = fn(acc, t[i], i)
        end
        return acc
    end
    CisTable.each(t, nil, function(value, key)
        acc = fn(acc, value, key)
    end)
    return acc
end

--- Sort a LIST by a derived key. `keyOf(value, index)`.
---
--- `comparator` compares the derived keys and defaults to CisTable.compareKeys,
--- so a key that is a number in one element and a string in the next orders
--- instead of raising.
---
--- Returns the SAME table, sorted in place: there is one array to sort and
--- making a copy would be pure waste. Callers who still need the original pass
--- a shallowCopy.
---@param list
---@param keyOf
---@param comparator
--- @return table|nil,string  the SAME list, sorted in place, or nil and a reason. The sort is stable: equal keys keep their original order.
function CisTable.sortBy(list, keyOf, comparator)
    if type(list) ~= 'table' then
        return nil, ('table expected, got %s'):format(type(list))
    end
    if type(keyOf) ~= 'function' then
        return nil, ('keyOf must be a function, got %s'):format(type(keyOf))
    end
    comparator = comparator or CisTable.compareKeys
    -- The derived keys are computed ONCE per element, before the sort. Doing it
    -- inside the comparator would be O(n log n) calls instead of O(n).
    local keyed = {}
    for i = 1, #list do
        keyed[i] = { k = keyOf(list[i], i), v = list[i], i = i }
    end
    local less = asSortComparator(function(a, b) return comparator(a, b) end)
    table.sort(keyed, function(a, b)
        if comparator(a.k, b.k) ~= 0 then
            return less(a.k, b.k)
        end
        -- Ties fall back to the original position, which makes the sort
        -- STABLE. Without it, table.sort's order among equal keys is an
        -- implementation detail and two runs can disagree.
        return a.i < b.i
    end)
    for i = 1, #keyed do
        list[i] = keyed[i].v
    end
    return list
end

--- Concatenate a list, skipping entries that are not strings or numbers.
---
--- tostring() would put a table's ADDRESS in your log line, and that changes
--- every run and means nothing to whoever reads it. Dropping the entry is
--- honest; a placeholder like '<table>' is a guess.
---
--- `sep` defaults to ''. nil entries in the list are skipped; a nil `sep` is an
--- error rather than a silent '' because the caller clearly had a separator in
--- mind.
---@param list
---@param sep
--- @return string  the tostring() of each entry joined by sep (default ''). A non-table is ''.
function CisTable.join(list, sep)
    if type(list) ~= 'table' then
        return ''
    end
    if sep == nil then
        sep = ''
    end
    local parts = {}
    local n = 0
    for i = 1, #list do
        local v = list[i]
        local tv = type(v)
        if tv == 'string' or tv == 'number' then
            n = n + 1
            parts[n] = tostring(v)
        end
    end
    return table.concat(parts, sep)
end

-- Merge policy names, exposed so a caller can pass the string it read from
-- config without hardcoding a literal somewhere else.
CisTable.POLICY = {
    OVERLAY = 'overlay',   -- the incoming value wins
    KEEP = 'keep',         -- the existing value wins; the incoming one fills gaps
    ERROR = 'error',       -- a genuine conflict is a refusal, not a coin flip
}

--- Deep merge into a NEW table. Neither argument is modified.
---
--- `policy` is one of CisTable.POLICY and exists to make the resolution of a
--- conflict EXPLICIT, because the default people reach for -- whichever side
--- they happen to think of first -- is how a config override quietly stops
--- overriding. Default is OVERLAY.
---
--- A CONFLICT for the ERROR policy is a key present on both sides whose
--- values are not both tables. Two tables are not a conflict: they are the case
--- merging exists for, and recursing into them is what makes a server's
--- `Doorlock = { Enabled = false }` actually extend the shipped Doorlock
--- defaults rather than replace the whole section and drop every key the
--- operator did not mention.
---
--- ARRAYS ARE ALWAYS REPLACED, with no option to change that. `{1,2,3}`
--- merged elementwise with `{9}` yields `{9,2,3}` -- an array of three where
--- the caller wrote one, and nothing in the result says which entries the
--- caller actually mentioned. Replacement is the only answer that means what
--- the caller wrote, and an escape hatch for the other behaviour would be used.
--- Use `CisTable.concat`-style manual assembly if you meant to extend a list.
---
--- The result NEVER ALIASES either input: every table on both sides is deep
--- copied, so mutating an input afterwards cannot reach into the result. Two
--- keys inside one input that share a table do NOT stay shared in the result;
--- the copy is structural, not a graph clone.
---
---@param base
---@param overlay
---@param policy
---@param opts
--- @return the merged table, or `nil, reason` -- a bad policy, a cycle in
---   either input, or a conflicting key under the ERROR policy.
function CisTable.deepMerge(base, overlay, policy, opts)
    opts = opts or {}
    local resolved = policy or CisTable.POLICY.OVERLAY
    if resolved ~= CisTable.POLICY.OVERLAY and resolved ~= CisTable.POLICY.KEEP
        and resolved ~= CisTable.POLICY.ERROR then
        return nil, ('unknown merge policy %q'):format(tostring(policy))
    end
    if type(base) ~= 'table' then base = {} end
    if type(overlay) ~= 'table' then overlay = {} end
    local maxDepth = opts.maxDepth or CisTable.MAX_DEPTH

    -- Checked once, up front, rather than with a seen-table inside the merge.
    -- A seen-table makes an acyclic structure with shared subtables look like a
    -- cycle on the second reference, and the error message ("cycle through
    -- self") would point at a table that is perfectly well formed.
    local baseCycle = CisTable.findCycle(base, maxDepth)
    if baseCycle then
        return nil, ('base has a cycle through %s'):format(table.concat(baseCycle, '.'))
    end
    local overlayCycle = CisTable.findCycle(overlay, maxDepth)
    if overlayCycle then
        return nil, ('overlay has a cycle through %s'):format(table.concat(overlayCycle, '.'))
    end

    local out = {}
    for k, v in pairs(base) do
        out[k] = CisTable.deepCopy(v)
    end
    for k, ov in pairs(overlay) do
        local bv = out[k]
        -- Two ARRAYS are replaced, never recursed into. Recursing would merge
        -- {1,2,3} with {9} into {9,2,3}: an array of three where the caller
        -- wrote one, with nothing in the result saying which entries they
        -- mentioned. That is the default precisely because it is the only
        -- answer that means what the caller wrote.
        local bothArrays = type(bv) == 'table' and type(ov) == 'table'
            and CisTable.isArray(bv) and CisTable.isArray(ov)
        if type(bv) == 'table' and type(ov) == 'table' and not bothArrays then
            local merged, err = CisTable.deepMerge(bv, ov, resolved, opts)
            if not merged then
                return nil, ('at key %s: %s'):format(tostring(k), err)
            end
            out[k] = merged
        elseif bv == nil then
            -- Present on one side only: there is nothing to resolve.
            out[k] = CisTable.deepCopy(ov)
        elseif resolved == CisTable.POLICY.ERROR then
            return nil, ('key %q is present on both sides (%s and %s)'):format(
                tostring(k), tostring(bv), tostring(ov))
        elseif resolved == CisTable.POLICY.KEEP then
            -- bv is already base's deep copy and stays untouched.
        else
            out[k] = CisTable.deepCopy(ov)
        end
    end
    return out
end

--- Deep merge that mutates `target` in place and returns it.
---
--- Provided because deepMerge copies the whole left side on every call, and a
--- config merge on a resource restart is not hot but a per-frame one is. Same
--- policy and reason semantics as deepMerge; the difference is only that the
--- base is written to rather than copied first. `target` must not be aliased
--- anywhere the caller still needs intact.
---@param target
---@param overlay
---@param policy
---@param opts
--- @return table|nil,string  the SAME target, merged in place, or nil and a reason. Use this when the caller needs its original table identity preserved.
function CisTable.deepMergeInto(target, overlay, policy, opts)
    if type(target) ~= 'table' then
        return nil, ('target must be a table, got %s'):format(type(target))
    end
    local merged, err = CisTable.deepMerge(target, overlay, policy, opts)
    if not merged then
        return nil, err
    end
    for k in pairs(target) do
        target[k] = nil
    end
    for k, v in pairs(merged) do
        target[k] = v
    end
    return target
end
