-- String helpers: case conversion, splitting, truncation, fuzzy matching.
--
-- PURE, no natives, no module state, no dependencies. Safe to `shared_script`
-- for a private copy (COMPATIBILITY.md §10.2).
--
-- WHY THIS FILE IS CALLED string.lua: nothing in this library `require`s
-- anything, so a file name never shadows the `string` global. The chunk is
-- loaded by path and contributes exactly one global: CisString.
--
-- The case converter and the typo suggester exist for one concrete use: a
-- `/command` handler that gets `/giviemoney` and has to say "did you mean
-- /giveMoney?". Levenshtein alone is not enough for that -- without a case
-- comparison it will rank `giveMoney` below `gimemoney` -- so `suggest`
-- compares lowercased first and only then spends the O(n*m) table.
--
-- A note on UNICODE, because Lua strings are byte strings and pretending
-- otherwise is where these functions usually break:
--   * Every case test here is a BYTE range test, so accented Latin text is not
--     case-folded: 'CAFÉ' does not become 'café'. Use string.lower for that,
--     with the same limitation.
--   * Bytes >= 0x80 are treated as WORD CHARACTERS and never dropped, so
--     'caféMoney' -> 'café-money' keeps its é. The alternative -- treating them
--     as separators, which is what a naive [A-Za-z] split does -- silently
--     deletes them and turns 'café' into 'caf'.
--   * truncate counts CODEPOINTS when the utf8 library is present and BYTES
--     when it is not, because a FiveM CLIENT runs LuaJIT, which has no utf8
--     library at all. See the note on truncate.

CisString = {}

-- Feature-detected rather than assumed. Lua 5.3 and 5.4 ship utf8; LuaJIT
-- (which is what a FiveM client runs) does not. Anything below that branches
-- on utf8 has to work in both worlds.
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

-- Everything else -- accented bytes, Cyrillic, emoji -- is a word character as
-- far as the splitter is concerned. Splitting on them would be lossy, and a
-- case converter that drops the non-ASCII part of a player's name is worse
-- than one that leaves it alone.
local function isWordByte(b)
    return isUpper(b) or isLower(b) or isDigit(b) or b >= 128
end

local function isSpaceByte(b)
    return b == 32 or (b >= 9 and b <= 13)
end

--- Break a string into words, in the sense the case converters mean.
---
--- Splits at three kinds of boundary:
---   * any byte that is not a word byte -- space, `_`, `-`, `.`, `/`, brackets.
---     These are DROPPED, not kept, because that is what "convert the case of
---     this identifier" means.
---   * lower/digit -> upper. 'giveMoney' -> 'give', 'Money'.
---   * the last upper of a run that is followed by a lower. 'HTTPServer' ->
---     'HTTP', 'Server'. This is the acronym rule, and without it 'HTTPServer'
---     camel-cases to 'hTTPServer', which is not a word anybody uses.
---
--- Digits do NOT start a new word: 'v2Mode' -> 'v2', 'Mode' rather than
--- 'v', '2', 'Mode'. The digit->letter boundary splits; the letter->digit one
--- does not. That is the conventional choice for version strings.
---
--- Empty pieces never appear, so the result is always a dense list.
function CisString.words(s)
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
            -- The acronym rule, in full: an upper at i begins a new word when
            --   (a) the byte before it is lower or a digit   -- 'give|Money'
            -- or (b) the byte before it is upper AND the byte after is lower
            --       -- 'HTTP|Server'
            -- and NOT merely because the byte before it is upper. That last
            -- distinction is the one that goes wrong: splitting at every
            -- upper turns 'HTTPServer' into H/T/T/P/Server, which is why the
            -- `nextIsLower` term is here and why it demands a following byte.
            -- With none -- 'HTTPS', 'AB' -- nothing splits.
            local prev = s:byte(i - 1)
            local nextIsLower = false
            local nb = s:byte(i + 1)
            if nb ~= nil then
                nextIsLower = isLower(nb)
            end
            -- `not isUpper(prev)` rather than `isLower(prev) or isDigit(prev)`:
            -- a byte >= 128 is neither, and testing it explicitly here is what
            -- keeps 'caféMoney' splitting into two words instead of one.
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

-- Recase one word. The TAIL is lowercased as well as the head being
-- uppercased: without that, 'GIVE_MONEY' camel-cases to 'gIVEmONEY', because
-- splitting an all-uppercase word leaves it upper, and only the first letter
-- was being touched.
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

--- 'give_money' -> 'giveMoney'. '' in, '' out.
---
--- The first word is lowercased and the rest are capitalised. Input may be any
--- of the shapes words() understands: 'GiveMoney', 'GIVE_MONEY', 'give-money'
--- and 'give money' all produce 'giveMoney'.
function CisString.camel(s)
    local words = CisString.words(s)
    if #words == 0 then
        return ''
    end
    return joinCased(words, false, true)
end

--- 'give_money' -> 'GiveMoney'. Same input contract as camel.
function CisString.pascal(s)
    local words = CisString.words(s)
    if #words == 0 then
        return ''
    end
    return joinCased(words, true, true)
end

--- 'GiveMoney' -> 'give_money'. Word boundaries become underscores.
---
--- The existing casing is PRESERVED except that an all-uppercase word is
--- lowercased: 'GiveHTTPServer' -> 'give_http_server', not
--- 'Give_HTTPServer'. A snake_case identifier that still contains 'HTTPServer'
--- is not snake_case, and every consumer of it has to special-case that.
function CisString.snake(s)
    local words = CisString.words(s)
    local parts = {}
    for i = 1, #words do
        parts[i] = words[i]:lower()
    end
    return table.concat(parts, '_')
end

--- 'GiveMoney' -> 'give-money'. Identical rules to snake, different joiner.
function CisString.kebab(s)
    local words = CisString.words(s)
    local parts = {}
    for i = 1, #words do
        parts[i] = words[i]:lower()
    end
    return table.concat(parts, '-')
end

--- Split on a separator.
---
--- This is the version with the edge cases the usual one gets wrong:
---
---   * `split('', ',')`  -> `{}`     ONE empty piece, not `{''}`.
---     A single empty string is not "one field between separators"; it is no
---     fields. Every CSV-shaped caller that got `{''}` then had to special-case
---     it, which is why so many copies of this function exist.
---   * `split('a,,b')`    -> a, '', b   INTERIOR empties are kept. A blank
---     column in a CSV is a blank column; dropping it shifts every field after
---     it, which is a data-corruption bug rather than a tidiness win.
---   * `split('a,b,')`    -> a, b, ''   The trailing empty is kept too, for
---     the same reason. If you want them gone, say so with opts.keepEmpty
---     = false -- do not have the default differ per caller.
---   * `split(',a')`      -> '', a
---   * `split(nil)`       -> `{}`
---   * separator must be non-empty and at least one character.
---
--- opts.keepEmpty  false drops every empty piece (default true).
--- opts.maxsplit  stop after this many SPLITS, keeping the unsplit remainder
---                 as the last piece. So split('a,b,c,d', ',', {maxsplit=2})
---                 is {'a','b','c,d'} -- nothing is discarded, which is the
---                 whole reason it counts splits and not pieces. A cap that
---                 silently dropped 'c,d' would be a data-loss trap wearing the
---                 costume of an optimisation. {maxsplit=0} returns the input
---                 as a single piece.
---
--- The separator is matched LITERALLY: it is a Lua pattern, so `split('a.b', '.')`
--- would match any character without the escape that is used here.
function CisString.split(s, sep, opts)
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

    -- A plain search, not a pattern: a separator of '.' or '%' or '-' has to
    -- match itself. `find(s, sep, init, true)` is the fourth-argument plain
    -- form and works on every Lua this library targets, including LuaJIT.
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
        -- Trailing separator: 'a,b,' leaves init one past the end and the body
        -- above produced a, b. The empty piece after the final separator is a
        -- real piece and is added here.
        push('')
    end
    return out
end

--- Cut to a maximum length, adding an ellipsis when it actually cut.
---
--- LENGTH IS IN CODEPOINTS when the utf8 library is available and in BYTES when
--- it is not, which is a real behavioural difference between the server (Lua
--- 5.4, has utf8) and a client (LuaJIT, does not) rather than an oversight.
--- `utf8len(s, max+1)` is the one call that both counts and finds the cut
--- point in a single pass.
---
--- Without utf8 the cut is at a byte boundary and MAY land in the middle of a
--- multi-byte character, leaving a broken final byte in the result. That is
--- stated rather than worked around because working around it needs the utf8
--- library, and a client does not have one. A character-boundary guarantee on
--- the client is therefore impossible without shipping the encoder; the caller
--- who needs it checks `CisString.hasUtf8()` first.
---
--- `ellipsis` defaults to '...'. Pass `false` for none. The ellipsis COUNTS
--- toward `max` -- the result is never longer than the caller asked for, which
--- is the one property that makes this usable inside a fixed-width UI field.
--- The consequence is worth knowing before you reach for it: truncate('hello',
--- 3) is '...', not 'he...', because three characters of ellipsis already fill
--- three characters of budget. Rails' truncate behaves the same way. Ask for
--- `max = length + 3` if you want the text plus its marker.
---
--- @return a string. nil in gives ''.
function CisString.truncate(s, max, ellipsis)
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
            -- utf8.len returns (count, positionOfFirstInvalidByte). The count
            -- is what is wanted; the second value is the error position and is
            -- discarded. A malformed string still yields a count.
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

--- Whether this runtime has the utf8 library. Exported so a caller can decide
--- whether byte-length semantics are acceptable before it uses truncate.
function CisString.hasUtf8()
    return HAS_UTF8
end

--- Collapse every run of whitespace to one space and trim both ends.
---
--- `\t\n\r\v\f` and space are all whitespace; nothing else is. A string of
--- only whitespace becomes ''. nil in gives ''.
function CisString.collapse(s)
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
            -- Only emit the separator once we know a non-space follows, which
            -- is what trims the leading run and the trailing run in one pass.
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
---
--- `plain = true` is what makes needle '.' and '%' match themselves; without
--- it `contains('config.json', '.')` would also be true for 'configXjson' and
--- the function would be worse than no function.
---
--- `ignoreCase` lowercases both sides first. That is byte-wise ASCII
--- lowercasing, so accented text does not fold -- see the header.
---
--- @return boolean. Never raises for any input, including nil.
function CisString.contains(s, needle, ignoreCase)
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

function CisString.startsWith(s, prefix, ignoreCase)
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

function CisString.endsWith(s, suffix, ignoreCase)
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

--- Pad on the left to `width`. Text longer than `width` is returned unchanged
--- -- truncation is a different decision and truncate() makes it explicitly.
---
--- `fill` is repeated as needed and cut to the exact pad width, so a two-byte
--- fill like '0' pads '7' to '007' and a one-byte fill needs no special case.
--- Padding is in BYTES: with the utf8 library present or not, this is a display
--- width, not a codepoint count.
function CisString.padStart(s, width, fill)
    s = type(s) == 'string' and s or tostring(s)
    fill = (type(fill) == 'string' and fill ~= '') and fill or ' '
    if #s >= width then
        return s
    end
    local need = width - #s
    return fill:rep(math.ceil(need / #fill)):sub(1, need) .. s
end

--- Pad on the right to `width`. Same byte-width rule as padStart.
function CisString.padEnd(s, width, fill)
    s = type(s) == 'string' and s or tostring(s)
    fill = (type(fill) == 'string' and fill ~= '') and fill or ' '
    if #s >= width then
        return s
    end
    local need = width - #s
    return s .. fill:rep(math.ceil(need / #fill)):sub(1, need)
end

--- Levenshtein edit distance between two strings.
---
--- Two-row dynamic programming, O(len(a) * len(b)) time and O(min) space.
--- Bytes, not codepoints: for ASCII command names that is exact, and for
--- anything else it is an approximation that still ranks correctly.
---
--- `maxDistance` (default: no limit) makes this SAFE for the "did you mean"
--- case. Without a ceiling, comparing a 3-character input against every
--- registered command is still O(n*m) per candidate and a server with 400
--- commands pays for all of it. With one, a candidate that is obviously
--- hopeless stops after a few cells, because the lowest a row can still reach
--- is its own row index.
---
--- @return the distance, or `nil, reason`. When maxDistance is given and the
---   true distance exceeds it, returns `maxDistance + 1` -- "farther than you
---   care about", not an error, so the caller can keep scoring candidates
---   without a branch.
function CisString.levenshtein(a, b, maxDistance)
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
    -- Also: a difference larger than the length of the longer string can never
    -- be reached by substitution alone, so it is a lower bound on the answer.
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
            -- Every cell in this row is already past the ceiling: no later row
            -- can come back under it.
            return cap + 1
        end
        prev, cur = cur, prev
    end
    return prev[lb]
end

--- Pick the closest candidate to `word`. This is the "did you mean" call.
---
--- The candidate list is compared CASE-INSENSITIVELY first, and that is not an
--- optimisation, it is a correctness fix. A distance over mixed case ranks the
--- wrong way: levenshtein('GIVEMONEY', 'giveMoney') is 8 -- eight case
--- substitutions -- while levenshtein('GIVEMONEY', 'gimemoney') is 1. Scored
--- raw, a typo beats the command the player actually meant. Lowercasing first,
--- then re-scoring only the winner in its real casing, fixes that and costs one
--- extra distance instead of one per candidate.
---
--- opts.maxDistance  reject anything further away than this (default 3, or
---                    `floor(len(word)/2) + 1` when shorter -- a two-character
---                    input has nothing within 3).
--- opts.comparator   scores candidates, default CisTable.compareKeys. The
---                    comparison is on DISTANCE, so a candidate list of
---                    numbers works too.
---
--- @return `match, distance`, or `nil` when nothing is close enough, or
---   `nil, reason` when the input itself is bad. Nothing-close is a nil with
---   NO reason: "no suggestion" is a normal answer for a typo handler, not an
---   error, and a caller that prints `why` on every miss would spam.
function CisString.suggest(word, candidates, opts)
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
            local score = CisString.levenshtein(lower, c:lower(), maxDistance)
            if score <= maxDistance then
                -- An exact case-insensitive hit is unbeatable; stop here rather
                -- than let a lucky 1-edit candidate displace it.
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
    -- Re-score the winner in its real casing, so the distance the caller logs
    -- is the honest one for the string it is about to print.
    return best, CisString.levenshtein(word, best, nil)
end
