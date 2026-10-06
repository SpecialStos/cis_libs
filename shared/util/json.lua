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
function M.checkEncodable(value, opts)
    opts = opts or {}
    local maxDepth = opts.maxDepth or M.MAX_DEPTH
    local path = { '<root>' }
    local seen = {}
    local problem

    local function walk(v, depth)
        if problem then return end
        local t = type(v)
        if t == 'table' then
            if seen[v] then
                problem = ('cycle through %s'):format(table.concat(path, '.'))
                return
            end
            if depth > maxDepth then
                problem = ('nesting deeper than %d at %s'):format(maxDepth, table.concat(path, '.'))
                return
            end
            seen[v] = true
            for k, child in pairs(v) do
                -- The key must be encodable too: a table keyed by a function is a real
                local kt = type(k)
                if kt ~= 'string' and kt ~= 'number' then
                    problem = ('key of type %s at %s'):format(kt, table.concat(path, '.'))
                    return
                end
                path[#path + 1] = tostring(k)
                walk(child, depth + 1)
                path[#path] = nil
                if problem then return end
            end
            seen[v] = nil
        elseif t == 'function' or t == 'thread' or t == 'userdata' then
            problem = ('%s at %s cannot be represented in JSON'):format(t, table.concat(path, '.'))
        elseif t == 'number' then
            -- NaN and the infinities have no JSON spelling.
            if v ~= v or v == math.huge or v == -math.huge then
                problem = ('non-finite number at %s'):format(table.concat(path, '.'))
            end
        end
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
    local encoded, err = pcall(codec.encode, value)
    if not encoded then
        return nil, ('the encoder raised: %s'):format(tostring(err))
    end
    local result = err
    if type(result) ~= 'string' then
        -- A codec that returns true/nil instead of raising is still wrong, and handing
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
        return nil, ('text is %d bytes, over the %d limit'):format(#text, maxInput)
    end
    local depth, scanErr = M.scanDepth(text)
    if not depth then
        return nil, scanErr
    end
    local maxDepth = opts.maxDepth or M.MAX_DEPTH
    if depth > maxDepth then
        return nil, ('text nests %d deep, over the %d limit'):format(depth, maxDepth)
    end
    local decoded, value = pcall(codec.decode, text)
    if not decoded then
        return nil, ('the decoder raised: %s'):format(tostring(value))
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
