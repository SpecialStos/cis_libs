-- Short collision-resistant ids and name normalisation, from an injectable RNG.
--
-- PURE, no natives, no module state, no dependencies. Safe to `shared_script`
-- for a private copy (COMPATIBILITY.md §10.2).
--
-- ####################################################################
-- # THIS IS NOT A SECURITY TOKEN. READ THIS BEFORE USING IT FOR ONE. #
-- ####################################################################
--
-- math.random is a pseudorandom generator seeded from a clock and a small
-- internal state. Its output is PREDICTABLE: an attacker who can observe two or
-- three ids can recover the seed and enumerate every id the server will ever
-- hand out, past and future. FiveM exposes no CSPRNG to Lua at all, so there
-- is no version of this file that fixes that -- the generator is injected
-- precisely so that a caller who HAS a real one can pass it in, but the default
-- is not one.
--
-- So: these ids are for ENTITY KEYS. 'which door is this', 'which sync record
-- is this', 'which row in my own table'. Anything a client must not be able to
-- guess or forge -- a session token, a webhook signing key, an admin command
-- nonce -- needs a generator this library cannot provide, and putting a
-- predictable id in that slot is the kind of bug that ships.
--
-- EVERY RANDOM SOURCE IS INJECTED. `math.random` is the default and the only
-- reference to it in the file, taken as a value rather than called at each
-- site. Under a test, pass `function() return 0.42 end` and every id in this
-- file becomes a constant you can assert on. That is not a testing convenience
-- bolted on afterwards; an id generator whose output cannot be pinned down is
-- an id generator with no test for the one thing that matters, which is that two
-- calls do not collide.

CisId = {
    -- Crockford-style base32: the digits plus the consonants, with I, L, O and U
    -- removed. Those four are removed because they are confusable with 1, 1, 0
    -- and V, and an id that gets read off a screenshot or typed into a console
    -- is an id someone will mistype. 32 symbols means 5 bits per character.
    ALPHABET = '0123456789ABCDEFGHJKMNPQRSTVWXYZ',
    -- 8 characters of 5 bits is 40 bits. At a million ids the birthday
    -- probability of a single collision is about 0.5%, which is the right
    -- order of magnitude for an in-memory table that is swept when the resource
    -- stops. 12 characters (60 bits) is the default because ids are usually
    -- written into a database where the table never goes away.
    LENGTH = 12,
}

--- Draw `count` symbols from `alphabet`, using `rng`.
---
--- `alphabet` defaults to CisId.ALPHABET and `count` to CisId.LENGTH, so
--- `draw(rng)` is a complete call -- it does not silently require the caller to
--- repeat the two defaults that `short` would have supplied anyway.
---
--- THE BIAS QUESTION, answered honestly rather than with a rejection loop:
--- taking `floor(r * n)` over a float r in [0,1) is uniform for every practical
--- alphabet size. A double has a granularity of 2^-53, so the most over-served
--- symbol is ahead by at most n * 2^-53 -- about 4e-15 for this 32-symbol
--- alphabet. That is not worth a rejection branch, and a rejection loop written
--- to fix it would have nothing to reject: `r < 1` means the index is never n.
---
--- WHAT DOES bite is a QUANTISED rng. An injected `function() return
--- math.floor(x*16)/16 end` can only ever produce the first sixteen symbols of
--- a 32-symbol alphabet, and no amount of arithmetic here can repair that --
--- the generator has lost the entropy before this function sees it. Pass a
--- full-precision float.
---
--- Values OUTSIDE [0,1) are refused rather than clamped. A generator returning
--- 1.0 or a negative number is broken, and indexing an alphabet with 1.0 * 32
--- is a read one past the end -- which is nil, which makes the next line fail
--- with a message about string.sub and no mention of the rng.
---
--- @return a string, or `nil, reason`.
function CisId.draw(rng, count, alphabet)
    if type(rng) ~= 'function' then
        return nil, 'rng must be a function returning a number in [0,1)'
    end
    count = count or CisId.LENGTH
    if alphabet == nil then
        alphabet = CisId.ALPHABET
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
        local r = rng()
        if type(r) ~= 'number' or r ~= r then
            return nil, ('rng returned %s, not a number'):format(type(r))
        end
        if r < 0 or r >= 1 then
            return nil, ('rng returned %s, outside [0,1)'):format(tostring(r))
        end
        local index = math.floor(r * n)
        if index >= n then
            -- Unreachable given the range check above. Kept because this is
            -- the line that would be one Lua version change away from reading
            -- past the alphabet, and the guard costs one comparison.
            index = n - 1
        end
        out[i] = alphabet:sub(index + 1, index + 1)
        i = i + 1
    end
    return table.concat(out)
end

--- A short opaque id, optionally prefixed.
---
--- `prefix` is separated with an underscore and is NOT escaped: it is yours, and
--- it is meant to be readable in a log line ('door_7F2K9Q1M4XB3'). Keep it to
--- characters that survive a log, a console and a CSV.
---
--- @param opts table|nil
---   opts.length    characters of entropy (default CisId.LENGTH, 12)
---   opts.alphabet  the symbol set (default CisId.ALPHABET)
---   opts.rng       the generator (default math.random)
--- @return the id, or `nil, reason`. A prefix that is not a string, or an
---   rng that misbehaves, is a refusal and not a broken id.
function CisId.short(prefix, opts)
    opts = opts or {}
    local rng = opts.rng or math.random
    local body, why = CisId.draw(rng, opts.length or CisId.LENGTH, opts.alphabet or CisId.ALPHABET)
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
---
--- The version nibble (4) and the variant nibble (8/9/A/B) are FIXED, so the
--- output is a valid v4 shape no matter what the generator produced. That is
--- what the format is for: downstream code that validates the shape, and log
--- grep. It is not a UUID in the cryptographic sense, for the reason in the
--- header, and nothing should parse one back apart expecting randomness.
function CisId.uuid(rng)
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
            -- Variant: the top two bits are fixed at 10, so the nibble is one
            -- of 8, 9, a, b and never c-f.
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
---
--- The store is passed IN and returned, which is this library's rule for
--- anything with state (see shared/pending.lua and shared/histogram.lua): a
--- module that held its own counter would make two copies of this file disagree
--- about what id 41 is.
---
--- @return a fresh counter table: `{ seq = 0 }`.
function CisId.newCounter()
    return { seq = 0 }
end

--- Take the next value from a counter.
---
--- Monotonic and gapless. `kind` is prefixed, so a door and a vehicle in the
--- same counter cannot collide and a log line says which it is. This is the
--- shape server/sync.lua already uses internally for its own record ids -- kept
--- here as the public version rather than replaced, because that file's counter
--- is a module local on purpose and changing it is out of scope for a pure
--- utility file.
---
--- @return the id, or `nil, reason` when the counter is not a counter. There is
---   no rollback: a call that consumed a value and then refused has left a gap,
---   which is harmless and far better than reusing a value.
function CisId.next(counter, kind)
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
-- REPLACEMENT and confusing them raises at run time:
--   * in a PATTERN, every magic character needs a leading %.
--   * in a REPLACEMENT, only % is special -- and it must be written %%. A '%'
--     followed by anything else is "invalid use of '%' in replacement string".
-- So a separator of '.' is '%.' as a pattern but '.' as a replacement, while a
-- separator containing '%' is '%25' as a pattern and '%%' as a replacement.
local function escapePattern(s)
    return (s:gsub('([%^%$%(%)%%%.%[%]%*%+%-%?])', '%%%1'))
end

local function escapeReplacement(s)
    return (s:gsub('%%', '%%%%'))
end

--- Turn a display name into a key that is safe to use as a table key, a
--- database column value, or a filename.
---
--- The rules, in order: lowercase, every run of characters that is not a
--- letter, digit, dash or underscore collapsed to a single separator, leading
--- and trailing separators trimmed, and the result capped at `maxLength`.
---
--- ACCENTED LETTERS ARE NOT STRIPPED, because stripping them by hand is how
--- 'Zoë' becomes 'Zo' on one machine and 'zo' on another: byte 0xC3 is not in
--- [a-z], so it becomes a separator here. That is a real limitation and it is
--- stated rather than papered over, because the correct fix needs a Unicode
--- table this file does not carry. If your server has accented player names,
--- normalise them at the boundary where you still have the UTF-8 string and use
--- this only on the result.
---
--- The `used` set is how uniqueness is achieved WITHOUT module state: pass the
--- table you are about to insert into and a collision appends -2, -3, and so
--- on. Passing nil skips the uniqueness pass entirely, which is what you want
--- when the caller has already decided.
---
--- @param opts table|nil
---   opts.maxLength  default 32. Longer names are CUT, and a cut can collide,
---                   which the `used` pass then resolves.
---   opts.separator  default '_'. Any string; it is pattern-escaped internally.
--- @return the key, or `nil, reason` when `raw` is not a string or normalises
---   to nothing (which is a refusal, not an empty key: `''` and a name of
---   '!!!' would both index the same row).
function CisId.normaliseName(raw, used, opts)
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
    -- trailing one has to go or every name is '_name'.
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
