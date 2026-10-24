-- Arrays that know their own length, and the everyday functions over them.
--
-- THE LENGTH IS EXPLICIT. An array made here carries `n`, and every function
-- reads `n` (or a plain table's own numeric `n`) rather than `#t`. `#t` is
-- undefined on a table with holes -- `{ 1, nil, 3 }` may report 1 or 3 -- so a
-- map whose callback returns nil, or a list from `table.pack(...)`, silently
-- lost its tail. With `n`, a hole is just an element whose value is nil: map
-- keeps it, slice counts it, reverse moves it. A plain table WITHOUT `n` is
-- measured with `#t`, which is exact only when it has no holes.
--
-- Function style like every other module -- `array.map(a, fn)` -- and, because
-- an array's metatable __index is this module, method style too:
-- `a:map(fn):filter(pred)`. Plain tables work as input everywhere; what comes
-- back is always an array made here.
--
-- NOTHING MUTATES ITS INPUT except push and splice, which say so. sort and
-- reverse return new arrays (unlike JavaScript's). Callbacks receive
-- `(value, index, array)`. Indexes are 1-based; a negative index counts from
-- the end (-1 is the last element) wherever an index is accepted.

local M = {}

local ArrayMT = { __index = M }

local function len(a)
    local n = rawget(a, 'n')
    -- A NaN or infinite `n` is not a length: `for i = 1, math.huge` never ended.
    if type(n) == 'number' and n == n and n ~= math.huge and n ~= -math.huge then
        return n
    end
    return rawlen(a)
end

local function make(n)
    return setmetatable({ n = n }, ArrayMT)
end

local function checkArray(a, who)
    if type(a) ~= 'table' then
        error(('array.%s: expected an array (a table), got %s'):format(who, type(a)), 3)
    end
end

local function checkFn(fn, who)
    if type(fn) ~= 'function' then
        error(('array.%s: expected a function, got %s'):format(who, type(fn)), 3)
    end
end

-- A negative index counts from the end, then the result is clamped to [lo, hi].
local function position(i, n, default, lo, hi)
    if i == nil then
        return default
    end
    if type(i) ~= 'number' or i ~= i then
        return default
    end
    i = math.floor(i)
    if i < 0 then
        i = n + i + 1
    end
    if i < lo then return lo end
    if i > hi then return hi end
    return i
end

--- Whether a table should be SPREAD by concat and flat: an array made here, a table with a numeric `n`, or a table whose every key is a positive integer (an empty table counts). A map, a set or a vector is a single value.
---@param v any
---@return boolean
function M.isArrayLike(v)
    if type(v) ~= 'table' then
        return false
    end
    if getmetatable(v) == ArrayMT or type(rawget(v, 'n')) == 'number' then
        return true
    end
    if getmetatable(v) ~= nil then
        return false
    end
    for k in pairs(v) do
        if math.type(k) == nil or k < 1 or k % 1 ~= 0 then
            return false
        end
    end
    return true
end

--- An array of the arguments, holes and trailing nils included.
---@param ... any
---@return table  the array, `n` = select('#', ...)
function M.new(...)
    local out = { ... }
    out.n = select('#', ...)
    return setmetatable(out, ArrayMT)
end

--- A copy of a table as an array.
---@param list table  `list.n` is honoured; otherwise #list
---@param n? integer  an explicit length, for a table with holes and no `n`
---@return table  a NEW array
function M.from(list, n)
    checkArray(list, 'from')
    n = (type(n) == 'number' and n >= 0 and n ~= math.huge) and math.floor(n) or len(list)
    local out = make(n)
    for i = 1, n do out[i] = list[i] end
    return out
end

--- Whether a value is an array made by this module.
---@param v any
---@return boolean
function M.isArray(v)
    return type(v) == 'table' and getmetatable(v) == ArrayMT
end

--- The length: `n` when the table has one, else #t.
---@param a table
---@return integer
function M.len(a)
    checkArray(a, 'len')
    return len(a)
end

--- Append values IN PLACE. Nil arguments become holes and still count.
---@param a table
---@param ... any
---@return integer  the new length. `a.n` is updated when `a` has one
function M.push(a, ...)
    checkArray(a, 'push')
    local n = len(a)
    local count = select('#', ...)
    for i = 1, count do
        a[n + i] = (select(i, ...))
    end
    n = n + count
    if rawget(a, 'n') ~= nil then
        a.n = n
    end
    return n
end

--- Call fn for every element.
---@param a table
---@param fn fun(value: any, index: integer, array: table)
---@return nil
function M.forEach(a, fn)
    checkArray(a, 'forEach')
    checkFn(fn, 'forEach')
    for i = 1, len(a) do fn(a[i], i, a) end
end

--- A new array of fn's results. A nil result is a hole, and the length is kept.
---@param a table
---@param fn fun(value: any, index: integer, array: table): any
---@return table  a NEW array of the same length
function M.map(a, fn)
    checkArray(a, 'map')
    checkFn(fn, 'map')
    local n = len(a)
    local out = make(n)
    for i = 1, n do out[i] = fn(a[i], i, a) end
    return out
end

--- The elements fn accepts, in order, with no holes.
---@param a table
---@param fn fun(value: any, index: integer, array: table): any
---@return table  a NEW, dense array
function M.filter(a, fn)
    checkArray(a, 'filter')
    checkFn(fn, 'filter')
    local out, k = make(0), 0
    for i = 1, len(a) do
        local v = a[i]
        if fn(v, i, a) then
            k = k + 1
            out[k] = v
        end
    end
    out.n = k
    return out
end

--- Fold left. With no initial value the first element is the start and the fold begins at the second.
---@param a table
---@param fn fun(acc: any, value: any, index: integer, array: table): any
---@param initial? any
---@return any  the accumulator; nil for an empty array with no initial value
function M.reduce(a, fn, initial)
    checkArray(a, 'reduce')
    checkFn(fn, 'reduce')
    local n = len(a)
    local acc, start = initial, 1
    if initial == nil then
        if n == 0 then
            return nil
        end
        acc, start = a[1], 2
    end
    for i = start, n do acc = fn(acc, a[i], i, a) end
    return acc
end

--- The first element fn accepts.
---@param a table
---@param fn fun(value: any, index: integer, array: table): any
---@return any  the element, or nil
---@return integer|nil  its index
function M.find(a, fn)
    checkArray(a, 'find')
    checkFn(fn, 'find')
    for i = 1, len(a) do
        local v = a[i]
        if fn(v, i, a) then return v, i end
    end
    return nil, nil
end

--- The index of the first element fn accepts.
---@param a table
---@param fn fun(value: any, index: integer, array: table): any
---@return integer|nil
function M.findIndex(a, fn)
    checkArray(a, 'findIndex')
    checkFn(fn, 'findIndex')
    for i = 1, len(a) do
        if fn(a[i], i, a) then return i end
    end
    return nil
end

--- Whether fn accepts at least one element.
---@param a table
---@param fn fun(value: any, index: integer, array: table): any
---@return boolean
function M.some(a, fn)
    return M.findIndex(a, fn) ~= nil
end

--- Whether fn accepts every element (true for an empty array).
---@param a table
---@param fn fun(value: any, index: integer, array: table): any
---@return boolean
function M.every(a, fn)
    checkArray(a, 'every')
    checkFn(fn, 'every')
    for i = 1, len(a) do
        if not fn(a[i], i, a) then return false end
    end
    return true
end

--- The first index holding a value equal (==) to v. NaN is never found, as in JavaScript.
---@param a table
---@param v any
---@param from? integer  where to start; negative counts from the end
---@return integer|nil
function M.indexOf(a, v, from)
    checkArray(a, 'indexOf')
    local n = len(a)
    for i = position(from, n, 1, 1, n + 1), n do
        if a[i] == v then return i end
    end
    return nil
end

--- Whether the array holds v. Unlike indexOf, NaN finds NaN, and nil finds a hole.
---@param a table
---@param v any
---@return boolean
function M.includes(a, v)
    checkArray(a, 'includes')
    if v ~= v then
        for i = 1, len(a) do
            local x = a[i]
            if x ~= x then return true end
        end
        return false
    end
    return M.indexOf(a, v) ~= nil
end

--- Elements i..j inclusive. Defaults: the whole array.
---@param a table
---@param i? integer  default 1; negative counts from the end
---@param j? integer  default the length; negative counts from the end
---@return table  a NEW array
function M.slice(a, i, j)
    checkArray(a, 'slice')
    local n = len(a)
    local from = position(i, n, 1, 1, n + 1)
    local to = position(j, n, n, 0, n)
    local count = to - from + 1
    if count < 0 then count = 0 end
    local out = make(count)
    for k = 1, count do out[k] = a[from + k - 1] end
    return out
end

--- Remove deleteCount elements at start and insert the extra arguments there, IN PLACE.
---@param a table
---@param start integer  negative counts from the end; clamped to 1..length+1
---@param deleteCount? integer  default everything from start; clamped to what exists
---@param ... any  the elements to insert
---@return table  a NEW array of the removed elements. `a.n` is updated when `a` has one
function M.splice(a, start, deleteCount, ...)
    checkArray(a, 'splice')
    local n = len(a)
    local s = position(start, n, 1, 1, n + 1)
    local available = n - s + 1
    local d = available
    if deleteCount ~= nil then
        d = (type(deleteCount) == 'number' and deleteCount == deleteCount) and math.floor(deleteCount) or 0
        if d < 0 then d = 0 end
        if d > available then d = available end
    end
    local removed = make(d)
    for k = 1, d do removed[k] = a[s + k - 1] end
    local insert = select('#', ...)
    -- The tail moves by (insert - d). Copy it out first, so the direction of the
    -- shift never matters.
    local tailFrom = s + d
    local tail, tn = {}, n - tailFrom + 1
    for k = 1, tn do tail[k] = a[tailFrom + k - 1] end
    for k = 1, insert do a[s + k - 1] = (select(k, ...)) end
    local writeAt = s + insert
    for k = 1, tn do a[writeAt + k - 1] = tail[k] end
    local newN = n - d + insert
    for k = newN + 1, n do a[k] = nil end
    if rawget(a, 'n') ~= nil then
        a.n = newN
    end
    return removed
end

--- The array followed by each argument; an array-like argument is spread one level, anything else is appended as one element.
---@param a table
---@param ... any
---@return table  a NEW array
function M.concat(a, ...)
    checkArray(a, 'concat')
    local out = M.from(a)
    local k = out.n
    for i = 1, select('#', ...) do
        local v = (select(i, ...))
        if M.isArrayLike(v) then
            for j = 1, len(v) do
                k = k + 1
                out[k] = v[j]
            end
        else
            k = k + 1
            out[k] = v
        end
    end
    out.n = k
    return out
end

-- `active` holds the arrays being spread right now: one met again inside itself is a
-- cycle, and is kept as an element rather than followed forever.
-- An explicit stack, not recursion: a 200k-deep array overflowed the C stack.
local function flatInto(out, k, a, depth, active)
    local arrs, idxs, deps, lens = { a }, { 0 }, { depth }, { len(a) }
    local top = 1
    active[a] = true
    while top > 0 do
        local i = idxs[top] + 1
        if i > lens[top] then
            active[arrs[top]] = nil
            arrs[top] = nil
            top = top - 1
        else
            idxs[top] = i
            local v = arrs[top][i]
            local d = deps[top]
            if d > 0 and not active[v] and M.isArrayLike(v) then
                top = top + 1
                arrs[top], idxs[top], deps[top], lens[top] = v, 0, d - 1, len(v)
                active[v] = true
            else
                k = k + 1
                out[k] = v
            end
        end
    end
    return k
end

--- Nested array-likes spread into one array, to a depth.
---@param a table
---@param depth? integer  default 1; math.huge flattens fully
---@return table  a NEW array; a table that contains itself is kept as an element where the cycle closes
function M.flat(a, depth)
    checkArray(a, 'flat')
    if depth == nil then depth = 1 end
    local out = make(0)
    out.n = flatInto(out, 0, a, depth, {})
    return out
end

--- The elements in reverse order.
---@param a table
---@return table  a NEW array; holes move with their position
function M.reverse(a)
    checkArray(a, 'reverse')
    local n = len(a)
    local out = make(n)
    for i = 1, n do out[i] = a[n - i + 1] end
    return out
end

--- The elements joined into a string.
---@param a table
---@param sep? string  default ''
---@return string  a hole is the empty string
function M.join(a, sep)
    checkArray(a, 'join')
    local n = len(a)
    local parts = {}
    for i = 1, n do
        local v = a[i]
        parts[i] = v == nil and '' or tostring(v)
    end
    return table.concat(parts, sep or '')
end

local function defaultLess(x, y)
    return x < y
end

--- A STABLE sort: elements the comparator calls equal keep their order. Holes sort to the end.
---@param a table
---@param less? fun(x: any, y: any): boolean  true when x goes before y; default `<`
---@return table  a NEW array; the input is untouched
function M.sort(a, less)
    checkArray(a, 'sort')
    if less ~= nil then checkFn(less, 'sort') end
    less = less or defaultLess
    local n = len(a)
    local src, m = {}, 0
    for i = 1, n do
        local v = a[i]
        if v ~= nil then
            m = m + 1
            src[m] = v
        end
    end
    -- Bottom-up merge sort. Ties take from the LEFT run, which is what makes it
    -- stable: table.sort is not, and a stable sort is the one a UI wants.
    local dst = {}
    local width = 1
    while width < m do
        local i = 1
        while i <= m do
            local mid = i + width
            local hi = i + 2 * width
            if mid > m + 1 then mid = m + 1 end
            if hi > m + 1 then hi = m + 1 end
            local l, r, k = i, mid, i
            while l < mid and r < hi do
                if less(src[r], src[l]) then
                    dst[k] = src[r]
                    r = r + 1
                else
                    dst[k] = src[l]
                    l = l + 1
                end
                k = k + 1
            end
            while l < mid do dst[k] = src[l]; l = l + 1; k = k + 1 end
            while r < hi do dst[k] = src[r]; r = r + 1; k = k + 1 end
            i = hi
        end
        src, dst = dst, src
        width = width * 2
    end
    local out = make(n)
    for i = 1, m do out[i] = src[i] end
    return out
end

local NIL_KEY, NAN_KEY = {}, {}

--- The first occurrence of each distinct element (or of each distinct key).
---@param a table
---@param keyOf? fun(value: any, index: integer): any  default the element itself
---@return table  a NEW, dense array. nil and NaN each count as one distinct value
function M.unique(a, keyOf)
    checkArray(a, 'unique')
    if keyOf ~= nil then checkFn(keyOf, 'unique') end
    local seen = {}
    local out, k = make(0), 0
    for i = 1, len(a) do
        local v = a[i]
        local key = v
        if keyOf then key = keyOf(v, i) end
        if key == nil then key = NIL_KEY elseif key ~= key then key = NAN_KEY end
        if not seen[key] then
            seen[key] = true
            k = k + 1
            out[k] = v
        end
    end
    out.n = k
    return out
end

--- Elements grouped by fn's answer. An element whose key is nil or NaN is left out.
---@param a table
---@param keyOf fun(value: any, index: integer): any
---@return table<any, table>  key -> a NEW array of its elements, in order
function M.groupBy(a, keyOf)
    checkArray(a, 'groupBy')
    checkFn(keyOf, 'groupBy')
    local groups = {}
    for i = 1, len(a) do
        local v = a[i]
        local key = keyOf(v, i)
        if key ~= nil and key == key then
            local g = groups[key]
            if g == nil then
                g = make(0)
                groups[key] = g
            end
            g.n = g.n + 1
            g[g.n] = v
        end
    end
    return groups
end

--- Consecutive pieces of at most size elements.
---@param a table
---@param size integer  at least 1
---@return table  a NEW array of NEW arrays; the last may be shorter
function M.chunk(a, size)
    checkArray(a, 'chunk')
    if type(size) ~= 'number' or size < 1 or size % 1 ~= 0 or size == math.huge then
        error(('array.chunk: size must be a whole number of at least 1, got %s'):format(tostring(size)), 2)
    end
    local n = len(a)
    local out, k = make(0), 0
    local i = 1
    while i <= n do
        local stop = i + size - 1
        if stop > n then stop = n end
        k = k + 1
        out[k] = M.slice(a, i, stop)
        i = stop + 1
    end
    out.n = k
    return out
end

--- Tuples of the i-th element of every argument; as long as the LONGEST, shorter ones padded with holes.
---@param ... table
---@return table  a NEW array of NEW arrays, each with n = the number of arguments
function M.zip(...)
    local count = select('#', ...)
    local lists, longest = {}, 0
    for j = 1, count do
        local l = (select(j, ...))
        checkArray(l, 'zip')
        lists[j] = l
        local n = len(l)
        if n > longest then longest = n end
    end
    local out = make(longest)
    for i = 1, longest do
        local tuple = make(count)
        for j = 1, count do tuple[j] = lists[j][i] end
        out[i] = tuple
    end
    return out
end

--- The sum of the elements; holes are skipped.
---@param a table
---@return number|nil  0 for an empty array
---@return string|nil  why, when an element is not a number
function M.sum(a)
    checkArray(a, 'sum')
    local total = 0
    for i = 1, len(a) do
        local v = a[i]
        if v ~= nil then
            if type(v) ~= 'number' then
                return nil, ('element %s is a %s, not a number'):format(tostring(i), type(v))
            end
            local nextTotal = total + v
            -- Integer addition wraps; once it would, the rest is summed as floats.
            if math.type(total) == 'integer' and math.type(v) == 'integer'
                and ((v > 0 and nextTotal < total) or (v < 0 and nextTotal > total)) then
                nextTotal = (total + 0.0) + v
            end
            total = nextTotal
        end
    end
    return total
end

local function extreme(a, keyOf, wantGreater, who)
    checkArray(a, who)
    if keyOf ~= nil then checkFn(keyOf, who) end
    local best, bestKey, bestIndex
    for i = 1, len(a) do
        local v = a[i]
        if v ~= nil then
            local key = v
            if keyOf then key = keyOf(v, i) end
            -- A nil or NaN key cannot be ordered, so it cannot win.
            if key ~= nil and key == key then
                if bestIndex == nil
                    or (wantGreater and bestKey < key)
                    or (not wantGreater and key < bestKey) then
                    best, bestKey, bestIndex = v, key, i
                end
            end
        end
    end
    return best, bestIndex
end

--- The smallest element (the first one, on a tie). Holes and NaN are skipped.
---@param a table
---@param keyOf? fun(value: any, index: integer): any  compare by this instead of the element
---@return any  the element, or nil when there is none
---@return integer|nil  its index
function M.min(a, keyOf)
    return extreme(a, keyOf, false, 'min')
end

--- The largest element (the first one, on a tie). Holes and NaN are skipped.
---@param a table
---@param keyOf? fun(value: any, index: integer): any  compare by this instead of the element
---@return any  the element, or nil when there is none
---@return integer|nil  its index
function M.max(a, keyOf)
    return extreme(a, keyOf, true, 'max')
end

ArrayMT.__len = len
ArrayMT.__tostring = function(a)
    return ('Array(%s)'):format(tostring(len(a)))
end

-- A MODULE, NOT A GLOBAL.
if ... ~= 'cis_require' then
    CisArray = M
end

return M
