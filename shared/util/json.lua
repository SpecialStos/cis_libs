-- A refusal-returning wrapper around whatever JSON codec the runtime has.

local M = {
    -- Nesting ceiling applied before the codec runs.
    MAX_DEPTH = 64,
    -- Longest input decode() will even look at.
    MAX_INPUT = 4 * 1024 * 1024,
}

--- Check that a value is shaped like a usable codec.
--- @param codec
--- @return the codec, or `nil, reason` naming what is missing.
function M.check(codec)
    if type(codec) ~= 'table' and type(codec) ~= 'userdata' then
        return nil, ('codec must be a table (FiveM\'s `json`), got %s'):format(type(codec))
    end
    if type(codec.encode) ~= 'function' then
        return nil, 'codec has no encode function'
    end
    if type(codec.decode) ~= 'function' then
        return nil, 'codec has no decode function'
    end
    return codec
end

--- Bind the functions to one codec, so a hot path does not pass it every call.
--- @param codec
--- @return a table of the same three functions with the codec captured, or
function M.bind(codec)
    local ok, why = M.check(codec)
    if not ok then
        return nil, why
    end
    local bound = {}
    function bound.encode(value, opts)
        return M.encode(ok, value, opts)
    end
    function bound.decode(text, opts)
        return M.decode(ok, text, opts)
    end
    function bound.tryDecode(text, opts)
        return M.tryDecode(ok, text, opts)
    end
    return bound
end

--- Walk a value and collect everything a JSON encoder cannot represent.
--- @param value
--- @param opts
--- @return boolean,string|nil  true when the value encodes, or false and a PATH that names the offending key. A table keyed by a function is a real Lua shape and fails here.
-- The SHAPE rule for one table, which is where the portable subset of JSON
-- and the codecs FiveM servers run disagree most. A table encodes the same way
-- everywhere only when it is one of:
--
--   * empty;
--   * an ARRAY: every key a positive integer, exactly 1..n, no holes;
--   * an OBJECT: every key a string.
--
-- Anything else is answered differently by different codecs, or raises in
-- some of them: a mixed table ({1, 2, name = 'x'}) is an object with "1"
-- and "2" keys in one codec and an error in another; a sparse array is padded
-- with nulls, or refused as "excessively sparse"; a fractional key (1.5) has
-- no array position at all. Refusing them here is the point of asking first:
-- the caller learns the WHERE, by path, instead of a codec error or a payload
-- that decodes as something else.
local function shapeProblem(v)
    local count, strings, numbers = 0, 0, 0
    for k in next, v do
        count = count + 1
        local kt = type(k)
        if kt == 'string' then
            strings = strings + 1
        elseif kt == 'number' then
            if k ~= k or k == math.huge or k == -math.huge or k % 1 ~= 0 then
                return ('number key %s is not an integer, and has no array position')
                    :format(tostring(k))
            end
            if k < 1 then
                return ('number key %s is below 1, and has no array position'):format(tostring(k))
            end
            numbers = numbers + 1
        else
            return ('key of type %s'):format(kt)
        end
    end
    if strings > 0 and numbers > 0 then
        return ('mixed keys: %d string and %d number keys in one table'):format(strings, numbers)
    end
    if numbers > 0 then
        for i = 1, count do
            if rawget(v, i) == nil then
                return ('sparse array: %d number keys, but index %d is missing'):format(count, i)
            end
        end
    end
    return nil
end

function M.checkEncodable(value, opts)
    opts = opts or {}
    local maxDepth = opts.maxDepth or M.MAX_DEPTH
    local path = { '<root>' }
    -- Two different facts, kept apart. `onPath` is "an ancestor of where the
    -- walk is now", and meeting one again is a cycle. `height` is "already
    -- walked to completion", and meeting one again is just a table shared by
    -- two parents: legal, encoded twice, and NOT worth walking twice. One set
    -- doing both jobs (cleared on the way out, so it could detect cycles)
    -- walked a shared table once per route to it: 2^22 walks for a 22-level
    -- chain of {a = t, b = t}.
    local onPath = {}
    local height = {}
    local problem

    local function where()
        return table.concat(path, '.')
    end

    -- Answers the height of `v` below and including itself (0 for a scalar).
    local function walk(v, depth)
        local t = type(v)
        if t == 'table' then
            if onPath[v] then
                problem = ('cycle through %s'):format(where())
                return 0
            end
            local known = height[v]
            if known then
                -- Already checked from another parent. Its shape is fine; the
                -- only thing that can differ on this route is the depth.
                if depth + known - 1 > maxDepth then
                    problem = ('nesting deeper than %s at %s'):format(tostring(maxDepth), where())
                end
                return known
            end
            if depth > maxDepth then
                problem = ('nesting deeper than %s at %s'):format(tostring(maxDepth), where())
                return 0
            end
            local shape = shapeProblem(v)
            if shape then
                problem = ('%s at %s'):format(shape, where())
                return 0
            end
            onPath[v] = true
            local below = 0
            for k, child in pairs(v) do
                path[#path + 1] = tostring(k)
                local h = walk(child, depth + 1)
                path[#path] = nil
                if problem then return 0 end
                if h > below then below = h end
            end
            onPath[v] = nil
            height[v] = below + 1
            return below + 1
        elseif t == 'function' or t == 'thread' or t == 'userdata' then
            problem = ('%s at %s cannot be represented in JSON'):format(t, where())
        elseif t == 'number' then
            -- NaN and the infinities have no JSON spelling.
            if v ~= v or v == math.huge or v == -math.huge then
                problem = ('non-finite number at %s'):format(where())
            end
        end
        return 0
    end

    walk(value, 1)
    if problem then
        return false, problem
    end
    return true
end

--- Encode, refusing rather than raising.
--- @param codec table  a table with encode and decode (FiveM's `json`).
--- @param value any   the value to encode.
--- @param opts table|nil
--- @return the encoded string, or `nil, reason`.
function M.encode(codec, value, opts)
    local ok, why = M.check(codec)
    if not ok then
        return nil, why
    end
    local good, problem = M.checkEncodable(value, opts)
    if not good then
        return nil, problem
    end
    local encoded, result, encodeErr = pcall(codec.encode, value)
    if not encoded then
        return nil, ('the encoder raised: %s'):format(tostring(result))
    end
    if type(result) ~= 'string' then
        -- A codec that answers anything but a string has not encoded. One in the
        -- `nil, err` style is reported with ITS reason.
        if result == nil and encodeErr ~= nil then
            return nil, ('the encoder refused: %s'):format(tostring(encodeErr))
        end
        return nil, ('the encoder returned %s, not a string'):format(type(result))
    end
    return result
end

--- Measure nesting depth in JSON TEXT without parsing it.
--- @param text
--- @return the maximum depth seen, or `nil, reason`.
function M.scanDepth(text)
    if type(text) ~= 'string' then
        return nil, ('text must be a string, got %s'):format(type(text))
    end
    local depth = 0
    local peak = 0
    local inString = false
    local escaped = false
    for i = 1, #text do
        local b = text:byte(i)
        if inString then
            if escaped then
                escaped = false
            elseif b == 92 then -- backslash
                escaped = true
            elseif b == 34 then -- quote
                inString = false
            end
        elseif b == 34 then
            inString = true
        elseif b == 123 or b == 91 then -- { [
            depth = depth + 1
            if depth > peak then
                peak = depth
            end
        elseif b == 125 or b == 93 then -- } ]
            depth = depth - 1
            if depth < 0 then
                return nil, 'closing bracket with no matching opening bracket'
            end
        end
    end
    return peak
end

--- Decode, refusing rather than raising.
--- @param codec
--- @param text
--- @param opts
--- @return the decoded value on success (nil, with no reason, for `null`), or
function M.decode(codec, text, opts)
    local ok, why = M.check(codec)
    if not ok then
        return nil, why
    end
    if text == nil then
        return nil, 'nothing to decode'
    end
    if type(text) ~= 'string' then
        return nil, ('text must be a string, got %s'):format(type(text))
    end
    opts = opts or {}
    if text == '' then
        if opts.allowEmpty then
            return nil
        end
        return nil, 'text is empty'
    end
    local maxInput = opts.maxInput or M.MAX_INPUT
    if #text > maxInput then
        return nil, ('text is %d bytes, over the %s limit'):format(#text, tostring(maxInput))
    end
    local depth, scanErr = M.scanDepth(text)
    if not depth then
        return nil, scanErr
    end
    local maxDepth = opts.maxDepth or M.MAX_DEPTH
    if depth > maxDepth then
        return nil, ('text nests %d deep, over the %s limit'):format(depth, tostring(maxDepth))
    end
    local decoded, value, second, third = pcall(codec.decode, text)
    if not decoded then
        return nil, ('the decoder raised: %s'):format(tostring(value))
    end
    -- A codec may REFUSE without raising. The two conventions in use are
    -- `nil, err` (lua-cjson's safe mode and most wrappers) and dkjson's
    -- `nil, position, err`. Read as success, either one turned malformed input
    -- into a JSON null -- the one answer a caller cannot tell from real data.
    -- dkjson's SUCCESS on `null` is `nil, position` with no message, which is
    -- why a number in the second slot is not itself a refusal.
    if value == nil then
        local refusal = (type(second) == 'string' and second) or (type(third) == 'string' and third)
        if refusal then
            return nil, ('the decoder refused: %s'):format(refusal)
        end
    end
    -- value == nil here means the codec succeeded and produced JSON null.
    return value
end

--- Decode, returning a boolean, for callers that cannot use the three-way form.
--- @param codec
--- @param text
--- @param opts
--- @return `true, value` on success -- value may be nil, for `null` -- or
function M.tryDecode(codec, text, opts)
    local value, why = M.decode(codec, text, opts)
    if why then
        return false, why
    end
    return true, value
end

--- Encode and decode back, and return the value that survived.
--- @param codec
--- @param value
--- @param opts
--- @return the decoded value, or `nil, reason` -- from either direction.
function M.roundTrip(codec, value, opts)
    local text, why = M.encode(codec, value, opts)
    if text == nil then
        return nil, why
    end
    return M.decode(codec, text, opts)
end

-- A MODULE, NOT A GLOBAL.
if ... ~= 'cis_require' then
    CisJson = M
end

return M
