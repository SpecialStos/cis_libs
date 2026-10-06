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
--- @param s
--- @return table  a dense array of words; {} for a non-string or an empty one
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
--- @param s
--- @return string  '' in, '' out
function M.camel(s)
    local words = M.words(s)
    if #words == 0 then
        return ''
    end
    return joinCased(words, false, true)
end

--- 'give_money' -> 'GiveMoney'.
--- @param s
--- @return string  same input contract as camel
function M.pascal(s)
    local words = M.words(s)
    if #words == 0 then
        return ''
    end
    return joinCased(words, true, true)
end

--- 'GiveMoney' -> 'give_money'.
--- @param s
--- @return string  '' for a non-string input
function M.snake(s)
    local words = M.words(s)
    local parts = {}
    for i = 1, #words do
        parts[i] = words[i]:lower()
    end
    return table.concat(parts, '_')
end

--- 'GiveMoney' -> 'give-money'.
--- @param s
--- @return string  same rules as snake, different joiner
function M.kebab(s)
    local words = M.words(s)
    local parts = {}
    for i = 1, #words do
        parts[i] = words[i]:lower()
    end
    return table.concat(parts, '-')
end

--- Split on a separator. This is the version with the edge cases the usual one gets
--- @param s
--- @param sep
--- @param opts
--- @return table|nil,string  the pieces, or nil and a reason for a bad separator or maxsplit
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
--- @param s
--- @param max
--- @param ellipsis
--- @return a string. nil in gives ''.
function M.truncate(s, max, ellipsis)
    if type(s) ~= 'string' then
        return ''
    end
    if type(max) ~= 'number' or max < 0 then
        return s
    end
    if ellipsis == nil then
        ellipsis = '...'
    elseif ellipsis == false or ellipsis == '' then
        ellipsis = ''
    end
    local function length(str)
        if HAS_UTF8 then
            -- utf8.len returns (count, positionOfFirstInvalidByte).
            local _, count = utf8.len(str)
            return count or #str
        end
        return #str
    end
    local len = length(s)
    if len <= max then
        return s
    end
    if ellipsis == '' then
        if HAS_UTF8 then
            local cut = utf8.offset(s, max + 1)
            return cut and s:sub(1, cut - 1) or ''
        end
        return s:sub(1, max)
    end
    local keep = max - length(ellipsis)
    if keep <= 0 then
        if HAS_UTF8 then
            local cut = utf8.offset(ellipsis, max + 1)
            return cut and ellipsis:sub(1, cut - 1) or ''
        end
        return ellipsis:sub(1, max)
    end
    if HAS_UTF8 then
        local cut = utf8.offset(s, keep + 1)
        return (cut and s:sub(1, cut - 1) or '') .. ellipsis
    end
    return s:sub(1, keep) .. ellipsis
end

--- Whether this runtime has the utf8 library.
--- @return boolean  true when this runtime has the utf8 library
function M.hasUtf8()
    return HAS_UTF8
end

--- Collapse every run of whitespace to one space and trim both ends.
--- @param s
--- @return string  every whitespace run collapsed to one space, both ends trimmed
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
--- @param s
--- @param needle
--- @param ignoreCase
--- @return boolean. Never raises for any input, including nil.
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

--- @param s
--- @param prefix
--- @param ignoreCase
--- @return boolean  false for a non-string, and true for an empty prefix
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

--- @param s
--- @param suffix
--- @param ignoreCase
--- @return boolean  false for a non-string, and true for an empty suffix
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
--- @param s
--- @param width
--- @param fill
--- @return string  padded on the left to a BYTE width; unchanged when already long enough
function M.padStart(s, width, fill)
    s = type(s) == 'string' and s or tostring(s)
    fill = (type(fill) == 'string' and fill ~= '') and fill or ' '
    if #s >= width then
        return s
    end
    local need = width - #s
    return fill:rep(math.ceil(need / #fill)):sub(1, need) .. s
end

--- Pad on the right to `width`.
--- @param s
--- @param width
--- @param fill
--- @return string  padded on the right to a BYTE width
function M.padEnd(s, width, fill)
    s = type(s) == 'string' and s or tostring(s)
    fill = (type(fill) == 'string' and fill ~= '') and fill or ' '
    if #s >= width then
        return s
    end
    local need = width - #s
    return s .. fill:rep(math.ceil(need / #fill)):sub(1, need)
end

--- Levenshtein edit distance between two strings.
--- @param a
--- @param b
--- @param maxDistance
--- @return the distance, or `nil, reason`. When maxDistance is given and the
function M.levenshtein(a, b, maxDistance)
    if type(a) ~= 'string' or type(b) ~= 'string' then
        return nil, 'both arguments must be strings'
    end
    local la, lb = #a, #b
    if la == 0 then
        return lb
    end
    if lb == 0 then
        return la
    end
    if a == b then
        return 0
    end
    -- The shorter string drives the row width so the table is min(la, lb)+1.
    local cap = maxDistance or math.max(la, lb)
    if math.abs(la - lb) > cap then
        return cap + 1
    end
    local prev = {}
    local cur = {}
    for j = 0, lb do
        prev[j] = j
    end
    for i = 1, la do
        cur[0] = i
        local best = cur[0]
        local ca = a:byte(i)
        for j = 1, lb do
            local cost = 0
            if ca ~= b:byte(j) then
                cost = 1
            end
            local d = prev[j - 1] + cost
            local del = prev[j] + 1
            if del < d then d = del end
            local ins = cur[j - 1] + 1
            if ins < d then d = ins end
            cur[j] = d
            if d < best then best = d end
        end
        if best > cap then
            -- Every cell in this row is already past the ceiling: no later row can come
            return cap + 1
        end
        prev, cur = cur, prev
    end
    return prev[lb]
end

--- Pick the closest candidate to `word`.
--- @param word
--- @param candidates
--- @param opts
--- @return `match, distance`, or `nil` when nothing is close enough, or
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
    -- Re-score the winner in its real casing, so the distance the caller logs is the
    return best, M.levenshtein(word, best, nil)
end

-- A MODULE, NOT A GLOBAL.
if ... ~= 'cis_require' then
    CisString = M
end

return M
