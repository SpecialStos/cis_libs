-- Tests for the developer-experience modules: array, set, ringbuffer, mathx,
-- class, string.random, print, locale, timer and cron.
--
-- Each module is loaded the way Cis.require loads it -- the chunk called with
-- the 'cis_require' marker -- so no legacy global is installed and every
-- assertion here goes through the table the module returns.
--
-- PROPERTIES, NOT ONLY EXAMPLES. Where a function has an obvious naive
-- implementation, random inputs are run through both and every answer is
-- compared: array and set against plain-loop references, the ring buffer
-- against a list that is trimmed by hand, and cron.next against a brute-force
-- walk that tests one minute at a time with nothing but os.date. The inputs
-- come from a seeded generator, so a failure names a seed that reproduces it.
--
-- Runs under fengari (Lua 5.3 semantics, 32-bit integers) and a real Lua 5.4.
-- Timestamps stay below 2^31 for that reason.

local passed, failed = 0, 0
TEST_CASES = {}

local function expect(cond, msg)
    if cond then
        passed = passed + 1
    else
        failed = failed + 1
        io.stderr:write('FAIL: ' .. msg .. '\n')
    end
    TEST_CASES[#TEST_CASES + 1] = { name = msg, status = cond and 'passed' or 'failed' }
end

local function load(rel)
    local chunk = assert(loadfile('./' .. rel))
    return chunk('cis_require')
end

local function raises(fn, needle)
    local ok, err = pcall(fn)
    if ok then return false end
    return needle == nil or tostring(err):find(needle, 1, true) ~= nil
end

-- Print capture. The modules call the global `print`; this suite owns it
-- while a block needs to read what was printed.
local realPrint = print
local printed = {}
local function capture()
    printed = {}
    print = function(s) printed[#printed + 1] = tostring(s) end -- luacheck: ignore 121
end
local function release()
    print = realPrint -- luacheck: ignore 121
end

local Random = load('shared/algo/random.lua')

-- ===================================================================== array
do
    local A = load('shared/util/array.lua')

    -- The explicit length is the headline: holes survive everything.
    local a = A.new(1, nil, 3, nil)
    expect(a.n == 4 and A.len(a) == 4 and #a == 4, 'array: new counts trailing nils and holes (n = 4)')
    local doubled = a:map(function(v) return v and v * 2 end)
    expect(doubled.n == 4 and doubled[1] == 2 and doubled[2] == nil and doubled[3] == 6,
        'array: map keeps holes and the length, in method style')
    expect(A.isArray(doubled) and not A.isArray({}), 'array: results are arrays; a plain table is not')
    local packed = A.from(table.pack(nil, nil, 'x'))
    expect(packed.n == 3 and packed[3] == 'x', 'array: from honours table.pack n')
    expect(A.from({ 1, 2 }, 5).n == 5, 'array: from takes an explicit length for a table with holes')
    expect(A.push(a, nil, 9) == 6 and a.n == 6 and a[6] == 9, 'array: push appends holes too and updates n')
    local plain = { 1, 2 }
    A.push(plain, 3)
    expect(plain.n == nil and plain[3] == 3, 'array: push on a plain table without n adds no n')

    expect(A.reduce(A.new(1, 2, 3), function(acc, v) return acc + v end) == 6, 'array: reduce with no initial starts at element 1')
    expect(A.reduce(A.new(), function() return 1 end) == nil, 'array: reduce of empty with no initial is nil')
    expect(A.reduce(A.new(1, 2), function(acc, v) return acc .. v end, '') == '12', 'array: reduce with an initial value')
    local v, vi = A.find(A.new(5, 6, 7), function(x) return x > 5 end)
    expect(v == 6 and vi == 2, 'array: find answers value and index')
    expect(A.findIndex(A.new(5, 6), function(x) return x > 9 end) == nil, 'array: findIndex answers nil when nothing matches')
    expect(A.indexOf(A.new('a', 'b', 'a'), 'a', 2) == 3, 'array: indexOf from a start')
    expect(A.indexOf(A.new('a', 'b', 'a'), 'a', -1) == 3, 'array: indexOf from a negative start')
    local nan = 0 / 0
    expect(A.indexOf(A.new(nan), nan) == nil and A.includes(A.new(1, nan), nan),
        'array: indexOf never finds NaN, includes does (SameValueZero)')
    expect(A.includes(A.new(1, nil, 3), nil) and not A.includes(A.new(1, 2), nil), 'array: includes(nil) finds a hole')
    expect(A.some(A.new(1, 2), function(x) return x == 2 end) and A.every(A.new(), function() return false end),
        'array: some and every (every is true on empty)')
    expect(A.join(A.new('a', nil, 'c'), '-') == 'a--c', 'array: join renders a hole as empty')

    -- sort is STABLE and holes go last.
    local recs = A.new({ k = 2, id = 1 }, { k = 1, id = 2 }, nil, { k = 2, id = 3 }, { k = 1, id = 4 })
    local sorted = A.sort(recs, function(x, y) return x.k < y.k end)
    expect(sorted.n == 5 and sorted[1].id == 2 and sorted[2].id == 4 and sorted[3].id == 1
        and sorted[4].id == 3 and sorted[5] == nil, 'array: sort is stable and puts holes last')
    expect(recs[1].id == 1, 'array: sort leaves its input alone')

    local groups = A.groupBy(A.new(1, 2, 3, 4, 5), function(x) return x % 2 == 0 and 'even' or 'odd' end)
    expect(groups.odd.n == 3 and groups.even.n == 2 and groups.even[2] == 4, 'array: groupBy keeps order inside a group')
    expect(raises(function() A.chunk(A.new(1), 0) end, 'size must be'), 'array: chunk refuses size 0 with the fix')
    expect(raises(function() A.map(A.new(1), 'x') end, 'expected a function'), 'array: map refuses a non-function')
    local sum, why = A.sum(A.new(1, 'x'))
    expect(sum == nil and why:find('element 2', 1, true) ~= nil, 'array: sum names the element that is not a number')
    expect(A.flat(A.new(1, A.new(2, A.new(3))), math.huge).n == 3, 'array: flat to infinite depth')
    expect(A.concat(A.new(1), { x = 1 }).n == 2, 'array: concat appends a map as ONE element, not spread')
    local mn, mi = A.min(A.new(3, nil, 1, nan, 1))
    local mx, xi = A.max(A.new('b', 'c', 'a'))
    expect(mn == 1 and mi == 3 and mx == 'c' and xi == 2, 'array: min/max skip holes and NaN, first index on a tie')
    expect(A.min(A.new()) == nil, 'array: min of empty is nil')

    -- ---- property: every function against a naive reference ----
    local gen = Random.newGenerator(20261022)
    local function randArray()
        local n = gen:int(0, 12)
        local out = { n = n }
        for k = 1, n do
            if gen:float() < 0.2 then out[k] = nil else out[k] = gen:int(-5, 5) end
        end
        return out
    end
    local function same(x, y)
        if x.n ~= y.n then return false end
        for k = 1, x.n do
            if x[k] ~= y[k] then return false end
        end
        return true
    end
    local function box(t) local b = {} for k = 1, t.n do b[k] = { t[k] } end return b end
    local function unbox(b) local t = { n = #b } for k = 1, #b do t[k] = b[k][1] end return t end
    local bad = {}
    local function check(ok, what, case) if not ok and #bad < 6 then bad[#bad + 1] = what .. ' #' .. case end end
    for case = 1, 400 do
        local x = randArray()
        local n = x.n
        -- map / filter / reduce
        local refMap = { n = n }
        for k = 1, n do refMap[k] = x[k] and x[k] * 3 or nil end
        check(same(A.map(x, function(e) return e and e * 3 end), refMap), 'map', case)
        local refFilter = { n = 0 }
        for k = 1, n do
            if x[k] ~= nil and x[k] % 2 == 0 then refFilter.n = refFilter.n + 1; refFilter[refFilter.n] = x[k] end
        end
        check(same(A.filter(x, function(e) return e ~= nil and e % 2 == 0 end), refFilter), 'filter', case)
        local refSum = 0
        for k = 1, n do refSum = refSum + (x[k] or 0) end
        check(A.reduce(x, function(acc, e) return acc + (e or 0) end, 0) == refSum, 'reduce', case)
        check(A.sum(x) == refSum, 'sum', case)
        -- slice, with every combination of nil / negative / out-of-range bounds
        local i = gen:float() < 0.2 and nil or gen:int(-n - 2, n + 2)
        local j = gen:float() < 0.2 and nil or gen:int(-n - 2, n + 2)
        local s = i or 1
        if s < 0 then s = n + s + 1 end
        local e = j or n
        if e < 0 then e = n + e + 1 end
        local refSlice = { n = 0 }
        for k = s, e do
            if k >= 1 and k <= n then refSlice.n = refSlice.n + 1; refSlice[refSlice.n] = x[k] end
        end
        check(same(A.slice(x, i, j), refSlice), 'slice', case)
        -- splice, against table.remove/insert on boxed values
        local start = gen:int(-n - 2, n + 2)
        local del = gen:float() < 0.2 and nil or gen:int(-1, n + 1)
        local ins = {}
        for k = 1, gen:int(0, 3) do ins[k] = gen:float() < 0.3 and false or gen:int(10, 20) end
        local list = box(x)
        local st = start < 0 and n + start + 1 or start
        if st < 1 then st = 1 end
        if st > n + 1 then st = n + 1 end
        local d = del == nil and (n - st + 1) or del
        if d < 0 then d = 0 end
        if d > n - st + 1 then d = n - st + 1 end
        local refRemoved = {}
        for _ = 1, d do refRemoved[#refRemoved + 1] = table.remove(list, st) end
        for k = 1, #ins do table.insert(list, st + k - 1, { ins[k] }) end
        local y = A.from(x)
        local removed = A.splice(y, start, del, table.unpack(ins))
        local tailClear = true
        for k = y.n + 1, n do if y[k] ~= nil then tailClear = false end end
        check(same(y, unbox(list)) and same(removed, unbox(refRemoved)) and tailClear, 'splice', case)
        -- reverse, concat, unique, chunk
        local refRev = { n = n }
        for k = 1, n do refRev[k] = x[n - k + 1] end
        check(same(A.reverse(x), refRev), 'reverse', case)
        local x2 = randArray()
        local refCat = { n = n + x2.n }
        for k = 1, n do refCat[k] = x[k] end
        for k = 1, x2.n do refCat[n + k] = x2[k] end
        check(same(A.concat(x, x2), refCat), 'concat', case)
        local refUniq = { n = 0 }
        for k = 1, n do
            local dup = false
            for m = 1, refUniq.n do if refUniq[m] == x[k] then dup = true end end
            -- nil == nil, but a hole only counts once if one was already kept
            if x[k] == nil then
                dup = false
                for m = 1, k - 1 do if x[m] == nil then dup = true end end
            end
            if not dup then refUniq.n = refUniq.n + 1; refUniq[refUniq.n] = x[k] end
        end
        check(same(A.unique(x), refUniq), 'unique', case)
        local size = gen:int(1, 4)
        local chunks = A.chunk(x, size)
        local okChunks = chunks.n == math.ceil(n / size)
        for c = 1, chunks.n do
            for k = 1, chunks[c].n do
                if chunks[c][k] ~= x[(c - 1) * size + k] then okChunks = false end
            end
        end
        check(okChunks, 'chunk', case)
        -- zip is as long as the longest input
        local z = A.zip(x, x2)
        local okZip = z.n == math.max(n, x2.n)
        for k = 1, z.n do
            if z[k][1] ~= x[k] or z[k][2] ~= x2[k] or z[k].n ~= 2 then okZip = false end
        end
        check(okZip, 'zip', case)
        -- min / max against a scan
        local refMin, refMinI, refMax, refMaxI
        for k = 1, n do
            local val = x[k]
            if val ~= nil then
                if refMin == nil or val < refMin then refMin, refMinI = val, k end
                if refMax == nil or val > refMax then refMax, refMaxI = val, k end
            end
        end
        local gotMin, gotMinI = A.min(x)
        local gotMax, gotMaxI = A.max(x)
        check(gotMin == refMin and gotMinI == refMinI and gotMax == refMax and gotMaxI == refMaxI, 'min/max', case)
        -- sort: stable, against insertion sort, holes last
        local recsX = { n = n }
        for k = 1, n do recsX[k] = x[k] ~= nil and { key = x[k] % 3, id = k } or nil end
        local ins2 = {}
        for k = 1, n do
            local r = recsX[k]
            if r then
                local pos = #ins2 + 1
                while pos > 1 and r.key < ins2[pos - 1].key do pos = pos - 1 end
                table.insert(ins2, pos, r)
            end
        end
        local got = A.sort(recsX, function(p, q) return p.key < q.key end)
        local okSort = got.n == n
        for k = 1, n do if got[k] ~= ins2[k] then okSort = false end end
        check(okSort, 'sort', case)
        -- includes / indexOf
        local probe = gen:int(-6, 6)
        local refIdx
        for k = 1, n do if x[k] == probe then refIdx = k break end end
        check(A.indexOf(x, probe) == refIdx and A.includes(x, probe) == (refIdx ~= nil), 'indexOf', case)
    end
    expect(#bad == 0, 'array: 400 random arrays with holes agree with naive references for map, filter, '
        .. 'reduce, sum, slice, splice, reverse, concat, unique, chunk, zip, min, max, sort (stable), '
        .. 'indexOf, includes: ' .. table.concat(bad, ', '))
end

-- ======================================================================= set
do
    local S = load('shared/algo/set.lua')
    local s = S.new({ 'a', 'b', 'a' })
    expect(S.size(s) == 2 and #s == 2, 'set: new de-duplicates')
    expect(s:add('c') == true and s:add('c') == false, 'set: add answers whether it was new')
    local ok, why = S.add(s, nil)
    expect(ok == nil and why:find('nil', 1, true) ~= nil, 'set: nil is refused by name')
    ok, why = S.add(s, 0 / 0)
    expect(ok == nil and why:find('NaN', 1, true) ~= nil, 'set: NaN is refused by name')
    expect(S.remove(s, 'a') and not S.has(s, 'a') and S.size(s) == 2, 'set: remove')
    S.add(s, 'a')
    local vals = S.values(s)
    expect(vals.n == 3 and vals[1] == 'b' and vals[2] == 'c' and vals[3] == 'a',
        'set: values are in insertion order, and a re-added member goes last')
    local x, y = S.new({ 1, 2, 3 }), S.new({ 3, 4 })
    expect(S.values(S.union(x, y))[4] == 4 and S.size(S.intersect(x, y)) == 1
        and S.size(S.difference(x, y)) == 2, 'set: union, intersect, difference')
    expect(S.isSubset(S.new({ 1 }), x) and not S.isSubset(y, x) and S.equals(S.new({ 3, 2, 1 }), x),
        'set: isSubset and equals ignore order')
    expect(S.size(S.clear(x)) == 0 and S.isSet(x) and not S.isSet({}), 'set: clear and isSet')

    -- ---- property: against a list with linear search ----
    local gen = Random.newGenerator(7)
    local bad = 0
    for case = 1, 60 do
        local set, ref = S.new(), {}
        local function refIndex(v) for k = 1, #ref do if ref[k] == v then return k end end end
        for _ = 1, 80 do
            local v = gen:int(1, 12)
            if gen:float() < 0.5 then v = 'k' .. v end
            local op = gen:int(1, 3)
            if op == 1 then
                local added = S.add(set, v)
                if added ~= (refIndex(v) == nil) then bad = bad + 1 end
                if refIndex(v) == nil then ref[#ref + 1] = v end
            elseif op == 2 then
                local removed = S.remove(set, v)
                local k = refIndex(v)
                if removed ~= (k ~= nil) then bad = bad + 1 end
                if k then table.remove(ref, k) end
            elseif S.has(set, v) ~= (refIndex(v) ~= nil) then
                bad = bad + 1
            end
        end
        local got = S.values(set)
        if got.n ~= #ref or S.size(set) ~= #ref then bad = bad + 1 end
        for k = 1, #ref do if got[k] ~= ref[k] then bad = bad + 1 break end end
        -- the algebra against nested loops
        local other = S.new()
        for _ = 1, 8 do S.add(other, gen:int(1, 12)) end
        local inter, diff = 0, 0
        for k = 1, #ref do
            if S.has(other, ref[k]) then inter = inter + 1 else diff = diff + 1 end
        end
        if S.size(S.intersect(set, other)) ~= inter or S.size(S.difference(set, other)) ~= diff
            or S.size(S.union(set, other)) ~= #ref + S.size(other) - inter then
            bad = bad + 1
        end
        if case == 60 then break end
    end
    expect(bad == 0, ('set: 60 random add/remove/has sequences agree with a linear-search list, order '
        .. 'included, and union/intersect/difference sizes agree with nested loops (%d mismatches)'):format(bad))
end

-- ================================================================ ringbuffer
do
    local R = load('shared/algo/ringbuffer.lua')
    expect(raises(function() R.new(0) end, 'capacity'), 'ringbuffer: capacity 0 is refused with the fix')
    local rb = R.new(3)
    rb:push(1) rb:push(nil) rb:push(3)
    expect(R.size(rb) == 3 and R.isFull(rb) and R.get(rb, 2) == nil and R.get(rb, 3) == 3,
        'ringbuffer: nil is a storable value and counts')
    local evicted, did = R.push(rb, 4)
    expect(evicted == 1 and did == true and R.peek(rb) == nil and R.peekLast(rb) == 4,
        'ringbuffer: push on a full buffer overwrites the oldest and says so')
    local arr = R.toArray(rb)
    expect(arr.n == 3 and arr[1] == nil and arr[2] == 3 and arr[3] == 4, 'ringbuffer: toArray oldest first, with n')
    expect(R.pop(rb) == 4 and R.shift(rb) == nil and R.size(rb) == 1 and R.get(rb, -1) == 3,
        'ringbuffer: pop takes the newest, shift the oldest')
    expect(R.isEmpty(R.clear(rb)) and R.capacity(rb) == 3, 'ringbuffer: clear keeps the capacity')

    local gen = Random.newGenerator(99)
    local bad = 0
    for _ = 1, 50 do
        local cap = gen:int(1, 6)
        local buf, ref = R.new(cap), {}
        for _ = 1, 60 do
            local op = gen:int(1, 4)
            if op <= 2 then
                local v = gen:int(1, 100)
                local ev, over = R.push(buf, v)
                ref[#ref + 1] = v
                local refEv
                if #ref > cap then refEv = table.remove(ref, 1) end
                if over ~= (refEv ~= nil) or ev ~= refEv then bad = bad + 1 end
            elseif op == 3 then
                if R.shift(buf) ~= table.remove(ref, 1) then bad = bad + 1 end
            else
                if R.pop(buf) ~= table.remove(ref) then bad = bad + 1 end
            end
            if R.size(buf) ~= #ref then bad = bad + 1 end
            local k = gen:int(-cap - 1, cap + 1)
            local refK = k < 0 and #ref + k + 1 or k
            if R.get(buf, k) ~= ref[refK] then bad = bad + 1 end
        end
    end
    expect(bad == 0, ('ringbuffer: 50 random push/shift/pop sequences agree with a hand-trimmed list (%d mismatches)')
        :format(bad))
end

-- ===================================================================== mathx
do
    local X = load('shared/util/mathx.lua')
    expect(X.round(2.5) == 3 and X.round(-2.5) == -3 and math.type(X.round(2.4)) == 'integer',
        'mathx: round half away from zero, to an integer')
    expect(X.round(1.2345, 2) == 1.23 and X.round(1250, -2) == 1300 and X.round(-1250, -2) == -1300,
        'mathx: round to decimals, and to hundreds with a negative count')
    expect(X.round(0 / 0) ~= X.round(0 / 0) and X.round(math.huge) == math.huge, 'mathx: round leaves NaN and inf alone')
    -- floor(x + 0.5) took 0.49999999999999994 to 1, an integer went through a
    -- float (past 2^53 it changed, math.mininteger flipped sign), and a scale
    -- of 10^400 made 0 * inf or inf / inf a NaN.
    expect(X.round(0.49999999999999994) == 0 and X.round(-0.49999999999999994) == 0 and X.round(0.5) == 1,
        'mathx: round only rounds up from a true half, 0.49999999999999994 stays 0')
    expect(X.round(math.maxinteger - 1) == math.maxinteger - 1 and X.round(math.mininteger) == math.mininteger
        and X.round(math.maxinteger, 3) == math.maxinteger and math.type(X.round(math.mininteger)) == 'integer' and math.type(X.round(7, 2)) == 'integer',
        'mathx: round returns an integer unchanged, math.maxinteger - 1 and math.mininteger included')
    expect(X.round(1.5, 400) == 1.5 and X.round(1.5, -400) == 0 and X.round(0, 400) == 0 and X.round(1e308, 1) == 1e308,
        'mathx: round with an enormous decimals count or a huge value answers, never NaN or inf')
    expect(X.round(math.mininteger, -2) <= 0 and X.round(2.5, 0) == 3, 'mathx: round of math.mininteger to hundreds keeps its sign')
    expect(X.clamp(5, 0, 10) == 5 and X.clamp(-1, 0, 10) == 0 and X.clamp(11, 0, 10) == 10, 'mathx: clamp')
    -- The three clamps (mathx, interp, validate) now agree: a NaN value or reversed
    -- bounds answer nil plus a reason. mathx used to swap the bounds and pass NaN on.
    local cv, cwhy = X.clamp(5, 10, 0)
    expect(cv == nil and type(cwhy) == 'string', 'mathx: clamp refuses reversed bounds with a reason')
    cv, cwhy = X.clamp(0 / 0, 0, 10)
    expect(cv == nil and type(cwhy) == 'string', 'mathx: clamp refuses NaN with a reason')
    expect(X.clamp(math.huge, 0, 10) == 10 and X.clamp(-math.huge, 0, 10) == 0 and X.clamp(5, -math.huge, math.huge) == 5,
        'mathx: clamp still takes infinities')
    expect(X.lerp(0, 10, 0.25) == 2.5 and X.inverseLerp(0, 10, 2.5) == 0.25 and X.inverseLerp(3, 3, 9) == 0,
        'mathx: lerp and inverseLerp, with a == b safe')
    expect(X.remap(5, 0, 10, 100, 200) == 150 and X.remap(20, 0, 10, 0, 1, true) == 1, 'mathx: remap and clamped remap')
    -- lerp is operator-only, so a vector type with arithmetic metamethods works.
    local V = {}
    V.__index = V
    local function vec(x, y) return setmetatable({ x = x, y = y }, V) end
    V.__add = function(p, q) return vec(p.x + q.x, p.y + q.y) end
    V.__sub = function(p, q) return vec(p.x - q.x, p.y - q.y) end
    V.__mul = function(p, k) return vec(p.x * k, p.y * k) end
    local mid = X.lerp(vec(0, 0), vec(10, 20), 0.5)
    expect(mid.x == 5 and mid.y == 10, 'mathx: lerp works on a vector type (FiveM vector2/3/4)')
    expect(X.approx(0.1 + 0.2, 0.3) and not X.approx(1, 1.001) and X.approx(1e20, 1e20 + 1e5)
        and not X.approx(0 / 0, 0 / 0) and X.approx(math.huge, math.huge), 'mathx: approx scales with magnitude, NaN is never equal')
    -- An infinity scaled the tolerance to infinity, and integers subtracted in
    -- integer arithmetic, where maxinteger - (-1) wraps to a tiny number.
    expect(not X.approx(math.huge, 1e308) and not X.approx(math.huge, -math.huge) and not X.approx(-math.huge, 5)
        and X.approx(-math.huge, -math.huge), 'mathx: approx never calls an infinity equal to a finite number or to its opposite')
    expect(not X.approx(math.maxinteger, -1) and not X.approx(math.mininteger, 1) and X.approx(math.maxinteger, math.maxinteger)
        and X.approx(3, 3.0000000001), 'mathx: approx does not let a wrapped integer difference pass')
    expect(X.toHex(255) == 'ff' and X.toHex(255, { upper = true, width = 4, prefix = '0x' }) == '0x00FF'
        and X.toHex(-16) == '-10' and X.toHex(0) == '0', 'mathx: toHex with options and sign')
    expect(X.toHex(1.5) == nil and X.toHex(2 ^ 53) == nil, 'mathx: toHex refuses a fraction and 2^53')
    -- -math.mininteger wraps back to itself, and toHex looped forever on it.
    -- Lua 5.4's is past 2^53 and refused; a 32-bit runtime's is -2^31 and printed.
    do
        debug.sethook(function() error('HUNG', 0) end, '', 2000000)
        local okHex, minHex = pcall(X.toHex, math.mininteger)
        debug.sethook()
        local minHexOk
        if math.mininteger < -(2 ^ 53) then minHexOk = okHex and minHex == nil else minHexOk = okHex and minHex == '-80000000' end
        expect(minHexOk, 'mathx: toHex(math.mininteger) answers instead of hanging, got ' .. tostring(minHex))
    end
    expect(X.fromHex('0xFF') == 255 and X.fromHex(' -a ') == -10 and X.fromHex('xyz') == nil and X.fromHex('') == nil,
        'mathx: fromHex accepts prefix, sign and case, refuses junk')
    expect(X.groupDigits(1234567) == '1,234,567' and X.groupDigits(-1234.5) == '-1,234.5'
        and X.groupDigits(999) == '999' and X.groupDigits(1234567.891, ' ', 2) == '1 234 567.89'
        and X.groupDigits('0012345') == '0,012,345', 'mathx: groupDigits')

    -- property: toHex/fromHex round-trip across the whole exact range, and
    -- toHex agrees with %x assembled from 16-bit pieces (which every runtime can format).
    local gen = Random.newGenerator(4242)
    local bad = {}
    for _ = 1, 300 do
        local n = math.floor(gen:float() * 2 ^ (gen:int(1, 53)))
        local text = X.toHex(n)
        local ref, rest = '', n
        repeat
            local piece = rest % 65536
            rest = (rest - piece) / 65536
            ref = (rest > 0 and ('%04x') or ('%x')):format(math.tointeger(piece) or piece) .. ref
        until rest == 0
        if text ~= ref or X.fromHex(text) ~= n or X.fromHex('-0x' .. text:upper()) ~= -n then
            bad[#bad + 1] = ('%.0f'):format(n)
        end
    end
    expect(#bad == 0, 'mathx: 300 random integers below 2^53 round-trip through toHex/fromHex and match %x: '
        .. table.concat(bad, ', ', 1, math.min(#bad, 4)))
    -- property: groupDigits, stripped of separators, is the plain integer text.
    local badGroup = 0
    for _ = 1, 200 do
        local n = math.floor(gen:float() * 1e12) * (gen:float() < 0.5 and -1 or 1)
        local g = X.groupDigits(n)
        if g:gsub(',', '') ~= ('%.0f'):format(n) or g:find('%d%d%d%d') then badGroup = badGroup + 1 end
    end
    expect(badGroup == 0, 'mathx: 200 random integers group into runs of at most three digits')

    -- weightedPick: same seed, same picks; frequencies follow the weights.
    local entries = { { 'a', 1 }, { 'b', 3 }, { 'c', 0 }, { 'd', 6 } }
    local g1, g2 = Random.newGenerator(5), Random.newGenerator(5)
    local same, counts = true, { a = 0, b = 0, c = 0, d = 0 }
    for _ = 1, 4000 do
        local p = X.weightedPick(entries, g1)
        if p ~= X.weightedPick(entries, g2) then same = false end
        counts[p] = counts[p] + 1
    end
    expect(same, 'mathx: weightedPick is deterministic with a seeded CisRandom generator')
    expect(counts.c == 0 and math.abs(counts.a / 4000 - 0.1) < 0.03 and math.abs(counts.b / 4000 - 0.3) < 0.04
        and math.abs(counts.d / 4000 - 0.6) < 0.04, ('mathx: weightedPick frequencies follow the weights '
        .. '(a=%d b=%d c=%d d=%d of 4000)'):format(counts.a, counts.b, counts.c, counts.d))
    local mapPick, mapIndex = X.weightedPick({ zed = 1, alpha = 1 }, function() return 0 end)
    expect(mapPick == 'alpha' and mapIndex == 1, 'mathx: a map is walked in sorted key order')
    expect(X.weightedPick({ { 'x', 0 } }) == nil and X.weightedPick({ { 'x', 2 } }, function() return 0.9999 end) == 'x',
        'mathx: weightedPick with no positive weight is nil; a draw near 1 still lands')
end

-- ===================================================================== class
do
    local C = load('shared/util/class.lua')
    local Animal = C.new('Animal')
    function Animal:constructor(name) self.name = name end
    function Animal:speak() return self.name .. ' makes a sound' end
    function Animal:__eq(other) return self.name == other.name end
    local Dog = C.new('Dog', Animal)
    function Dog:constructor(name, breed)
        Dog.super.constructor(self, name)
        self.breed = breed
    end
    function Dog:speak() return self.name .. ' barks' end
    local Puppy = C.new('Puppy', Dog)
    function Puppy:toString() return 'Puppy<' .. self.name .. '>' end

    local rex = Dog:new('Rex', 'lab')
    local fido = Dog('Fido')
    local tiny = Puppy('Tiny', 'pug')
    expect(rex.name == 'Rex' and rex.breed == 'lab' and fido.name == 'Fido', 'class: Class:new and Class() both construct')
    expect(rex:speak() == 'Rex barks' and Animal('Cat'):speak() == 'Cat makes a sound', 'class: override and base method')
    expect(tiny:speak() == 'Tiny barks' and tiny.breed == 'pug', 'class: a grandchild inherits the constructor and methods')
    expect(C.instanceof(tiny, Animal) and C.instanceof(rex, Dog) and not C.instanceof(rex, Puppy)
        and not C.instanceof({}, Animal) and not C.instanceof(rex, {}), 'class: instanceof walks the chain only')
    expect(tostring(tiny) == 'Puppy<Tiny>', 'class: toString drives tostring')
    expect(tostring(rex):match('^Dog: ') ~= nil and tostring(Dog) == 'class Dog', 'class: default tostring names the class')
    expect(Dog('Rex') == Dog('Rex'), 'class: a metamethod defined on the parent first is inherited (copied down)')
    expect(C.nameOf(rex) == 'Dog' and C.nameOf(Puppy) == 'Puppy' and C.classOf(rex) == Dog and C.isClass(Dog)
        and not C.isClass(rex), 'class: nameOf, classOf, isClass')
    expect(raises(function() C.new('X', {}) end, 'not a class'), 'class: a parent that is not a class is refused')
    expect(raises(function() return Dog.new('x') end, 'Thing:new'), 'class: Dog.new without a colon names the fix')

    -- No closure per call: the method a call resolves to is the one function on the class.
    expect(rex.speak == Dog.speak and fido.speak == rex.speak and tiny.speak == Dog.speak,
        'class: every instance shares the class function (no per-instance closures)')

    local private = C.privates()
    local Account = C.new('Account')
    function Account:constructor(balance) private(self).balance = balance end
    function Account:balance() return private(self).balance end
    local acct = Account(50)
    local fieldCount = 0
    for _ in pairs(acct) do fieldCount = fieldCount + 1 end
    expect(acct:balance() == 50 and fieldCount == 0, 'class: private fields are not on the instance')
    expect(C.privates()(acct).balance == nil, 'class: another accessor cannot see them')
end

-- ============================================================ string.random
do
    local Str = load('shared/util/string.lua')
    local plate = Str.random('1AA111', Random.newGenerator(1))
    expect(type(plate) == 'string' and plate:match('^%d%u%u%d%d%d$') ~= nil, 'string.random: 1AA111 shape')
    expect(Str.random('aaa.', Random.newGenerator(2)):match('^%l%l%l%w$') ~= nil, 'string.random: a and . classes')
    expect(Str.random('^1^A-^^x') == '1A-^x', 'string.random: ^ makes the next character literal')
    expect(Str.random('11', Random.newGenerator(3)) == Str.random('11', Random.newGenerator(3)), 'string.random: seeded is reproducible')
    expect(Str.random('1', function() return 0.9999999 end) == '9', 'string.random: a function rng near 1 stays in range')
    local okNil, why = Str.random(nil)
    expect(okNil == nil and why:find('pattern', 1, true) ~= nil, 'string.random: refuses a non-string pattern')
    expect(Str.random('1', 'x') == nil, 'string.random: refuses an rng of the wrong type')
end

-- ===================================================================== print
do
    local convars = {}
    GetConvar = function(name, default) -- luacheck: ignore 121
        local v = convars[name]
        if v == nil then return default end
        return v
    end
    GetCurrentResourceName = function() return 'shop' end -- luacheck: ignore 121
    local encodes = 0
    json = { encode = function() encodes = encodes + 1 return '{"x":1}' end } -- luacheck: ignore 121

    convars['cis:printlevel'] = 'warn'
    local P = load('shared/util/print.lua')
    expect(P.getLevel() == 'warn', 'print: the global convar sets the level')
    convars['cis:printlevel:shop'] = 'DEBUG'
    local level, from = P.refresh()
    expect(level == 'debug' and from == 'cis:printlevel:shop', 'print: the per-resource convar wins, any case')
    convars['cis:printlevel:shop'] = nil
    convars['cis:printlevel'] = nil
    expect(P.refresh() == 'info', 'print: default info')

    capture()
    local touched = 0
    local probe = setmetatable({}, { __tostring = function() touched = touched + 1 return 'probe' end })
    P.debug('hidden', probe, { big = true })
    P.verbose(probe)
    P.info('shown', 3, { a = 1 })
    P.warn('w')
    P.error('e')
    release()
    expect(touched == 0 and encodes == 1, 'print: a filtered call converts and encodes NOTHING')
    expect(#printed == 3, ('print: info, warn and error print at level info (%d lines)'):format(#printed))
    expect(printed[1] == '^7[INFO] shown\t3\t{"x":1}^7', 'print: info has its colour prefix, tab-joined args, JSON tables and a ^7 reset')
    expect(printed[2]:sub(1, 8) == '^3[WARN]' and printed[3]:sub(1, 9) == '^1[ERROR]', 'print: warn and error prefixes')

    expect(P.setLevel('nope') == nil and P.setLevel(5) == true and P.isEnabled('debug') and not P.isEnabled('bogus'),
        'print: setLevel validates; isEnabled answers for a level')
    capture()
    P.debug('now visible')
    release()
    expect(#printed == 1 and printed[1]:sub(1, 9) == '^6[DEBUG]', 'print: debug prints at level debug')

    convars['cis:printlevel'] = 'loud'
    capture()
    P.refresh()
    release()
    expect(P.getLevel() == 'info' and #printed == 1 and printed[1]:find('loud', 1, true) ~= nil,
        'print: an unknown convar value warns, naming it, and falls back to info')
end

-- ==================================================================== locale
do
    local files = {}
    local reads = {}
    LoadResourceFile = function(resource, path) -- luacheck: ignore 121
        reads[#reads + 1] = resource .. ':' .. path
        return files[path]
    end
    GetCurrentResourceName = function() return 'shop' end -- luacheck: ignore 121
    local decoded = {
        EN = { greet = 'Hello ${name}', shop = { price = 'Costs $%s', both = '${who} paid %s', only = 'en only' },
            n = 5, count = '%d items', pct = 'Hi ${name}: %s', half = '${name}: 50%% off' },
        PT = { greet = 'Ola ${name}', shop = { price = 'Custa R$%s' } },
    }
    json = { decode = function(text) -- luacheck: ignore 121
        if decoded[text] then return decoded[text] end
        error('unexpected character')
    end }
    local convars = { ['cis:locale'] = 'pt' }
    GetConvar = function(name, default) -- luacheck: ignore 121
        if convars[name] ~= nil then return convars[name] end
        return default
    end
    files['locales/en.json'] = 'EN'
    files['locales/pt.json'] = 'PT'

    local L = load('shared/util/locale.lua')
    expect(L.t('greet', { name = 'Ana' }) == 'Ola Ana', 'locale: t() loads the convar language on first use and fills ${name}')
    expect(reads[1]:sub(1, 5) == 'shop:', 'locale: files are read from the CALLING resource')
    expect(L.getLanguage() == 'pt', 'locale: the convar picks the language')
    expect(L.t('shop.price', 250) == 'Custa R$250', 'locale: nested keys flatten to dots; %s is positional')
    expect(L.t('shop.only') == 'en only', 'locale: a key missing from the language falls back to English')
    expect(L.t('shop.both', { who = 'Bo' }, 9) == 'Bo paid 9', 'locale: a table then positional arguments')
    expect(L.t('n') == '5', 'locale: a number phrase becomes text')
    -- ${name} was filled first and the result went through string.format, so a
    -- value holding '%' broke the positional arguments, and '%%' collapsed only
    -- when a positional argument came with the table.
    expect(L.t('pct', { name = '50%' }, 'x') == 'Hi 50%: x' and L.t('pct', { name = '100%s' }, 'x') == 'Hi 100%s: x',
        'locale: a named value holding % is printed as it is and leaves the positional arguments alone')
    expect(L.t('half', { name = 'A' }) == 'A: 50% off' and L.t('half', { name = 'A' }, 1) == 'A: 50% off',
        'locale: %% is one % with a table alone and with a table plus positional arguments')

    capture()
    local miss1 = L.t('nope.key')
    local miss2 = L.t('nope.key')
    release()
    expect(miss1 == 'nope.key' and miss2 == 'nope.key' and #printed == 1 and printed[1]:find('nope.key', 1, true),
        'locale: a missing key answers the key and warns ONCE')

    expect(L.set('en') == 'en' and L.t('shop.price', 3) == 'Costs $3', 'locale: set switches language')
    capture()
    local used = L.load('fr')
    release()
    expect(used == 'en' and L.t('greet', { name = 'X' }) == 'Hello X' and #printed == 1,
        'locale: a missing language file falls back to en, and says so')
    local bad, why = L.load('../secrets')
    expect(bad == nil and why:find('language must be', 1, true) ~= nil, 'locale: a language name cannot become a path')
    files['locales/en.json'] = nil
    local none, noneWhy = L.load('de')
    expect(none == nil and noneWhy:find('locales/de.json', 1, true) and noneWhy:find('en.json', 1, true),
        'locale: with no file and no en fallback, the refusal names both files')
    files['locales/xx.json'] = 'NOT JSON'
    local broken, brokenWhy = L.load('xx')
    expect(broken == nil and brokenWhy:find('not a JSON object', 1, true) ~= nil, 'locale: bad JSON is a reason, not a crash')
    files['locales/en.json'] = 'EN'
    L.load('en')
    capture()
    local unfit = L.t('count', 'many')
    release()
    expect(unfit == '%d items' and #printed == 1, 'locale: a phrase that does not fit its arguments comes back unformatted and warns')
    expect(L.has('greet') and not L.has('nope'), 'locale: has')
end

-- ============================================================ fake scheduler
-- CreateThread / Wait / GetGameTimer for timer and cron: a virtual clock in
-- milliseconds and coroutines that yield the time they want to sleep. Like
-- FiveM, a new thread runs at once until its first Wait.
local clock = { now = 0, threads = {} }
local function resumeThread(t)
    local ok, ms = coroutine.resume(t.co)
    if not ok then error(ms, 0) end
    if coroutine.status(t.co) == 'dead' then
        t.dead = true
    else
        t.wake = clock.now + (ms or 0)
    end
end
CreateThread = function(fn) -- luacheck: ignore 121
    local t = { co = coroutine.create(fn), wake = clock.now }
    clock.threads[#clock.threads + 1] = t
    resumeThread(t)
end
Wait = function(ms) coroutine.yield(ms) end -- luacheck: ignore 121
GetGameTimer = function() return clock.now end -- luacheck: ignore 121
local function advance(ms)
    local target = clock.now + ms
    while true do
        local best
        for _, t in ipairs(clock.threads) do
            if not t.dead and t.wake <= target and (best == nil or t.wake < best.wake) then best = t end
        end
        if not best then break end
        if best.wake > clock.now then clock.now = best.wake end
        resumeThread(best)
    end
    clock.now = target
end
local function liveThreads()
    local n = 0
    for _, t in ipairs(clock.threads) do if not t.dead then n = n + 1 end end
    return n
end

-- ===================================================================== timer
do
    local T = load('shared/util/timer.lua')
    local ended = 0
    local t = T.new(1000, function() ended = ended + 1 end)
    expect(not t:isPaused() and t:getTimeLeft('ms') == 1000, 'timer: a new timer starts running')
    local wakes = 0
    for _, th in ipairs(clock.threads) do if not th.dead then wakes = wakes + 1 end end
    expect(wakes == 1 and clock.threads[#clock.threads].wake == 1000, 'timer: one thread, asleep for exactly the time left')
    advance(400)
    expect(t:getTimeLeft('ms') == 600 and t:pause() and t:isPaused(), 'timer: pause keeps the time left')
    advance(5000)
    expect(ended == 0 and t:getTimeLeft('ms') == 600 and not t:hasEnded(), 'timer: a paused timer does not run out')
    expect(liveThreads() == 0, 'timer: pausing retires the sleeper -- nothing keeps waking while paused')
    expect(t:pause() == false and t:play() and t:play() == false, 'timer: pause/play answer false when there is nothing to do')
    advance(599)
    expect(ended == 0 and t:getTimeLeft('s') == 0, 'timer: not yet (getTimeLeft s rounds to 2 places)')
    advance(1)
    expect(ended == 1 and t:hasEnded() and t:getTimeLeft('ms') == 0, 'timer: onEnd fires once when the time is up')
    advance(10000)
    expect(ended == 1, 'timer: and never again')
    expect(liveThreads() == 0, 'timer: every sleeper has exited, including the one retired by the pause')

    t:restart()
    advance(250)
    local parts = t:getTimeLeft()
    expect(parts.s == 0 and parts.ms == 750 and parts.h == 0 and parts.m == 0, 'timer: restart, and the breakdown form')
    expect(T.forceEnd(t, true) and ended == 2 and T.forceEnd(t) == false, 'timer: forceEnd(true) calls onEnd; a second forceEnd is false')
    advance(5000)
    expect(ended == 2, 'timer: the retired run does not call onEnd after forceEnd')
    local quiet = T.new(100, nil, { autoStart = false })
    expect(quiet:isPaused() and quiet:getTimeLeft('ms') == 100, 'timer: autoStart = false starts paused')
    local long = T.new(2 * 3600000 + 3 * 60000 + 4500, nil)
    local lp = long:getTimeLeft()
    expect(lp.h == 2 and lp.m == 3 and lp.s == 4 and lp.ms == 500 and long:getTimeLeft('h') == 2.05,
        'timer: hours/minutes/seconds breakdown and the h format')
    long:forceEnd()
    expect(raises(function() T.pause({}) end, 'expected a timer'), 'timer: a non-timer is refused with the fix')
    expect(raises(function() T.new(-1) end, 'milliseconds'), 'timer: a negative duration is refused')

    -- setTimeout / setInterval, either argument order, cancellable.
    local log = {}
    local id1 = T.setTimeout(function(a, b) log[#log + 1] = 'timeout:' .. a .. b end, 500, 'x', 'y')
    local id2 = T.setTimeout(300, function() log[#log + 1] = 'never' end)
    expect(T.clearTimeout(id2) and not T.clearTimeout(id2), 'timer: clearTimeout answers whether it was pending')
    local ticks = 0
    local iv
    iv = T.setInterval(function()
        ticks = ticks + 1
        if ticks == 3 then T.clearInterval(iv) end
        if ticks == 2 then error('boom') end
    end, 200)
    capture()
    advance(2000)
    release()
    expect(#log == 1 and log[1] == 'timeout:xy', 'timer: setTimeout(fn, ms, ...) passes its arguments; a cleared one never runs')
    expect(ticks == 3, ('timer: setInterval keeps going after a raise and stops when cleared from inside (%d ticks)'):format(ticks))
    expect(#printed == 1 and printed[1]:find('boom', 1, true) ~= nil, 'timer: the interval error is reported with its message')
    expect(T.clearTimeout(id1) == false, 'timer: a timeout that already ran is not pending')
    -- The long timer's sleeper was retired by forceEnd and exits when it wakes.
    advance(3 * 3600000)
    expect(liveThreads() == 0, 'timer: no thread is left behind')
    -- Every play used to spawn a sleeper, and a paused timer's old ones slept on
    -- until their original deadline: 500 cycles left 501 threads.
    local cycles = 0
    local cyc = T.new(100000, function() cycles = cycles + 1 end)
    for _ = 1, 500 do
        cyc:pause()
        advance(1)
        cyc:play()
    end
    expect(liveThreads() == 1, ('timer: pause/play cycles reuse one sleeper (%d threads)'):format(liveThreads()))
    advance(99999)
    expect(cycles == 0 and cyc:getTimeLeft('ms') == 1, 'timer: a reused sleeper does not end the timer early')
    advance(1)
    expect(cycles == 1 and cyc:hasEnded() and liveThreads() == 0, 'timer: and ends it on time, once, leaving no thread')
    -- A sleeper that wakes while the timer is paused exits; a later play starts a new one.
    local gap = T.new(100, nil)
    gap:pause()
    advance(500)
    expect(liveThreads() == 0, 'timer: the sleeper of a paused timer exits when it wakes')
    gap:play()
    expect(liveThreads() == 1, 'timer: and play after that starts one again')
    advance(100)
    expect(gap:hasEnded() and liveThreads() == 0, 'timer: which ends the timer')
    expect(raises(function() T.setTimeout(1, 2) end, 'either order'), 'timer: two numbers are refused, naming both orders')
end

-- ====================================================================== cron
do
    local Cr = load('shared/util/cron.lua')

    -- ---- parse ----
    local spec = Cr.parse('*/15 9-17 * jan,MAR-may mon-fri')
    expect(spec ~= nil and #spec.minutes == 4 and spec.hours[1] == 9 and #spec.hours == 9
        and #spec.months == 4 and #spec.weekdays == 5, 'cron: parse steps, ranges, lists and names in any case')
    expect(#Cr.parse('0 0 * * 5-7').weekdays == 3 and Cr.parse('0 0 * * 7').weekdays[1] == 0,
        'cron: 7 is Sunday')
    expect(#Cr.parse('5/20 * * * *').minutes == 3, 'cron: a/s runs from a to the maximum')
    local daily = Cr.parse('@daily')
    expect(daily and daily.minutes[1] == 0 and daily.hours[1] == 0 and #daily.days == 31, 'cron: @daily')
    local refusals = {
        { '* * * *', 'needs 5' }, { '60 * * * *', 'outside' }, { '* * * * fri-mon', 'fri-sat,sun-mon' },
        { '*/0 * * * *', 'step' }, { '1,,2 * * * *', 'empty list' }, { '@reboot', 'not a macro' },
        { '0 0 30 2 *', 'never run' }, { 'x * * * *', 'not a valid minute' }, { '* * * foo *', 'month' },
    }
    local wrong = {}
    for _, r in ipairs(refusals) do
        local s, why = Cr.parse(r[1])
        if s ~= nil or type(why) ~= 'string' or not why:find(r[2], 1, true) then
            wrong[#wrong + 1] = r[1] .. ' -> ' .. tostring(why)
        end
    end
    expect(#wrong == 0, 'cron: malformed expressions are refused with a reason naming the field or the fix: '
        .. table.concat(wrong, '; '))

    -- ---- next: fixed cases in UTC ----
    local function utc(y, m, d, h, mi)
        -- Independent of the module: os.time on a UTC table, corrected by the
        -- host's offset at that instant.
        local guess = os.time({ year = y, month = m, day = d, hour = h, min = mi, sec = 0 })
        local back = os.date('!*t', guess)
        local diff = os.time({ year = back.year, month = back.month, day = back.day, hour = back.hour,
            min = back.min, sec = 0 }) - guess
        return guess - diff
    end
    local base = utc(2024, 1, 31, 23, 59)
    expect(Cr.next('@hourly', base, { utc = true }) == utc(2024, 2, 1, 0, 0), 'cron: @hourly crosses a month')
    expect(Cr.next('0 0 29 2 *', base, { utc = true }) == utc(2024, 2, 29, 0, 0), 'cron: Feb 29 in a leap year')
    expect(Cr.next('0 0 29 2 *', utc(2024, 3, 1, 0, 0), { utc = true }) == utc(2028, 2, 29, 0, 0),
        'cron: Feb 29 skips to the next leap year')
    -- 2024-09-13 was a Friday. OR: the 13th OR a Friday; the first after Sep 10 is Fri the 13th,
    -- and after that Fri the 20th.
    expect(Cr.next('0 12 13 * fri', utc(2024, 9, 10, 0, 0), { utc = true }) == utc(2024, 9, 13, 12, 0)
        and Cr.next('0 12 13 * fri', utc(2024, 9, 13, 12, 0), { utc = true }) == utc(2024, 9, 20, 12, 0),
        'cron: day-of-month and day-of-week are ORed when both are restricted (Vixie)')
    -- `*/1` starts with '*': ANDed, so only Fridays.
    expect(Cr.next('0 12 */1 * fri', utc(2024, 9, 14, 0, 0), { utc = true }) == utc(2024, 9, 20, 12, 0)
        and Cr.next('0 12 1-31 * fri', utc(2024, 9, 14, 0, 0), { utc = true }) == utc(2024, 9, 14, 12, 0),
        'cron: a field starting with * makes it AND; 1-31 does not')
    expect(Cr.next('30 * * * *', utc(2024, 1, 1, 10, 30), { utc = true }) == utc(2024, 1, 1, 11, 30),
        'cron: next is strictly after from')
    expect(Cr.next('0 0 * * *', utc(2024, 12, 31, 23, 59) + 59, { utc = true }) == utc(2025, 1, 1, 0, 0),
        'cron: crosses a year from inside the last minute')
    expect(Cr.matches('*/5 * * * *', utc(2024, 5, 5, 5, 10) + 30, { utc = true })
        and not Cr.matches('*/5 * * * *', utc(2024, 5, 5, 5, 11), { utc = true }), 'cron: matches tests the minute')
    local nn, nwhy = Cr.next('nope')
    expect(nn == nil and type(nwhy) == 'string', 'cron: next refuses a bad expression with the reason')
    -- os.date raises on a time the platform cannot convert, and on a non-number
    -- math.floor did; both now answer nil plus a reason.
    local huge, hwhy = Cr.next('* * * * *', 1e18, { utc = true })
    expect(huge == nil and type(hwhy) == 'string', 'cron: next answers nil and a reason for a time too large to convert')
    local hugeL, hwhyL = Cr.next('* * * * *', -1e18)
    expect(hugeL == nil and type(hwhyL) == 'string', 'cron: and for one too early, in local time')
    local mnone, mwhy = Cr.matches('* * * * *', 'abc')
    expect(mnone == nil and type(mwhy) == 'string', 'cron: matches refuses a time that is not a number')
    local mnan, mnwhy = Cr.matches('* * * * *', 0 / 0)
    expect(mnan == nil and type(mnwhy) == 'string', 'cron: matches refuses NaN')
    local mbig, mbwhy = Cr.matches('* * * * *', 1e18, { utc = true })
    expect(mbig == nil and type(mbwhy) == 'string', 'cron: matches answers nil and a reason for a time too large to convert')

    -- ---- property: next vs a brute-force walk, in UTC ----
    local gen = Random.newGenerator(1337)
    local MONTHS = { 'jan', 'feb', 'mar', 'apr', 'may', 'jun', 'jul', 'aug', 'sep', 'oct', 'nov', 'dec' }
    local DAYS = { [0] = 'sun', 'mon', 'tue', 'wed', 'thu', 'fri', 'sat' }
    -- One field: the text, the set it means, and whether it starts with '*'.
    local function randField(lo, hi, names, isDow)
        local set, parts = {}, {}
        local function name(v)
            if names and gen:float() < 0.4 then
                return names[v] or tostring(v)
            end
            if isDow and v == 0 and gen:float() < 0.3 then return '7' end
            return tostring(v)
        end
        local shape = gen:int(1, 10)
        if shape <= 3 then
            for v = lo, hi do set[v] = true end
            return '*', set, true
        elseif shape == 4 then
            local step = gen:int(2, math.max(2, (hi - lo) // 2))
            for v = lo, hi, step do set[v] = true end
            return '*/' .. step, set, true
        end
        for _ = 1, gen:int(1, 3) do
            local a = gen:int(lo, hi)
            local form = gen:int(1, 3)
            if form == 1 then
                set[a] = true
                parts[#parts + 1] = name(a)
            else
                local b = gen:int(a, hi)
                local step = form == 3 and gen:int(1, 4) or 1
                for v = a, b, step do set[v] = true end
                parts[#parts + 1] = name(a) .. '-' .. name(b) .. (form == 3 and ('/' .. step) or '')
            end
        end
        return table.concat(parts, ','), set, false
    end
    local monthNames = {}
    for i = 1, 12 do monthNames[i] = MONTHS[i] end
    local function refNext(sets, from)
        -- Day by day, then minute by minute inside a matching day: nothing but
        -- os.date and the sets the generator meant.
        local t = from - from % 60 + 60
        local limit = from + 12 * 366 * 86400
        while t <= limit do
            local f = os.date('!*t', t)
            local domOk = sets.dom[f.day] == true
            local dowOk = sets.dow[f.wday - 1] == true
            local dayOk
            if sets.domStar or sets.dowStar then dayOk = domOk and dowOk else dayOk = domOk or dowOk end
            if sets.month[f.month] and dayOk then
                if sets.hour[f.hour] and sets.minute[f.min] then return t end
                t = t + 60
            else
                t = t - t % 86400 + 86400
            end
        end
        return nil
    end
    local mismatches, compared, skipped = {}, 0, 0
    for case = 1, 250 do
        local sets = {}
        local fm, fh, fd, fmo, fw
        fm, sets.minute = randField(0, 59)
        fh, sets.hour = randField(0, 23)
        fd, sets.dom, sets.domStar = randField(1, 31)
        fmo, sets.month = randField(1, 12, monthNames)
        fw, sets.dow, sets.dowStar = randField(0, 6, DAYS, true)
        local expr = table.concat({ fm, fh, fd, fmo, fw }, ' ')
        local from = 946684800 + gen:int(0, 24 * 365 * 86400 - 1)
        local s = Cr.parse(expr)
        if s == nil then
            skipped = skipped + 1   -- e.g. only Feb 30: refused by design, checked above
        else
            local want = refNext(sets, from)
            if want == nil then
                skipped = skipped + 1
            else
                compared = compared + 1
                local got = Cr.next(s, from, { utc = true })
                if got ~= want and #mismatches < 4 then
                    mismatches[#mismatches + 1] = ('#%d %q from %s: got %s want %s'):format(case, expr,
                        tostring(from), tostring(got), tostring(want))
                end
                -- and the answer matches, by the module's own test
                if got and not Cr.matches(s, got, { utc = true }) and #mismatches < 4 then
                    mismatches[#mismatches + 1] = ('#%d %q: next does not match itself'):format(case, expr)
                end
            end
        end
    end
    expect(#mismatches == 0 and compared >= 200, ('cron: next agrees with a brute-force walk on %d random '
        .. 'expressions and dates (%d skipped): %s'):format(compared, skipped, table.concat(mismatches, '; ')))

    -- ---- local time: the default path, against the same walk on os.date('*t') ----
    local function refLocal(expr, from)
        local t = from - from % 60 + 60
        for _ = 1, 8 * 1440 do
            if Cr.matches(expr, t) then return t end
            t = t + 60
        end
    end
    local mid = os.time({ year = 2024, month = 1, day = 15, hour = 12, min = 7, sec = 30 })
    local localOk = true
    for _, expr in ipairs({ '*/10 * * * *', '0 * * * *', '30 18 * * *', '0 9 * * mon', '15 3 16 1 *' }) do
        if Cr.next(expr, mid) ~= refLocal(expr, mid) then localOk = false end
    end
    expect(localOk, 'cron: local-time next agrees with a minute walk over os.date("*t")')

    -- ---- the scheduler ----
    local realTime = os.time
    local EPOCH = utc(2024, 3, 1, 10, 0) - 30
    local t0 = clock.now
    local function wall() return EPOCH + (clock.now - t0) // 1000 end
    os.time = function(t) -- luacheck: ignore 122
        if t then return realTime(t) end
        return wall()
    end
    local runs = {}
    local before = #clock.threads
    local minutely = Cr.schedule('* * * * *', function(job, due) runs[#runs + 1] = { 'minute', due, job } end,
        { utc = true })
    local fiveMin = Cr.schedule('*/5 * * * *', function(_, due) runs[#runs + 1] = { 'five', due } end, { utc = true })
    expect(minutely and fiveMin and #clock.threads - before == 1 and liveThreads() == 1,
        'cron: two jobs, ONE scheduler thread')
    expect(clock.threads[#clock.threads].wake == t0 + 30000, 'cron: the thread sleeps until the first due job, not a frame')
    advance(30000)
    expect(#runs == 2 and runs[1][1] == 'minute' and runs[2][1] == 'five' and runs[1][2] == EPOCH + 30
        and runs[1][3] == minutely, 'cron: both jobs due at 10:00 run in id order with (job, due)')
    advance(60000 * 5)
    expect(#runs == 8 and runs[7][1] == 'minute' and runs[8][1] == 'five' and runs[8][2] == EPOCH + 330,
        'cron: 10:01-10:04 run the minutely job only, 10:05 both')
    expect(minutely:stop() and not minutely:isActive() and minutely:stop() == false and Cr.nextRun(minutely) == nil,
        'cron: stop, isActive and nextRun')
    local errored = Cr.schedule('* * * * *', function() error('cron boom') end, { utc = true, name = 'flaky' })
    capture()
    advance(60000 * 5)
    release()
    expect(#runs == 9 and errored:isActive() and #printed == 5 and printed[1]:find('flaky', 1, true)
        and printed[1]:find('cron boom', 1, true), 'cron: a raising job is reported by name and stays scheduled')
    errored:stop()
    -- A stall: nothing runs for an hour, then the five-minute job runs ONCE.
    clock.now = clock.now + 3600000
    advance(1)
    local fiveRuns = 0
    for _, r in ipairs(runs) do if r[1] == 'five' then fiveRuns = fiveRuns + 1 end end
    expect(fiveRuns == 4, ('cron: a stalled hour runs a missed job once, not twelve times (%d five-minute runs)')
        :format(fiveRuns))
    local nextDue = fiveMin:nextRun()
    expect(nextDue > wall() and nextDue % 300 == 0, 'cron: and the next run is in the future, on the grid')
    -- A job due EARLIER than the planned wake is not missed.
    local hourly = Cr.schedule('0 * * * *', function() end, { utc = true })
    fiveMin:stop()
    local soon = {}
    Cr.schedule('* * * * *', function(job) soon[#soon + 1] = true job:stop() end, { utc = true })
    advance(61000)
    expect(#soon == 1, 'cron: a job scheduled to run before the planned wake still runs on time')
    hourly:stop()
    advance(3600000)
    expect(Cr.count() == 0 and liveThreads() == 0, 'cron: with no jobs left the scheduler thread exits')
    local bad1, why1 = Cr.schedule('* * *', function() end)
    local bad2, why2 = Cr.schedule('* * * * *', 'x')
    expect(bad1 == nil and why1:find('5', 1, true) and bad2 == nil and why2:find('function', 1, true),
        'cron: schedule refuses a bad expression and a non-function')
    os.time = realTime -- luacheck: ignore 122
end

-- ====================================================== re-audit lows (A-L5..A-L9)
do
    local X = load('shared/util/mathx.lua')
    local Str = load('shared/util/string.lua')
    local A = load('shared/util/array.lua')
    local C = load('shared/util/class.lua')

    -- A-L5: an integer is formatted as an integer, and a bad decimals is a refusal.
    local want = math.maxinteger > 2 ^ 40 and '9,223,372,036,854,775,807' or '2,147,483,647'
    expect(X.groupDigits(math.maxinteger) == want,
        'mathx: groupDigits writes math.maxinteger digit for digit, not through a float')
    local wantMin = math.maxinteger > 2 ^ 40 and '-9,223,372,036,854,775,808' or '-2,147,483,648'
    expect(X.groupDigits(math.mininteger) == wantMin, 'mathx: groupDigits writes math.mininteger exactly')
    for _, bad in ipairs({ 'x', -1, 100, 0 / 0, math.huge, {} }) do
        local ok, out, why = pcall(X.groupDigits, 1234.5, ',', bad)
        expect(ok and out == nil and type(why) == 'string',
            ('mathx: groupDigits refuses decimals %s with a reason instead of raising'):format(tostring(bad)))
    end
    expect(X.groupDigits(1234.5, ',', 2.9) == '1,234.50', 'mathx: a fractional decimals still floors')

    -- A-L6: a width that is not a whole number is floored, and a missing one pads nothing.
    expect(Str.padStart('a', 2.5) == ' a' and Str.padEnd('a', 2.5) == 'a ',
        'string: pad floors a fractional width')
    expect(Str.padStart('a') == 'a' and Str.padEnd('a') == 'a' and Str.padStart('a', 'x') == 'a'
        and Str.padStart('a', 0 / 0) == 'a' and Str.padEnd('a', math.huge) == 'a',
        'string: pad with no usable width returns the text unchanged')

    -- A-L7: the sum leaves the integers instead of wrapping, and flat survives a cycle.
    local total = A.sum({ math.maxinteger, 1 })
    expect(total == math.maxinteger + 1.0, 'array: sum past the integer range goes to a float, not a wrapped negative')
    local low = A.sum({ math.mininteger, -1 })
    expect(low == math.mininteger - 1.0, 'array: sum below the integer range goes to a float too')
    expect(A.sum({ 1, 2, 3 }) == 6 and math.type(A.sum({ 1, 2, 3 })) == 'integer',
        'array: a sum that fits stays an integer')
    local cyc = { 1 }
    cyc[2] = cyc
    cyc[3] = { 2, cyc }
    local okFlat, flat = pcall(A.flat, cyc, math.huge)
    expect(okFlat and flat[1] == 1 and flat[2] == cyc and flat[3] == 2 and flat[4] == cyc,
        'array: flat keeps a reference to a table it is already inside, instead of overflowing the stack')
    local shared = { 7 }
    local twice = A.flat({ shared, shared }, math.huge)
    expect(twice[1] == 7 and twice[2] == 7, 'array: flat still spreads the same table met twice, side by side')

    -- A-L9: a subclass keeps the parent's guards.
    local Base = C.new('Base')
    Base.__newindex = function(_, k) error('read-only: ' .. tostring(k), 0) end
    Base.__gc = function() end
    local Sub = C.new('Sub', Base)
    expect(not pcall(function() Sub:new().x = 1 end), 'class: a read-only parent stays read-only through a subclass')
    expect(rawget(Sub, '__gc') == Base.__gc, 'class: __gc is copied down to a subclass')
    local Dyn = C.new('Dyn')
    function Dyn:hello() return 'hi' end
    Dyn.__index = function(_, k)
        local m = rawget(Dyn, k)
        if m ~= nil then return m end
        return 'dyn:' .. tostring(k)
    end
    local Kid = C.new('Kid', Dyn)
    function Kid:own() return 'own' end
    local kid = Kid:new()
    expect(kid.anything == 'dyn:anything' and kid:hello() == 'hi' and kid:own() == 'own',
        'class: a parent __index function still answers for a subclass instance, and methods still resolve')
    local plain = C.new('Plain', C.new('Root'))
    expect(rawget(plain, '__index') == plain, 'class: a plain parent leaves the subclass __index as the class itself')
end

io.write(('devx module tests: passed=%d failed=%d\n'):format(passed, failed))
if failed > 0 then
    os.exit(1)
end
