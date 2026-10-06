-- Short collision-resistant ids and name normalisation, from an injectable RNG.

local M = {
    -- Crockford-style base32: the digits plus the consonants, with I, L, O and U
    ALPHABET = '0123456789ABCDEFGHJKMNPQRSTVWXYZ',
    -- 8 characters of 5 bits is 40 bits.
    LENGTH = 12,
}

-- Is this argument an rng rather than a count or an alphabet?
--- Draw `count` symbols from `alphabet`, using `rng`.
local function isRng(value)
    if type(value) == 'function' then
        return true
    end
    return type(value) == 'table' and type(value.float) == 'function'
end

-- The generator argument into "call this with no arguments, get a float in [0, 1)".
local function normaliseRng(value)
    if value == nil then
        return math.random
    end
    if type(value) == 'function' then
        return value
    end
    if type(value) == 'table' and type(value.float) == 'function' then
        return function() return value:float() end
    end
    return nil
end

--- @param count number|nil     how many symbols; default CisId.LENGTH
--- @param alphabet string|nil  default CisId.ALPHABET
--- @param rng function|table|nil  a function returning [0,1), or an object
--- @return a string, or `nil, reason`.
function M.draw(count, alphabet, rng)
    -- The original form was draw(rng, count, alphabet), and a consumer written against
    if isRng(count) then
        rng, count, alphabet = count, alphabet, rng
    end
    local draw01 = normaliseRng(rng)
    if not draw01 then
        return nil, ('rng must be a function returning a number in [0,1), '
            .. 'or a CisRandom.newGenerator object, got %s'):format(type(rng))
    end
    count = count or M.LENGTH
    if alphabet == nil then
        alphabet = M.ALPHABET
    end
    if type(alphabet) ~= 'string' or alphabet == '' then
        return nil, 'alphabet must be a non-empty string'
    end
    if type(count) ~= 'number' or count < 1 then
        return nil, 'count must be a positive number'
    end
    local n = #alphabet
    local out = {}
    local i = 1
    while i <= count do
        local r = draw01()
        if type(r) ~= 'number' or r ~= r then
            return nil, ('rng returned %s, not a number'):format(type(r))
        end
        if r < 0 or r >= 1 then
            return nil, ('rng returned %s, outside [0,1)'):format(tostring(r))
        end
        local index = math.floor(r * n)
        if index >= n then
            -- Unreachable given the range check above.
            index = n - 1
        end
        out[i] = alphabet:sub(index + 1, index + 1)
        i = i + 1
    end
    return table.concat(out)
end

--- A short opaque id, optionally prefixed.
--- @param opts table|nil
--- @param prefix
--- @return the id, or `nil, reason`. A prefix that is not a string, or an
function M.short(prefix, opts)
    opts = opts or {}
    -- The rng goes LAST, and no longer needs a closure wrapped round it: draw accepts a
    local body, why = M.draw(opts.length or M.LENGTH,
        opts.alphabet or M.ALPHABET, opts.rng)
    if not body then
        return nil, why
    end
    if prefix == nil or prefix == '' then
        return body
    end
    if type(prefix) ~= 'string' then
        return nil, ('prefix must be a string, got %s'):format(type(prefix))
    end
    return prefix .. '_' .. body
end

--- An RFC 4122 version 4 shaped string, from the same injected generator.
--- @param rng
--- @return string|nil,string  an RFC 4122 version-4 shaped string, or nil and a reason if the rng misbehaves. Not a UUID in the cryptographic sense -- see the header.
function M.uuid(rng)
    rng = rng or math.random
    local hex = '0123456789abcdef'
    local out = {}
    local i = 1
    while i <= 32 do
        local r = rng()
        if type(r) ~= 'number' or r ~= r or r < 0 or r >= 1 then
            return nil, 'rng must return a number in [0,1)'
        end
        if i == 13 then
            -- Version: fixed at 4, per RFC 4122.
            out[i] = '4'
        elseif i == 17 then
            -- Variant: the top two bits are fixed at 10, so the nibble is one of 8, 9,
            local v = math.floor(r * 4) + 9
            out[i] = hex:sub(v, v)
        else
            local v = math.floor(r * 16) + 1
            out[i] = hex:sub(v, v)
        end
        i = i + 1
    end
    local s = table.concat(out)
    return ('%s-%s-%s-%s-%s'):format(
        s:sub(1, 8), s:sub(9, 12), s:sub(13, 16), s:sub(17, 20), s:sub(21, 32))
end

--- A counter, for ids that must be readable and ordered.
--- @return a fresh counter table: `{ seq = 0 }`.
--- @return table  a counter handle; feed it to CisId.next
function M.newCounter()
    return { seq = 0 }
end

--- Take the next value from a counter.
--- @param counter
--- @param kind
--- @return the id, or `nil, reason` when the counter is not a counter. There is
function M.next(counter, kind)
    if type(counter) ~= 'table' then
        return nil, ('counter must be a table from CisId.newCounter(), got %s'):format(type(counter))
    end
    if type(counter.seq) ~= 'number' then
        return nil, 'counter.seq is not a number; this is not a counter'
    end
    counter.seq = counter.seq + 1
    if kind == nil or kind == '' then
        return tostring(counter.seq)
    end
    if type(kind) ~= 'string' then
        return nil, ('kind must be a string, got %s'):format(type(kind))
    end
    return ('%s_%d'):format(kind, counter.seq)
end

-- Two escapes, because Lua uses different rules for a pattern and for a gsub
local function escapePattern(s)
    return (s:gsub('([%^%$%(%)%%%.%[%]%*%+%-%?])', '%%%1'))
end

local function escapeReplacement(s)
    return (s:gsub('%%', '%%%%'))
end

--- Turn a display name into a key that is safe to use as a table key, a database column
--- @param opts table|nil
--- @param raw
--- @param used
--- @return the key, or `nil, reason` when `raw` is not a string or normalises
function M.normaliseName(raw, used, opts)
    if type(raw) ~= 'string' then
        return nil, ('name must be a string, got %s'):format(type(raw))
    end
    opts = opts or {}
    local separator = opts.separator or '_'
    if type(separator) ~= 'string' or separator == '' then
        return nil, 'separator must be a non-empty string'
    end
    local maxLength = opts.maxLength or 32
    local pattern = escapePattern(separator)
    local replacement = escapeReplacement(separator)
    local lowered = raw:lower()
    local cleaned = lowered:gsub('[^%w_]+', replacement)
    -- A run that ENDS at a separator already collapsed to one, but a leading or
    cleaned = cleaned:gsub('^' .. pattern .. '+', ''):gsub(pattern .. '+$', '')
    if #cleaned > maxLength then
        cleaned = cleaned:sub(1, maxLength):gsub(pattern .. '+$', '')
    end
    if cleaned == '' then
        return nil, 'name normalises to an empty key'
    end
    if type(used) ~= 'table' then
        return cleaned
    end
    local candidate = cleaned
    local suffix = 2
    while used[candidate] do
        candidate = ('%s%s%d'):format(cleaned, separator, suffix)
        suffix = suffix + 1
    end
    return candidate
end

-- A MODULE, NOT A GLOBAL.
if ... ~= 'cis_require' then
    CisId = M
end

return M
