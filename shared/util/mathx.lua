-- Number helpers the standard math library leaves out: rounding to decimals,
-- clamping and remapping, tolerant comparison, hex text, digit grouping and a
-- weighted pick that is reproducible with a seeded generator.
--
-- Named `mathx` so it never shadows `math`. Where a function is plain
-- arithmetic -- lerp -- it is written with operators only, so a FiveM vector2,
-- vector3 or vector4 works as well as a number: `mathx.lerp(vec3a, vec3b, 0.5)`.

local M = {}

local TWO53 = 9007199254740992

local function isNumber(v)
    return type(v) == 'number' and v == v
end

-- An integer when the value is whole and fits, else the float unchanged.
local function tidy(v)
    return math.tointeger(v) or v
end

--- Round half AWAY from zero, to a number of decimal places.
---@param n number
---@param decimals? integer  default 0; negative rounds to tens, hundreds...
---@return number  n itself when it is an integer and decimals is not negative; an integer when decimals is 0 and the result fits one; NaN and infinities come back unchanged
function M.round(n, decimals)
    if type(n) ~= 'number' then
        error(('mathx.round: expected a number, got %s'):format(type(n)), 2)
    end
    if n ~= n or n == math.huge or n == -math.huge then
        return n
    end
    local d = decimals or 0
    if type(d) ~= 'number' or d % 1 ~= 0 then
        error(('mathx.round: decimals must be a whole number, got %s'):format(tostring(decimals)), 2)
    end
    -- A whole number has nothing to round to a decimal place, and going through a
    -- float would change an integer past 2^53 or flip math.mininteger's sign.
    if d >= 0 and math.type(n) == 'integer' then
        return n
    end
    -- Past 308 places the scale is infinite, and 0 * inf or inf / inf is NaN.
    if d > 308 then d = 308 elseif d < -308 then d = -308 end
    local a = n >= 0 and n or -(n + 0.0)
    local r
    if d >= 0 then
        local m = 10 ^ d
        local scaled = a * m
        -- Beyond 2^52 every double is whole already, and the scale may overflow.
        if scaled >= 2 ^ 52 then
            return d == 0 and tidy(n) or n
        end
        local f = math.floor(scaled)
        -- The fraction against one half, not floor(x + 0.5): that sum rounds
        -- 0.49999999999999994 up to 1.0.
        r = (scaled - f >= 0.5 and f + 1 or f) / m
    else
        -- Divide then multiply: 10 ^ -1 is not exactly 0.1, and n * 0.1 / 0.1
        -- drifts where n / 10 * 10 does not.
        local m = 10 ^ -d
        local scaled = a / m
        local f = math.floor(scaled)
        r = (scaled - f >= 0.5 and f + 1 or f) * m
    end
    if n < 0 then r = -r end
    if d <= 0 then
        return tidy(r)
    end
    return r
end

--- Clamp into [lo, hi]. Reversed bounds are swapped rather than refused.
---@param v number
---@param lo number
---@param hi number
---@return number
function M.clamp(v, lo, hi)
    if lo > hi then lo, hi = hi, lo end
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

--- Linear interpolation; t is not clamped. Works for numbers and FiveM vectors alike.
---@param a number|vector2|vector3|vector4
---@param b number|vector2|vector3|vector4
---@param t number  0 gives a, 1 gives b
---@return number|vector2|vector3|vector4
function M.lerp(a, b, t)
    return a + (b - a) * t
end

--- Where v sits between a and b, as a fraction: the inverse of lerp.
---@param a number
---@param b number
---@param v number
---@return number  0 when a == b, rather than a division by zero
function M.inverseLerp(a, b, v)
    if a == b then
        return 0
    end
    return (v - a) / (b - a)
end

--- Map v from [inMin, inMax] onto [outMin, outMax].
---@param v number
---@param inMin number
---@param inMax number
---@param outMin number
---@param outMax number
---@param clamped? boolean  keep the result inside the output range
---@return number
function M.remap(v, inMin, inMax, outMin, outMax, clamped)
    local t = M.inverseLerp(inMin, inMax, v)
    if clamped then
        if t < 0 then t = 0 elseif t > 1 then t = 1 end
    end
    return outMin + (outMax - outMin) * t
end

--- Equal within a tolerance that scales with the magnitude: |a - b| <= epsilon * max(1, |a|, |b|).
---@param a number
---@param b number
---@param epsilon? number  default 1e-9
---@return boolean  false when either side is NaN; equal infinities are equal
function M.approx(a, b, epsilon)
    if not isNumber(a) or not isNumber(b) then
        return false
    end
    if a == b then
        return true
    end
    -- Unequal and either side infinite: the tolerance would scale to infinity too.
    if a == math.huge or a == -math.huge or b == math.huge or b == -math.huge then
        return false
    end
    -- In floats: integer arithmetic wraps, and math.abs(math.mininteger) with it.
    a, b = a + 0.0, b + 0.0
    local eps = epsilon or 1e-9
    local scale = math.max(1, math.abs(a), math.abs(b))
    return math.abs(a - b) <= eps * scale
end

local HEX = '0123456789abcdef'

--- A whole number as hexadecimal text, with no prefix.
---@param n number  whole, with magnitude below 2^53; negative gives a leading '-'
---@param opts? table  { upper = boolean, width = integer (zero-padded), prefix = string such as '0x' }
---@return string|nil
---@return string|nil  why, for a fraction, NaN, infinity or a magnitude a double cannot hold exactly
function M.toHex(n, opts)
    if type(n) ~= 'number' then
        return nil, ('expected a number, got %s'):format(type(n))
    end
    if n ~= n or n % 1 ~= 0 then
        return nil, ('%s is not a whole number'):format(tostring(n))
    end
    local negative = n < 0
    -- Negated as a float: on integers -math.mininteger wraps back to itself, so v
    -- stayed negative, passed the 2^53 check and the loop below never reached 0.
    local v = negative and -(n + 0.0) or n
    if v >= TWO53 then
        return nil, ('%s is beyond 2^53, where a double stops holding every integer'):format(tostring(n))
    end
    -- Division, not '%x': '%x' raises on a float in Lua 5.4 and on anything past
    -- 2^31 in a 32-bit-integer runtime.
    local digits, k = {}, 0
    repeat
        local d = v % 16
        k = k + 1
        digits[k] = HEX:sub(d + 1, d + 1)
        v = (v - d) / 16
    until v == 0
    local out = {}
    for i = k, 1, -1 do out[#out + 1] = digits[i] end
    local text = table.concat(out)
    opts = opts or {}
    if opts.upper then text = text:upper() end
    local width = opts.width
    if type(width) == 'number' and #text < width then
        text = ('0'):rep(width - #text) .. text
    end
    if type(opts.prefix) == 'string' then text = opts.prefix .. text end
    if negative then text = '-' .. text end
    return text
end

--- Hexadecimal text back to a number. Accepts an optional sign and a 0x prefix, any case.
---@param s string
---@return number|nil  an integer where the runtime can hold it
---@return string|nil  why
function M.fromHex(s)
    if type(s) ~= 'string' then
        return nil, ('expected a string, got %s'):format(type(s))
    end
    local sign, body = s:match('^%s*([+-]?)(.-)%s*$')
    body = body:gsub('^0[xX]', '')
    if body == '' or body:find('[^%x]') then
        return nil, ('%q is not hexadecimal'):format(s)
    end
    -- Accumulated as a float: tonumber(s, 16) wraps past the integer width.
    local v = 0.0
    for i = 1, #body do
        v = v * 16 + tonumber(body:sub(i, i), 16)
        if v >= TWO53 then
            return nil, ('%q is beyond 2^53, where a double stops holding every integer'):format(s)
        end
    end
    if sign == '-' then v = -v end
    return tidy(v)
end

--- Thousands separators: 1234567.891 -> '1,234,567.891'.
---@param n number|string  a number, or a numeric string (kept exactly as written)
---@param sep? string  default ','
---@param decimals? integer  fix the number of decimals first (numbers only)
---@return string|nil
---@return string|nil  why
function M.groupDigits(n, sep, decimals)
    sep = sep or ','
    local text
    if type(n) == 'number' then
        if n ~= n or n == math.huge or n == -math.huge then
            return tostring(n)
        end
        if decimals ~= nil then
            text = ('%.' .. tostring(math.floor(decimals)) .. 'f'):format(n)
        elseif n % 1 == 0 and math.abs(n) < 1e21 then
            text = ('%.0f'):format(n)
        else
            text = ('%.14g'):format(n)
        end
    elseif type(n) == 'string' then
        text = n
    else
        return nil, ('expected a number or a numeric string, got %s'):format(type(n))
    end
    local sign, int, rest = text:match('^([+-]?)(%d+)(.*)$')
    if not int then
        return nil, ('%q does not start with digits'):format(text)
    end
    -- An exponent means the digits are not the number's digits; leave it alone.
    if rest:find('[eE]') then
        return text
    end
    local groups = {}
    local first = #int % 3
    if first > 0 then groups[1] = int:sub(1, first) end
    for i = first + 1, #int, 3 do
        groups[#groups + 1] = int:sub(i, i + 2)
    end
    return sign .. table.concat(groups, sep) .. rest
end

local function draw01(rng)
    local v
    if rng == nil then
        v = math.random()
    elseif type(rng) == 'function' then
        v = rng()
    elseif type(rng) == 'table' and type(rng.float) == 'function' then
        v = rng:float()
    else
        error(('mathx.weightedPick: rng must be a CisRandom generator, a function or nil, got %s')
            :format(type(rng)), 3)
    end
    if type(v) ~= 'number' or v ~= v or v < 0 then return 0 end
    if v >= 1 then return 0.9999999999 end
    return v
end

--- A weighted random choice. Reproducible: pass a generator from Cis.require('random').newGenerator(seed).
---@param entries table  an array of { value, weight } pairs, or a map value -> weight (walked in sorted key order, so the same seed picks the same entry)
---@param rng? table|fun(): number  a CisRandom generator, a function returning [0, 1), or nil for math.random
---@return any  the chosen value, or nil when no weight is positive
---@return integer|nil  its position in the (sorted) entry list
function M.weightedPick(entries, rng)
    if type(entries) ~= 'table' then
        error(('mathx.weightedPick: entries must be a table, got %s'):format(type(entries)), 2)
    end
    local values, weights, n = {}, {}, 0
    if entries[1] ~= nil then
        for i = 1, #entries do
            local e = entries[i]
            if type(e) == 'table' then
                n = n + 1
                values[n], weights[n] = e[1], e[2]
            end
        end
    else
        local keys = {}
        for k in pairs(entries) do keys[#keys + 1] = k end
        table.sort(keys, function(x, y)
            local tx, ty = type(x), type(y)
            if tx ~= ty then return tx < ty end
            if tx == 'number' or tx == 'string' then return x < y end
            return tostring(x) < tostring(y)
        end)
        for i = 1, #keys do
            n = n + 1
            values[n], weights[n] = keys[i], entries[keys[i]]
        end
    end
    local total = 0
    for i = 1, n do
        local w = weights[i]
        if isNumber(w) and w > 0 and w ~= math.huge then total = total + w end
    end
    if total <= 0 then
        return nil, nil
    end
    local target = draw01(rng) * total
    local acc, last = 0, nil
    for i = 1, n do
        local w = weights[i]
        if isNumber(w) and w > 0 and w ~= math.huge then
            acc = acc + w
            last = i
            if target < acc then return values[i], i end
        end
    end
    -- Rounding can leave target a hair past the final sum.
    return values[last], last
end

-- A MODULE, NOT A GLOBAL.
if ... ~= 'cis_require' then
    CisMathX = M
end

return M
