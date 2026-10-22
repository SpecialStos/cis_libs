-- UTF-8 that survives json.encode and a byte budget. No natives.
--
-- json.encode raises on an invalid byte sequence, so a string bound for the
-- page or the wire is cleaned first. Cleaning used to replace EVERY byte above
-- 127 with '?' once one sequence was bad, and a server cut by bytes landed in
-- the middle of a character: a Cyrillic title arrived as "???? ????". Here only
-- the bad bytes become '?', and a cut always lands on a character boundary.

CisUtf8 = {}

-- The length of the sequence that starts at byte i, or nil if it is not a
-- valid one (overlong forms, surrogates and values past U+10FFFF included).
local function seqLen(s, i)
    local c = s:byte(i)
    if c < 0x80 then
        return 1
    end
    local n, lo, hi
    if c >= 0xC2 and c <= 0xDF then
        n = 2
    elseif c >= 0xE0 and c <= 0xEF then
        n = 3
        lo = (c == 0xE0) and 0xA0 or 0x80
        hi = (c == 0xED) and 0x9F or 0xBF
    elseif c >= 0xF0 and c <= 0xF4 then
        n = 4
        lo = (c == 0xF0) and 0x90 or 0x80
        hi = (c == 0xF4) and 0x8F or 0xBF
    else
        return nil
    end
    for k = 1, n - 1 do
        local b = s:byte(i + k)
        if not b then
            return nil
        end
        local min, max = 0x80, 0xBF
        if k == 1 and lo then
            min, max = lo, hi
        end
        if b < min or b > max then
            return nil
        end
    end
    return n
end

-- `s` with each invalid byte replaced by '?'; valid characters are kept.
-- Checked byte by byte, not with utf8.len: how strict that is about
-- surrogates differs between Lua builds (fengari's accepts them).
function CisUtf8.clean(s)
    if not s:find('[\128-\255]') then
        return s
    end
    local out, i, n = {}, 1, #s
    while i <= n do
        local len = seqLen(s, i)
        if len then
            out[#out + 1] = s:sub(i, i + len - 1)
            i = i + len
        else
            out[#out + 1] = '?'
            i = i + 1
        end
    end
    return table.concat(out)
end

-- Whether `s` is valid UTF-8 as clean() defines it.
function CisUtf8.valid(s)
    return CisUtf8.clean(s) == s
end

-- At most `maxBytes` bytes of a VALID string, cut on a character boundary.
function CisUtf8.clip(s, maxBytes)
    if #s <= maxBytes then
        return s
    end
    local cut = maxBytes + 1
    -- Back off over continuation bytes to the start of the character that
    -- would have been split.
    while cut > 1 do
        local b = s:byte(cut)
        if b < 0x80 or b >= 0xC0 then
            break
        end
        cut = cut - 1
    end
    return s:sub(1, cut - 1)
end

-- The length a browser gives `s` (UTF-16 code units), so a min or max length
-- checked here agrees with `value.length` on the page.
function CisUtf8.units(s)
    local n = 0
    for _, cp in utf8.codes(s) do
        n = n + (cp >= 0x10000 and 2 or 1)
    end
    return n
end
