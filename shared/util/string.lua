-- String helpers: case conversion, splitting, truncation, fuzzy matching.

local M = {}

-- Feature-detected rather than assumed.
local HAS_UTF8 = type(utf8) == 'table' and type(utf8.offset) == 'function'

local function isUpper(b)
    return b >= 65 and b <= 90
end

local function isLower(b)
    return b >= 97 and b <= 122
end

local function isDigit(b)
    return b >= 48 and b <= 57
end

-- Everything else -- accented bytes, Cyrillic, emoji -- is a word character as far as
local function isWordByte(b)
    return isUpper(b) or isLower(b) or isDigit(b) or b >= 128
end

local function isSpaceByte(b)
    return b == 32 or (b >= 9 and b <= 13)
end

--- Break a string into words, in the sense the case converters mean.
---@param s string
---@return string[]  a dense array of words; {} for a non-string or an empty one
function M.words(s)
    if type(s) ~= 'string' or s == '' then
        return {}
    end
    local out = {}
    local n = #s
    local i = 1
    local start = 1
    while i <= n do
        local b = s:byte(i)
        if not isWordByte(b) then
            -- separator run
            if i > start then
                out[#out + 1] = s:sub(start, i - 1)
            end
            start = i + 1
            i = i + 1
        elseif isUpper(b) and i > start then
            -- The acronym rule, in full: an upper at i begins a new word when (a) the
            local prev = s:byte(i - 1)
            local nextIsLower = false
            local nb = s:byte(i + 1)
            if nb ~= nil then
                nextIsLower = isLower(nb)
            end
            -- `not isUpper(prev)` rather than `isLower(prev) or isDigit(prev)`: a byte
            if not isUpper(prev) or (isUpper(prev) and nextIsLower) then
                out[#out + 1] = s:sub(start, i - 1)
                start = i
            end
            i = i + 1
        else
            i = i + 1
        end
    end
    if start <= n then
        out[#out + 1] = s:sub(start, n)
    end
    return out
end

-- Recase one word. The TAIL is lowercased as well as the head being uppercased: without
local function lowerFirst(w)
    return w:sub(1, 1):lower() .. w:sub(2):lower()
end

local function upperFirst(w)
    return w:sub(1, 1):upper() .. w:sub(2):lower()
end

local function joinCased(words, firstUpper, restUpper)
    local out = {}
    for i = 1, #words do
        local w = words[i]
        if i == 1 then
            out[i] = firstUpper and upperFirst(w) or lowerFirst(w)
        else
            out[i] = restUpper and upperFirst(w) or lowerFirst(w)
        end
    end
    return table.concat(out)
end

--- 'give_money' -> 'giveMoney'.
---@param s string
---@return string  '' in, '' out
function M.camel(s)
    local words = M.words(s)
    if #words == 0 then
        return ''
    end
    return joinCased(words, false, true)
end

--- 'give_money' -> 'GiveMoney'.
---@param s string
---@return string  same input contract as camel
function M.pascal(s)
    local words = M.words(s)
    if #words == 0 then
        return ''
    end
    return joinCased(words, true, true)
end

--- 'GiveMoney' -> 'give_money'.
---@param s string
---@return string  '' for a non-string input
function M.snake(s)
    local words = M.words(s)
    local parts = {}
    for i = 1, #words do
        parts[i] = words[i]:lower()
    end
    return table.concat(parts, '_')
end

--- 'GiveMoney' -> 'give-money'.
---@param s string
---@return string  same rules as snake, different joiner
function M.kebab(s)
    local words = M.words(s)
    local parts = {}
    for i = 1, #words do
        parts[i] = words[i]:lower()
    end
    return table.concat(parts, '-')
end

--- Split on a separator. This is the version with the edge cases the usual one gets
---@param s string
---@param sep string
---@param opts? table  { keepEmpty, maxsplit }
---@return string[]|nil
---@return string|nil  why, for a bad separator or maxsplit
function M.split(s, sep, opts)
    if type(s) ~= 'string' or s == '' then
        return {}
    end
    if type(sep) ~= 'string' or sep == '' then
        return nil, 'separator must be a non-empty string'
    end
    opts = opts or {}
    local keepEmpty = opts.keepEmpty ~= false
    local maxsplit = opts.maxsplit
    if maxsplit ~= nil and (type(maxsplit) ~= 'number' or maxsplit < 0 or maxsplit % 1 ~= 0) then
        return nil, 'maxsplit must be a non-negative whole number'
    end

    -- A plain search, not a pattern: a separator of '.' or '%' or '-' has to match
    local out = {}
    local init = 1
    local splits = 0
    local function push(piece)
        if piece ~= '' or keepEmpty then
            out[#out + 1] = piece
        end
    end
    while true do
        if maxsplit and splits >= maxsplit then
            break
        end
        local a, b = s:find(sep, init, true)
        if not a then
            break
        end
        push(s:sub(init, a - 1))
        init = b + 1
        splits = splits + 1
    end
    if init <= #s then
        push(s:sub(init))
    elseif s:sub(-#sep) == sep and keepEmpty then
        -- Trailing separator: 'a,b,' leaves init one past the end and the body above
        push('')
    end
    return out
end

--- Cut to a maximum length, adding an ellipsis when it actually cut.
---@param s string
---@param max number  in CHARACTERS (bytes for invalid UTF-8); floored
---@param ellipsis? string|false  default "..."
---@return string  "" for a non-string
function M.truncate(s, max, ellipsis)
    if type(s) ~= 'string' then
        return ''
    end
    if type(max) ~= 'number' or max ~= max or max < 0 then
        return s
    end
    -- A whole number of characters. utf8.offset raises on a fractional index
    -- ("number has no integer representation"), so 2.5 used to be a crash.
    max = math.floor(max)
    if ellipsis == nil then
        ellipsis = '...'
    elseif ellipsis == false or ellipsis == '' then
        ellipsis = ''
    end
    -- Characters when the text is valid UTF-8, bytes when it is not. utf8.len
    -- answers (count) for valid text and (nil, position) for invalid text; the
    -- old code took the SECOND value, which is nil on valid text, so every
    -- string was measured in bytes and "é" counted twice.
    local function length(str)
        if HAS_UTF8 then
            local count = utf8.len(str)
            if count then
                return count, true
            end
        end
        return #str, false
    end
    -- The first `n` characters of `str`.
    local function prefix(str, n, chars)
        if n <= 0 then
            return ''
        end
        if chars then
            local cut = utf8.offset(str, n + 1)
            return cut and str:sub(1, cut - 1) or str
        end
        return str:sub(1, n)
    end
    local len, chars = length(s)
    if len <= max then
        return s
    end
    if ellipsis == '' then
        return prefix(s, max, chars)
    end
    local ellipsisLen, ellipsisChars = length(ellipsis)
    local keep = max - ellipsisLen
    if keep <= 0 then
        return prefix(ellipsis, max, ellipsisChars)
    end
    return prefix(s, keep, chars) .. ellipsis
end

--- Whether this runtime has the utf8 library.
---@return boolean  true when this runtime has the utf8 library
function M.hasUtf8()
    return HAS_UTF8
end

--- Collapse every run of whitespace to one space and trim both ends.
---@param s string
---@return string  every whitespace run collapsed to one space, both ends trimmed
function M.collapse(s)
    if type(s) ~= 'string' then
        return ''
    end
    local out = {}
    local n = 0
    local pending = false
    local started = false
    for i = 1, #s do
        local b = s:byte(i)
        if isSpaceByte(b) then
            -- Only emit the separator once we know a non-space follows, which is what
            pending = started
        else
            if pending then
                n = n + 1
                out[n] = ' '
                pending = false
            end
            n = n + 1
            out[n] = s:sub(i, i)
            started = true
        end
    end
    return table.concat(out)
end

--- Case-insensitive-ish containment test, matching the needle LITERALLY.
---@param s string
---@param needle string
---@param ignoreCase? boolean
---@return boolean  never raises
function M.contains(s, needle, ignoreCase)
    if type(s) ~= 'string' or type(needle) ~= 'string' then
        return false
    end
    if needle == '' then
        return true
    end
    if ignoreCase then
        return s:lower():find(needle:lower(), 1, true) ~= nil
    end
    return s:find(needle, 1, true) ~= nil
end

---@param s string
---@param prefix string
---@param ignoreCase? boolean
---@return boolean  false for a non-string, and true for an empty prefix
function M.startsWith(s, prefix, ignoreCase)
    if type(s) ~= 'string' or type(prefix) ~= 'string' then
        return false
    end
    if prefix == '' then
        return true
    end
    if ignoreCase then
        return s:lower():sub(1, #prefix) == prefix:lower()
    end
    return s:sub(1, #prefix) == prefix
end

---@param s string
---@param suffix string
---@param ignoreCase? boolean
---@return boolean  false for a non-string, and true for an empty suffix
function M.endsWith(s, suffix, ignoreCase)
    if type(s) ~= 'string' or type(suffix) ~= 'string' then
        return false
    end
    if suffix == '' then
        return true
    end
    if ignoreCase then
        return s:lower():sub(-#suffix) == suffix:lower()
    end
    return s:sub(-#suffix) == suffix
end

--- Pad on the left to `width`. Text longer than `width` is returned unchanged --
---@param s any
---@param width integer  a fraction is floored; a missing, NaN or infinite width pads nothing
---@param fill? string
---@return string  padded on the left to a BYTE width; unchanged when already long enough
function M.padStart(s, width, fill)
    s = type(s) == 'string' and s or tostring(s)
    fill = (type(fill) == 'string' and fill ~= '') and fill or ' '
    if type(width) ~= 'number' or width ~= width or width == math.huge then
        return s
    end
    width = math.floor(width)
    if #s >= width then
        return s
    end
    local need = width - #s
    return fill:rep(math.ceil(need / #fill)):sub(1, need) .. s
end

--- Pad on the right to `width`.
---@param s any
---@param width integer  a fraction is floored; a missing, NaN or infinite width pads nothing
---@param fill? string
---@return string  padded on the right to a BYTE width
function M.padEnd(s, width, fill)
    s = type(s) == 'string' and s or tostring(s)
    fill = (type(fill) == 'string' and fill ~= '') and fill or ' '
    if type(width) ~= 'number' or width ~= width or width == math.huge then
        return s
    end
    width = math.floor(width)
    if #s >= width then
        return s
    end
    local need = width - #s
    return s .. fill:rep(math.ceil(need / #fill)):sub(1, need)
end

--- Levenshtein edit distance between two strings.
---@param a string
---@param b string
---@param maxDistance? integer  0 or more; a fraction counts as its floor, math.huge as none
---@return integer|nil  the distance; maxDistance + 1 once it is exceeded
---@return string|nil  why
function M.levenshtein(a, b, maxDistance)
    if type(a) ~= 'string' or type(b) ~= 'string' then
        return nil, 'both arguments must be strings'
    end
    local la, lb = #a, #b
    -- A negative or NaN ceiling used to answer a "distance" of cap + 1 (0 for -1).
    if maxDistance ~= nil and (type(maxDistance) ~= 'number' or not (maxDistance >= 0)) then
        return nil, ('maxDistance must be a number 0 or more, got %s'):format(tostring(maxDistance))
    end
    local cap = math.max(la, lb)
    if maxDistance ~= nil and maxDistance < cap then
        cap = math.floor(maxDistance)
    end
    if la == 0 then
        return lb > cap and cap + 1 or lb
    end
    if lb == 0 then
        return la > cap and cap + 1 or la
    end
    if a == b then
        return 0
    end
    -- The shorter string drives the row width so the table is min(la, lb)+1.
    if math.abs(la - lb) > cap then
        return cap + 1
    end
    -- Only cells within `cap` of the diagonal can stay at or under the ceiling
    -- (Ukkonen's band): a cell outside it reads as cap + 1, so a ceiling walks
    -- (2 * cap + 1) cells a row instead of the whole table.
    local over = cap + 1
    local prev = {}
    local cur = {}
    for j = 0, math.min(lb, cap) do
        prev[j] = j
    end
    if cap < lb then
        prev[cap + 1] = over
    end
    for i = 1, la do
        local lo = i - cap
        if lo < 1 then lo = 1 end
        local hi = i + cap
        if hi > lb then hi = lb end
        if lo == 1 then
            cur[0] = i <= cap and i or over
        else
            cur[lo - 1] = over
        end
        local best = over
        if lo == 1 and cur[0] < best then best = cur[0] end
        local ca = a:byte(i)
        for j = lo, hi do
            local cost = 0
            if ca ~= b:byte(j) then
                cost = 1
            end
            local d = prev[j - 1] + cost
            local del = prev[j] + 1
            if del < d then d = del end
            local ins = cur[j - 1] + 1
            if ins < d then d = ins end
            if d > over then d = over end
            cur[j] = d
            if d < best then best = d end
        end
        if hi < lb then
            cur[hi + 1] = over
        end
        if best > cap then
            -- Every cell in this row is already past the ceiling: no later row can come
            return cap + 1
        end
        prev, cur = cur, prev
    end
    -- No row went past the ceiling, but the last cell can still sit above it.
    return prev[lb] > cap and cap + 1 or prev[lb]
end

--- Pick the closest candidate to `word`.
---@param word string
---@param candidates string[]
---@param opts? table  { maxDistance, comparator }
---@return string|nil  the closest candidate
---@return integer|string|nil  its distance, or why
function M.suggest(word, candidates, opts)
    if type(word) ~= 'string' or word == '' then
        return nil, 'word must be a non-empty string'
    end
    if type(candidates) ~= 'table' then
        return nil, ('candidates must be a table, got %s'):format(type(candidates))
    end
    opts = opts or {}
    local maxDistance = opts.maxDistance
    if maxDistance == nil then
        maxDistance = math.floor(#word / 2) + 1
    elseif type(maxDistance) ~= 'number' or not (maxDistance >= 0) then
        -- A negative one raised a compare error on the nil levenshtein answer.
        return nil, ('opts.maxDistance must be a number 0 or more, got %s'):format(tostring(maxDistance))
    end
    local comparator = opts.comparator
    local lower = word:lower()
    local best, bestScore, bestExact
    for i = 1, #candidates do
        local c = candidates[i]
        if type(c) == 'string' then
            local score = M.levenshtein(lower, c:lower(), maxDistance)
            if score <= maxDistance then
                -- An exact case-insensitive hit is unbeatable; stop here rather than
                if lower == c:lower() then
                    if not bestExact then
                        best, bestScore, bestExact = c, 0, true
                    end
                elseif not bestExact then
                    local better
                    if best == nil then
                        better = true
                    elseif comparator then
                        better = comparator(score, bestScore) < 0
                    else
                        better = score < bestScore
                    end
                    if better then
                        best, bestScore = c, score
                    end
                end
            end
        end
    end
    if not best then
        return nil
    end
    -- The distance it was judged on: the real-casing one can exceed maxDistance.
    return best, bestScore
end

local RANDOM_CLASSES = {
    ['1'] = '0123456789',
    ['A'] = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ',
    ['a'] = 'abcdefghijklmnopqrstuvwxyz',
    ['.'] = '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz',
}

-- An index in [1, n] from math.random, a CisRandom generator or a function returning [0, 1).
local function randomIndex(n, rng)
    if rng == nil then
        return math.random(n)
    end
    if type(rng) == 'table' and type(rng.int) == 'function' then
        return rng:int(1, n)
    end
    local v = rng()
    if type(v) ~= 'number' or v ~= v or v < 0 then v = 0 end
    local i = math.floor(v * n) + 1
    if i > n then i = n end
    return i
end

--- A random string shaped by a pattern, like ox_lib's string.random: '1' a digit, 'A' an upper-case letter, 'a' a lower-case letter, '.' a letter or digit, '^' makes the next character literal, anything else is itself.
---@param pattern string  e.g. '1AA111' for a plate, 'AAA-^1^1' for 'XQZ-11'
---@param rng? table|fun(): number  a CisRandom generator, a function returning [0, 1), or nil for math.random
---@return string|nil
---@return string|nil  why, for a non-string pattern or an rng of the wrong type
function M.random(pattern, rng)
    if type(pattern) ~= 'string' then
        return nil, ('pattern must be a string, got %s'):format(type(pattern))
    end
    if rng ~= nil and type(rng) ~= 'function'
        and not (type(rng) == 'table' and type(rng.int) == 'function') then
        return nil, ('rng must be a CisRandom generator, a function or nil, got %s'):format(type(rng))
    end
    local out, k = {}, 0
    local i, n = 1, #pattern
    while i <= n do
        local c = pattern:sub(i, i)
        if c == '^' and i < n then
            i = i + 1
            c = pattern:sub(i, i)
        else
            local class = RANDOM_CLASSES[c]
            if class then
                local j = randomIndex(#class, rng)
                c = class:sub(j, j)
            end
        end
        k = k + 1
        out[k] = c
        i = i + 1
    end
    return table.concat(out)
end

-- A MODULE, NOT A GLOBAL.
if ... ~= 'cis_require' then
    CisString = M
end

return M
