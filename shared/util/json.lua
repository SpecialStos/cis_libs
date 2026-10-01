-- A refusal-returning wrapper around whatever JSON codec the runtime has.
--
-- PURE, no natives, no module state, no dependencies. Safe to `shared_script`
-- for a private copy (COMPATIBILITY.md §10.2).
--
-- READ THIS BEFORE ASKING WHY THERE IS NO ENCODER HERE
--
-- FiveM ships `json.encode` and `json.decode`, and this repository already uses
-- them directly -- server/discord.lua builds webhook bodies, server/doorlock.lua
-- stores each door as one JSON blob. That is the encoder, and it is a good one.
-- Writing a second one would mean two JSON implementations in one resource
-- that could disagree about number formatting, about how a NaN is spelled, and
-- about what a non-finite float does to the writer -- with the door table going
-- through one and the Discord body through the other, forever.
--
-- So this file has NO parser and NO serializer. What it has is the part that
-- was actually missing, which is the failure behaviour:
--
--   * the codec is INJECTED, not looked up. FiveM's `json` is a global that
--     only exists inside the engine, so a global lookup would make this file
--     untestable under fengari. Handing it in also means it works with any
--     compatible codec, and a test can hand it a deliberately hostile one.
--   * every failure comes back as `nil, reason` instead of a raise. That is the
--     library's refusal convention (DOCUMENTATION.md §0.6) and it is what
--     server/doorlock.lua had to hand-roll as a bare pcall.
--   * the inputs a codec cannot survive -- a cycle, an unsupported type, an
--     absurd nesting depth -- are REFUSED BEFORE the codec sees them, with a
--     reason that names the key path. FiveM's decoder raises "table index is
--     nil"-class errors from the inside of C with no indication of which of
--     the 12,000 door rows had the problem.
--
-- Every function takes the codec as its first argument for the same reason the
-- clock is injected in time.lua: no global lookups, so everything here runs
-- under fengari with a fake codec and every failure path is reachable in a
-- test.

CisJson = {
    -- Nesting ceiling applied before the codec runs. 64 is far beyond any
    -- legitimate config or record and low enough that a hostile 10MB payload
    -- cannot spend the C stack.
    MAX_DEPTH = 64,
    -- Longest input decode() will even look at. A door record is a few hundred
    -- bytes; anything past this is not a record.
    MAX_INPUT = 4 * 1024 * 1024,
}

--- Check that a value is shaped like a usable codec.
---
---@param codec
--- @return the codec, or `nil, reason` naming what is missing.
function CisJson.check(codec)
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
---
---@param codec
--- @return a table of the same three functions with the codec captured, or
---   `nil, reason` from check().
function CisJson.bind(codec)
    local ok, why = CisJson.check(codec)
    if not ok then
        return nil, why
    end
    local bound = {}
    function bound.encode(value, opts)
        return CisJson.encode(ok, value, opts)
    end
    function bound.decode(text, opts)
        return CisJson.decode(ok, text, opts)
    end
    function bound.tryDecode(text, opts)
        return CisJson.tryDecode(ok, text, opts)
    end
    return bound
end

--- Walk a value and collect everything a JSON encoder cannot represent.
---
--- Returns `nil` when the value is encodable, or `false, reason, path` for the
--- FIRST problem. Depth is checked on the way down, so the walk terminates even
--- on a structure with no cycle in it at all but a hundred levels of nesting.
---
--- A function, thread or userdata is refused rather than skipped. Skipping is
--- the worse answer: the caller asked to store a record, half of it disappears,
--- and the record that comes back is missing the field that mattered. A refusal
--- is visible at the call that caused it.
---
--- Kept as its own pass rather than folded into encode() so that the check is
--- available on its own -- it is the answer to "why did my door row not save",
--- and it works with no codec at all.
function CisJson.checkEncodable(value, opts)
    opts = opts or {}
    local maxDepth = opts.maxDepth or CisJson.MAX_DEPTH
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
                -- The key must be encodable too: a table keyed by a function is
                -- a real shape in Lua and becomes "{}" in JSON.
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
            -- NaN and the infinities have no JSON spelling. Every encoder
            -- handles them differently -- some emit null, some emit garbage,
            -- some raise -- so they are refused here where the answer is
            -- consistent.
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
---
--- The order of operations is the whole design: check the value first, so the
--- reason names the key path, and only then hand it to the codec inside a pcall
--- so a codec that raises for a reason nobody anticipated still comes back as
--- a reason instead of unwinding the caller's frame. A raise from a JSON codec
--- inside a FiveM event handler is a stack trace in the console that names no
--- config and no caller.
---
--- @param codec table  a table with encode and decode (FiveM's `json`).
--- @param value any   the value to encode.
--- @param opts table|nil
---   opts.maxDepth  override CisJson.MAX_DEPTH.
--- @return the encoded string, or `nil, reason`.
function CisJson.encode(codec, value, opts)
    local ok, why = CisJson.check(codec)
    if not ok then
        return nil, why
    end
    local good, problem = CisJson.checkEncodable(value, opts)
    if not good then
        return nil, problem
    end
    local encoded, err = pcall(codec.encode, value)
    if not encoded then
        return nil, ('the encoder raised: %s'):format(tostring(err))
    end
    local result = err
    if type(result) ~= 'string' then
        -- A codec that returns true/nil instead of raising is still wrong, and
        -- handing nil to a SQL column is worse than refusing here.
        return nil, ('the encoder returned %s, not a string'):format(type(result))
    end
    return result
end

--- Measure nesting depth in JSON TEXT without parsing it.
---
--- Bracket and brace depth only, tracked outside string literals and honouring
--- backslash escapes. It is not a validator -- it cannot tell `{"a":}` from
--- `{"a":1}` -- and it is not trying to. Its only job is to reject a payload
--- that nests deeper than the codec could survive BEFORE the codec walks it, so
--- the refusal names a depth instead of arriving as a stack overflow.
---
--- It also stops at the first closing bracket that takes the depth below zero,
--- which is what makes `]]]]]]` cheap to reject rather than O(n) with a stack.
---
---@param text
--- @return the maximum depth seen, or `nil, reason`.
function CisJson.scanDepth(text)
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
---
--- opts.maxDepth   override CisJson.MAX_DEPTH for the pre-scan.
--- opts.maxInput   override CisJson.MAX_INPUT, in bytes.
--- opts.allowEmpty accept '' as a successful nil. Off by default: an empty
---                  body is a missing body, and the refusal is the only thing
---                  that distinguishes the two.
---
--- THE THREE-WAY RETURN, which is the one subtle thing here:
---
---     local value, why = CisJson.decode(codec, text)
---     if why then -- refused; why says why
---     end         -- otherwise it succeeded, and `value` is nil only for `null`
---
--- A text of `null` decodes to nil WITHOUT a reason: that is a successful
--- decode of a legitimate JSON value, and refusing it would make a nullable
--- column look like a corrupt row. Testing `if not value` therefore cannot
--- distinguish the two, which is why tryDecode() exists below.
---
---@param codec
---@param text
---@param opts
--- @return the decoded value on success (nil, with no reason, for `null`), or
---   `nil, reason` on refusal.
function CisJson.decode(codec, text, opts)
    local ok, why = CisJson.check(codec)
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
    local maxInput = opts.maxInput or CisJson.MAX_INPUT
    if #text > maxInput then
        return nil, ('text is %d bytes, over the %d limit'):format(#text, maxInput)
    end
    local depth, scanErr = CisJson.scanDepth(text)
    if not depth then
        return nil, scanErr
    end
    local maxDepth = opts.maxDepth or CisJson.MAX_DEPTH
    if depth > maxDepth then
        return nil, ('text nests %d deep, over the %d limit'):format(depth, maxDepth)
    end
    local decoded, value = pcall(codec.decode, text)
    if not decoded then
        return nil, ('the decoder raised: %s'):format(tostring(value))
    end
    -- value == nil here means the codec succeeded and produced JSON null. No
    -- reason is attached, which is what makes the caller's `if why` test work.
    return value
end

--- Decode, returning a boolean, for callers that cannot use the three-way form.
---
---@param codec
---@param text
---@param opts
--- @return `true, value` on success -- value may be nil, for `null` -- or
---   `false, reason` on refusal.
function CisJson.tryDecode(codec, text, opts)
    local value, why = CisJson.decode(codec, text, opts)
    if why then
        return false, why
    end
    return true, value
end

--- Encode and decode back, and return the value that survived.
---
--- This is the round-trip check, and it is here rather than in a test file
--- because the useful version is a RUNTIME one: a config that survives a
--- round trip through the codec is the only proof that a value written to a
--- database and read back a week later is the value that went in. Deep copy
--- semantics mean the returned value shares nothing with the input.
---
---@param codec
---@param value
---@param opts
--- @return the decoded value, or `nil, reason` -- from either direction.
function CisJson.roundTrip(codec, value, opts)
    local text, why = CisJson.encode(codec, value, opts)
    if text == nil then
        return nil, why
    end
    return CisJson.decode(codec, text, opts)
end
