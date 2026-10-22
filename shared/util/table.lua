-- Table helpers: deep copy, deep merge, counting, shape detection, iteration.

local M = {
    -- Nesting budget shared by the recursive walks below.
    MAX_DEPTH = 64,
}

--- Total order over keys of ANY type.
--- @param a
--- @param b
--- @return -1 if a < b, 0 if they compare equal, 1 if a > b.
function M.compareKeys(a, b)
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
local function asSortComparator(comparator)
    return function(a, b)
        local r = comparator(a, b)
        if type(r) == 'boolean' then
            return r
        end
        return r < 0
    end
end

-- Length of the contiguous run t[1], t[2], ... that ends at the first nil.
--
-- NOT `#t`. On a table with a hole the length operator may answer any border,
-- so {1, nil, 3} can report 3 -- and a walk that trusted it counted keys 1 and
-- 3 as "the prefix", invented key 2, and lost key 3. The run is walked with
-- rawget because keys/each walk the table with raw `next`.
local function prefixLength(t)
    local n = 0
    while rawget(t, n + 1) ~= nil do
        n = n + 1
    end
    return n
end

local function inPrefix(k, n)
    return type(k) == 'number' and k >= 1 and k <= n and k % 1 == 0
end

-- True when `t` is a table and has no key outside 1..n.
--- @param t
--- @return boolean  true only for a table whose keys are all integers
function M.isArray(t)
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
--- @param t
--- @return boolean  true for any table that is not an array; {} counts as a map
function M.isMap(t)
    if type(t) ~= 'table' then
        return false
    end
    if next(t) == nil then
        return true
    end
    return not M.isArray(t)
end

--- @param t
--- @return boolean  true for nil, a non-table, or a table with no entries
function M.isEmpty(t)
    if type(t) ~= 'table' then
        return true
    end
    return next(t) == nil
end

--- Shallow copy. This is the one to reach for when the table is an identity-keyed
--- @param t
--- @return any  a new table with the same entries one level down; a non-table is returned unchanged
function M.shallowCopy(t)
    if type(t) ~= 'table' then
        return t
    end
    local out = {}
    -- table.move exists in Lua 5.3+.
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
--- @param value
--- @param seen
--- @return any  a copy with the structure reproduced; non-tables are returned as-is, and a cycle resolves to the copy in progress
function M.deepCopy(value, seen)
    if type(value) ~= 'table' then
        return value
    end
    seen = seen or {}
    local existing = seen[value]
    if existing ~= nil then
        return existing
    end
    local out = {}
    -- Registered BEFORE the descent.
    seen[value] = out
    -- VALUES are copied; KEYS are kept. A table used as a key is an identity --
    -- a set of players, a map from entity handle tables to state -- and a copy
    -- of the key is a different identity, so every lookup by the original key
    -- missed in the copy.
    for k, v in next, value do
        out[k] = M.deepCopy(v, seen)
    end
    return out
end

--- How deeply nested a table is.
--- @param t
--- @param maxDepth
--- @return a number >= 1, or 0 for a non-table.
function M.depth(t, maxDepth)
    if type(t) ~= 'table' then
        return 0
    end
    maxDepth = maxDepth or M.MAX_DEPTH
    -- `height[v]` is how many levels hang below v, INCLUDING v, once v has been
    -- walked completely. A table shared by two parents is walked once and its
    -- height reused, which keeps a DAG linear (the old seen-set did that too)
    -- and, unlike a seen-set, still counts the DEEPER of the two routes to it:
    -- whichever parent `next` reached first used to decide the answer.
    -- `onPath` stops a cycle; a cycle adds no depth.
    local height = {}
    local onPath = {}
    local function walk(value, level)
        local known = height[value]
        if known then
            return known
        end
        if onPath[value] then
            return 0
        end
        -- Past the budget the answer only has to say "deeper than maxDepth",
        -- so the walk stops there: this table counts as one level, unexplored.
        if level > maxDepth then
            return 1
        end
        onPath[value] = true
        local below = 0
        for _, child in next, value do
            if type(child) == 'table' then
                local h = walk(child, level + 1)
                if h > below then below = h end
            end
        end
        onPath[value] = nil
        local h = below + 1
        -- Only a walk the budget did not cut short is a true height, and only a
        -- true height may be reused from a shallower route.
        if level + h - 1 <= maxDepth then
            height[value] = h
        end
        return h
    end
    return walk(t, 1)
end

--- Deep copy that REFUSES a cyclic or over-deep input.
--- @param value
--- @param opts
--- @return the copy, or `nil, reason`. The cycle reason names the path that
function M.deepCopyStrict(value, opts)
    opts = opts or {}
    local maxDepth = opts.maxDepth or M.MAX_DEPTH
    local cycle = M.findCycle(value, maxDepth)
    if cycle then
        return nil, ('cycle through %s'):format(table.concat(cycle, '.'))
    end
    local depth = M.depth(value, maxDepth)
    if depth > maxDepth then
        return nil, ('nesting deeper than %s'):format(tostring(maxDepth))
    end
    return M.deepCopy(value)
end

--- Find the key path that closes a cycle.
--- @param t any value; a non-table is never a cycle.
--- @param maxDepth number|nil defaults to CisTable.MAX_DEPTH.
--- @return array of keys leading back to the repeated table, or nil if acyclic.
function M.findCycle(t, maxDepth)
    if type(t) ~= 'table' then
        return nil
    end
    maxDepth = maxDepth or M.MAX_DEPTH
    local onPath = {}
    -- The shallowest depth at which a table was walked to completion without
    -- finding a cycle. Reaching it again at that depth or deeper cannot find
    -- anything new, so it is skipped. Without this a table shared by two
    -- parents was walked once per ROUTE to it -- 2^22 walks for a 22-level
    -- chain of {a = t, b = t}, which is seconds of a server frame inside
    -- deepMerge. On-path (a cycle) and fully-visited (shared) are different
    -- facts and are kept apart.
    local doneAt = {}
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
        local done = doneAt[value]
        if done and done <= depth then
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
            doneAt[value] = depth
        end
    end

    walk(t, 1)
    return hit
end

--- Number of direct keys. `{}` is 0, nil is 0.
--- @param t
--- @return number  how many keys, at any depth 0. A non-table is 0
function M.count(t)
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
--- @param t
--- @param opts
--- @return number  how many values at any depth, cycles counted once; opts.maxDepth caps the walk
function M.deepSize(t, opts)
    if type(t) ~= 'table' then
        return 0
    end
    local maxDepth = (opts and opts.maxDepth) or M.MAX_DEPTH
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
--- @param t
--- @param comparator
--- @return array of keys. `{}` in, `{}` out; nil in, nil out.
function M.keys(t, comparator)
    if type(t) ~= 'table' then
        return nil
    end
    comparator = asSortComparator(comparator or M.compareKeys)
    local n = prefixLength(t)
    local rest = {}
    for k in next, t do
        if not inPrefix(k, n) then
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
--- @param t
--- @param comparator
--- @return table|nil  the values in key order, or nil when the keys cannot be ordered
function M.values(t, comparator)
    local ks = M.keys(t, comparator)
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
--- @param t
--- @param comparator
--- @param fn
--- @return number|nil,string  how many were visited, or nil and a reason for a bad argument. fn returning false stops the walk early and counts as visited.
function M.each(t, comparator, fn)
    if type(t) ~= 'table' then
        return nil, ('table expected, got %s'):format(type(t))
    end
    if type(fn) ~= 'function' then
        return nil, ('fn must be a function, got %s'):format(type(fn))
    end
    -- The same order as CisTable.keys, from the same prefix rule.
    local n = prefixLength(t)
    local rest = {}
    for k in next, t do
        if not inPrefix(k, n) then
            rest[#rest + 1] = k
        end
    end
    for i = 1, n do
        if fn(rawget(t, i), i) == false then
            return true
        end
    end
    table.sort(rest, asSortComparator(comparator or M.compareKeys))
    for i = 1, #rest do
        if fn(t[rest[i]], rest[i]) == false then
            return true
        end
    end
    return true
end

--- First value whose `predicate(value, key)` is truthy.
--- @param t
--- @param predicate
--- @return the value, or nil. A nil table or an empty table is nil, not an
function M.find(t, predicate)
    if type(t) ~= 'table' or type(predicate) ~= 'function' then
        return nil
    end
    local result
    M.each(t, nil, function(value, key)
        if predicate(value, key) then
            result = value
            return false
        end
    end)
    return result
end

--- Keep the entries whose `predicate(value, key)` is truthy.
--- @param t
--- @param predicate
--- @return the new table, or `nil, reason` when `predicate` is not a function.
function M.filter(t, predicate)
    if type(t) ~= 'table' then
        return nil, ('table expected, got %s'):format(type(t))
    end
    if type(predicate) ~= 'function' then
        return nil, ('predicate must be a function, got %s'):format(type(predicate))
    end
    local wasArray = M.isArray(t)
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
    M.each(t, nil, function(value, key)
        if predicate(value, key) then
            out[key] = value
        end
    end)
    return out
end

--- Transform every value. SHAPE IS PRESERVED (see filter).
--- @param t
--- @param fn
--- @param opts
--- @return the new table, or `nil, reason` when `fn` is not a function.
function M.map(t, fn, opts)
    if type(t) ~= 'table' then
        return nil, ('table expected, got %s'):format(type(t))
    end
    if type(fn) ~= 'function' then
        return nil, ('fn must be a function, got %s'):format(type(fn))
    end
    opts = opts or {}
    local wasArray = M.isArray(t)
    local wantArray = wasArray
    if opts.out == 'array' then
        wantArray = true
    elseif opts.out == 'map' then
        wantArray = false
    end
    -- A nil result is stored as nil, which leaves a hole: it used to be
    -- rewritten to `false`, a value fn never returned. Drop unwanted entries
    -- with filter instead.
    if opts.inPlace then
        if wantArray then
            for i = 1, #t do
                t[i] = fn(t[i], i)
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
            out[i] = fn(t[i], i)
        end
        return out
    end
    M.each(t, nil, function(value, key)
        out[key] = fn(value, key)
    end)
    return out
end

--- Fold a table into one value.
--- @param t
--- @param fn
--- @param initial
--- @return the accumulator, or `nil, reason`.
function M.reduce(t, fn, initial)
    if type(t) ~= 'table' then
        return nil, ('table expected, got %s'):format(type(t))
    end
    if type(fn) ~= 'function' then
        return nil, ('fn must be a function, got %s'):format(type(fn))
    end
    local acc = initial
    local skipFirst = false
    -- Nothing to fold and nothing to start from. Answering a bare nil looked
    -- like a fold whose result happened to be nil.
    if acc == nil and next(t) == nil then
        return nil, 'reduce of an empty table needs an initial value'
    end
    if acc == nil and M.isArray(t) and #t > 0 then
        acc = t[1]
        skipFirst = true
    elseif acc == nil and not M.isArray(t) then
        return nil, 'reduce over a map needs an initial value: a map has no first key'
    end
    local startAt = skipFirst and 2 or 1
    if M.isArray(t) then
        for i = startAt, #t do
            acc = fn(acc, t[i], i)
        end
        return acc
    end
    M.each(t, nil, function(value, key)
        acc = fn(acc, value, key)
    end)
    return acc
end

--- Sort a LIST by a derived key.
--- @param list
--- @param keyOf
--- @param comparator
--- @return table|nil,string  the SAME list, sorted in place, or nil and a reason. The sort is stable: equal keys keep their original order.
function M.sortBy(list, keyOf, comparator)
    if type(list) ~= 'table' then
        return nil, ('table expected, got %s'):format(type(list))
    end
    if type(keyOf) ~= 'function' then
        return nil, ('keyOf must be a function, got %s'):format(type(keyOf))
    end
    comparator = comparator or M.compareKeys
    -- The derived keys are computed ONCE per element, before the sort.
    local keyed = {}
    for i = 1, #list do
        keyed[i] = { k = keyOf(list[i], i), v = list[i], i = i }
    end
    -- Three-way, whatever form the comparator has. A BOOLEAN comparator (`a < b`)
    -- never answers 0, so "is this a tie" has to be asked both ways round: equal
    -- keys are the ones neither orders before the other. Reading `~= 0` off a
    -- boolean called every pair a non-tie, and the position tiebreak below --
    -- the thing that makes the sort stable -- never ran.
    local function order(a, b)
        local r = comparator(a, b)
        if type(r) == 'boolean' then
            if r then return -1 end
            if comparator(b, a) == true then return 1 end
            return 0
        end
        if r < 0 then return -1 end
        if r > 0 then return 1 end
        return 0
    end
    table.sort(keyed, function(a, b)
        local c = order(a.k, b.k)
        if c ~= 0 then
            return c < 0
        end
        -- Ties fall back to the original position, which makes the sort STABLE.
        return a.i < b.i
    end)
    for i = 1, #keyed do
        list[i] = keyed[i].v
    end
    return list
end

--- Concatenate a list, skipping entries that are not strings or numbers.
--- @param list
--- @param sep
--- @return string  the tostring() of each entry joined by sep (default ''). A non-table is ''.
function M.join(list, sep)
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

-- Merge policy names, exposed so a caller can pass the string it read from config
M.POLICY = {
    OVERLAY = 'overlay',   -- the incoming value wins
    KEEP = 'keep',         -- the existing value wins; the incoming one fills gaps
    ERROR = 'error',       -- a genuine conflict is a refusal, not a coin flip
}

--- Deep merge into a NEW table.
--- @param base
--- @param overlay
--- @param policy
--- @param opts
--- @return the merged table, or `nil, reason` -- a bad policy, a cycle in
function M.deepMerge(base, overlay, policy, opts)
    opts = opts or {}
    local resolved = policy or M.POLICY.OVERLAY
    if resolved ~= M.POLICY.OVERLAY and resolved ~= M.POLICY.KEEP
        and resolved ~= M.POLICY.ERROR then
        return nil, ('unknown merge policy %q'):format(tostring(policy))
    end
    if type(base) ~= 'table' then base = {} end
    if type(overlay) ~= 'table' then overlay = {} end
    local maxDepth = opts.maxDepth or M.MAX_DEPTH

    -- Checked once, up front, rather than with a seen-table inside the merge.
    local baseCycle = M.findCycle(base, maxDepth)
    if baseCycle then
        return nil, ('base has a cycle through %s'):format(table.concat(baseCycle, '.'))
    end
    local overlayCycle = M.findCycle(overlay, maxDepth)
    if overlayCycle then
        return nil, ('overlay has a cycle through %s'):format(table.concat(overlayCycle, '.'))
    end

    local out = {}
    for k, v in pairs(base) do
        out[k] = M.deepCopy(v)
    end
    for k, ov in pairs(overlay) do
        local bv = out[k]
        -- Two ARRAYS are replaced, never recursed into.
        local bothArrays = type(bv) == 'table' and type(ov) == 'table'
            and M.isArray(bv) and M.isArray(ov)
        if type(bv) == 'table' and type(ov) == 'table' and not bothArrays then
            local merged, err = M.deepMerge(bv, ov, resolved, opts)
            if not merged then
                return nil, ('at key %s: %s'):format(tostring(k), err)
            end
            out[k] = merged
        elseif bv == nil then
            -- Present on one side only: there is nothing to resolve.
            out[k] = M.deepCopy(ov)
        elseif resolved == M.POLICY.ERROR then
            return nil, ('key %q is present on both sides (%s and %s)'):format(
                tostring(k), tostring(bv), tostring(ov))
        -- luacheck: ignore 542
        elseif resolved == M.POLICY.KEEP then
            -- bv is already base's deep copy and stays untouched.
        else
            out[k] = M.deepCopy(ov)
        end
    end
    return out
end

--- Deep merge that mutates `target` in place and returns it.
--- @param target
--- @param overlay
--- @param policy
--- @param opts
--- @return table|nil,string  the SAME target, merged in place, or nil and a reason. Use this when the caller needs its original table identity preserved.
function M.deepMergeInto(target, overlay, policy, opts)
    if type(target) ~= 'table' then
        return nil, ('target must be a table, got %s'):format(type(target))
    end
    local merged, err = M.deepMerge(target, overlay, policy, opts)
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

-- A MODULE, NOT A GLOBAL.
if ... ~= 'cis_require' then
    CisTable = M
end

return M
