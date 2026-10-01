-- Strict semantic-version parsing, comparison, and range satisfaction.
--
-- PURE, no natives, no module state, no dependencies. Safe to `shared_script`
-- for a private copy (COMPATIBILITY.md §10.2).
--
-- ##########################################################################
-- # RELATIONSHIP TO CisDetect.versionAtLeast -- THEY DISAGREE, ON PURPOSE. #
-- ##########################################################################
--
-- shared/detect.lua has `CisDetect.versionAtLeast(have, want)`. It is NOT
-- deprecated and nothing here replaces it. Read this before choosing.
--
--   CisDetect.versionAtLeast('1.9.0-beta3', '1.9.0')  -->  TRUE
--   CisSemver.satisfies('1.9.0-beta3', '>=1.9.0')    -->  FALSE
--
-- That gap is the point of both functions. `versionAtLeast` exists to answer
-- "is this framework new enough to boot against?" during detection, and there
-- the tolerant answer is the correct one: a server running qb-core 1.9.0-beta3
-- must not be refused as "too old" because of a prerelease tag, and detection
-- that hard-fails on a version string takes the whole library down at boot. It
-- also splits on '.' and '-' and coerces each piece with tonumber, so
-- 'es_extended 1.9.0-legacy' orders without a parser.
--
-- This module implements the actual SemVer 2.0.0 rules, where a prerelease
-- sorts BEFORE its release and therefore does not satisfy a plain range. That is
-- what npm means, and a manifest that says 'requires ^2.1.0' has to be refused
-- when 2.1.0-rc1 turns up -- the opposite of what versionAtLeast would say.
--
-- So: use CisDetect.versionAtLeast for framework detection, use this file for
-- anything where a prerelease genuinely is a different thing. Two questions,
-- not two implementations of one.
--
-- What this file does NOT do: `^0.x` uses caret's literal definition
-- (`^0.2.3` allows 0.2.x but not 0.3.0), not npm's "0.x means anything under
-- it" rule, because that rule is npm policy for how PACKAGES are versioned
-- rather than a property of the version itself. `~0.2.3` allows 0.2.x. If you
-- want npm's 0.x behaviour, write `>=0.0.0 <1.0.0`, which is what npm expands
-- it to anyway.

CisSemver = {}

--- Parse a version string into its parts.
---
--- Accepts a leading 'v' ('v1.2.3') because resource versions and git tags are
--- written both ways and refusing half of them is a papercut, not a safety
--- property. Accepts 1 or 2 numeric components ('1' -> 1.0.0, '1.2' -> 1.2.0)
--- for the same reason.
---
--- Prerelease and build metadata follow the spec: '-' then dot-separated
--- identifiers where a NUMERIC identifier has no leading zero, then '+' then
--- build identifiers where leading zeros ARE allowed. The asymmetry is in the
--- spec and is the thing most hand-rolled comparators get wrong.
---
--- A TABLE is passed through unchanged, so an already-parsed version can be fed
--- to compare and satisfies without being re-parsed for every candidate.
---
---@param v
--- @return { major, minor, patch, prerelease, build, raw, normalized }, or
---   `nil, reason` naming what was wrong. Nothing raises.
function CisSemver.parse(v)
    if type(v) == 'table' then
        return v
    end
    if type(v) ~= 'string' then
        return nil, ('version must be a string, got %s'):format(type(v))
    end
    local s = v:gsub('^%s+', ''):gsub('%s+$', ''):gsub('^v', '')
    if s == '' then
        return nil, 'version is empty'
    end

    local prerelease, build
    local plusAt = s:find('+', 1, true)
    if plusAt then
        build = s:sub(plusAt + 1)
        s = s:sub(1, plusAt - 1)
        if build == '' or build:find('[^%w%-_%.]') then
            return nil, 'build metadata must be dot-separated alphanumeric identifiers'
        end
    end
    local dashAt = s:find('-', 1, true)
    if dashAt then
        prerelease = s:sub(dashAt + 1)
        s = s:sub(1, dashAt - 1)
        if prerelease == '' then
            return nil, 'prerelease is empty after the hyphen'
        end
        if prerelease:find('[^%w%-_%.]') then
            return nil, 'prerelease must be dot-separated alphanumeric identifiers'
        end
        -- The spec's own rule, which surprises people: NUMERIC identifiers
        -- must not have leading zeroes. '01' is numeric, so '1.0.0-alpha.01'
        -- is ILLEGAL; '01a' is alphanumeric, so '1.0.0-alpha.01a' is fine. The
        -- leading zero is legal in BUILD metadata, where the rule does not
        -- apply -- the asymmetry is deliberate on the spec's part.
        for piece in prerelease:gmatch('[^%.]+') do
            if piece:match('^%d+$') and #piece > 1 and piece:sub(1, 1) == '0' then
                return nil, ('prerelease identifier %q has a leading zero'):format(piece)
            end
        end
    end

    local core = {}
    for piece in s:gmatch('[^%.]+') do
        core[#core + 1] = piece
    end
    if #core == 0 then
        return nil, 'version has no numeric part'
    end
    if #core > 3 then
        return nil, ('version has %d numeric parts, at most 3 are allowed'):format(#core)
    end
    for _, piece in ipairs(core) do
        if not piece:match('^%d+$') then
            return nil, ('%q is not a number'):format(piece)
        end
        -- '01.2.3' from a version that went through a spreadsheet is a real
        -- input, not a hypothetical, and silently reading it as 1.2.3 would make
        -- two different strings the same version.
        if #piece > 1 and piece:sub(1, 1) == '0' then
            return nil, ('%q has a leading zero'):format(piece)
        end
        -- Fifteen digits is the last width a double holds exactly: 2^53 is
        -- about 9.007e15, and 999999999999999 is the largest all-nines value
        -- under it. A wider part is refused rather than accepted because it
        -- cannot be parsed, not merely because it is unusual -- the value
        -- silently becomes a DIFFERENT number, so 'normalized' would report a
        -- version nobody wrote. Refusing with a reason is the only honest
        -- answer, and this file promises never to raise.
        if #piece > 15 then
            return nil, ('%q has %d digits, at most 15 fit in a double exactly')
                :format(piece, #piece)
        end
    end

    local major = tonumber(core[1]) or 0
    local minor = tonumber(core[2]) or 0
    local patch = tonumber(core[3]) or 0
    return {
        major = major, minor = minor, patch = patch,
        prerelease = prerelease, build = build,
        raw = v,
        -- %.0f rather than %d ON PURPOSE. A component wide enough to be a
        -- float has no integer representation for %d to print -- in Lua 5.3
        -- it raises outright, and in fengari %d rejects a float from ten
        -- digits up -- so formatting a perfectly legal ten-digit major used
        -- to take the parser down. Every value reaching here is under 2^53 and
        -- integral, which is exactly the range %.0f prints without rounding.
        normalized = ('%.0f.%.0f.%.0f%s%s'):format(major, minor, patch,
            prerelease and ('-' .. prerelease) or '',
            build and ('+' .. build) or ''),
    }
end

-- Compare two prerelease identifier lists per SemVer 2.0.0 section 11.
--
-- An identifier is compared numerically when BOTH sides are numeric, and as a
-- string otherwise. Numeric always sorts below alphanumeric, so
-- 1.0.0-alpha.1 < 1.0.0-alpha.beta. A longer list wins when every shared
-- identifier ties, so 1.0.0-alpha < 1.0.0-alpha.1. A version WITH a prerelease
-- has lower precedence than the same version without one.
local function comparePrerelease(a, b)
    if not a and not b then return 0 end
    if not a then return 1 end
    if not b then return -1 end
    local ai, bi = 1, 1
    while true do
        local x, y = a:match('[^%.]+', ai), b:match('[^%.]+', bi)
        if not x and not y then return 0 end
        if not x then return -1 end
        if not y then return 1 end
        local xn, yn = tonumber(x), tonumber(y)
        if xn and yn then
            if xn ~= yn then
                return xn < yn and -1 or 1
            end
        elseif xn then
            return -1
        elseif yn then
            return 1
        else
            if x ~= y then
                return x < y and -1 or 1
            end
        end
        ai = ai + #x + 1
        bi = bi + #y + 1
    end
end

--- Compare two versions.
---
---@param a
---@param b
--- @return -1 if a < b, 0 if equal, 1 if a > b -- or `nil, reason` when either
---   side does not parse. A refusal rather than a default of 0, because "these
---   are incomparable because one is not a version" and "these are the same
---   version" are different answers, and collapsing them makes a typo look like
---   a match.
---
--- BUILD METADATA IS IGNORED, per the spec: 1.0.0+build1 and 1.0.0+build2 have
--- equal precedence. Two FiveM resources built from one commit with different
--- build stamps must not read as an upgrade.
function CisSemver.compare(a, b)
    local pa, whyA = CisSemver.parse(a)
    if not pa then
        return nil, whyA
    end
    local pb, whyB = CisSemver.parse(b)
    if not pb then
        return nil, whyB
    end
    if pa.major ~= pb.major then
        return pa.major < pb.major and -1 or 1
    end
    if pa.minor ~= pb.minor then
        return pa.minor < pb.minor and -1 or 1
    end
    if pa.patch ~= pb.patch then
        return pa.patch < pb.patch and -1 or 1
    end
    return comparePrerelease(pa.prerelease, pb.prerelease)
end

---@param a
---@param b
--- @return boolean, or `nil, reason` (see compare).
function CisSemver.gte(a, b)
    local c, why = CisSemver.compare(a, b)
    if c == nil then return nil, why end
    return c >= 0
end

---@param a
---@param b
--- @return boolean, or `nil, reason`.
function CisSemver.lt(a, b)
    local c, why = CisSemver.compare(a, b)
    if c == nil then return nil, why end
    return c < 0
end

---@param a
---@param b
--- @return boolean, or `nil, reason`. Build metadata does not affect equality.
function CisSemver.eq(a, b)
    local c, why = CisSemver.compare(a, b)
    if c == nil then return nil, why end
    return c == 0
end

-- Split a range token into its operator and its version.
--
-- Written as an if-chain on purpose. The obvious one-liner
-- `token:match('^(>=|<=|>|<)?(.+)$')` is wrong, and wrong in a way that is
-- silent: Lua patterns have NO alternation operator -- `|` is an ordinary
-- character -- so that pattern matches the literal twelve-character sequence
-- `>=|<=|>|<`, never matches, and every range token falls through with no
-- operator at all. Every `>=` in every range then parses as a version and
-- fails. There is no syntax error and no warning.
local function splitOperator(token)
    local two = token:sub(1, 2)
    if two == '>=' then return '>=', token:sub(3) end
    if two == '<=' then return '<=', token:sub(3) end
    local one = token:sub(1, 1)
    if one == '>' then return '>', token:sub(2) end
    if one == '<' then return '<', token:sub(2) end
    if one == '=' then return '=', token:sub(2) end
    if one == '~' then return '~', token:sub(2) end
    if one == '^' then return '^', token:sub(2) end
    return '=', token
end

-- How many numeric components were WRITTEN in a comparator.
--
-- Not the same question as "how many does this version have": `parse` has
-- already zero-filled 1.2 to 1.2.0, and the operators below need to know which
-- end the caller actually typed.
--
-- Prerelease and build suffixes are excluded on purpose. Counting every run of
-- digits in the token made '~1-rc1' look like two components, which quietly
-- turned '~1' -- >=1.0.0 <2.0.0 -- into '>=1.0.0 <1.1.0'.
local function writtenComponents(rest)
    local core = rest:match('^[^%-%+]+') or rest
    local n = 0
    for _ in core:gmatch('%d+') do
        n = n + 1
    end
    return n
end

-- The bound a PARTIAL upper comparator really means: the last component
-- written, bumped by one, with everything after it zeroed.
local function bumpedUpper(parsed, written)
    if written <= 1 then
        return { major = parsed.major + 1, minor = 0, patch = 0 }
    end
    return { major = parsed.major, minor = parsed.minor + 1, patch = 0 }
end

-- Expand one range token into the one or two inclusive/exclusive bounds it
-- means. Returns a list of { op, v } pairs, or nil plus a reason.
--
-- Declared BEFORE CisSemver.satisfies on purpose. In Lua an upvalue is
-- resolved lexically, so a `local function` written after its caller makes the
-- caller reach for a GLOBAL of that name -- nil at runtime, with no syntax
-- error anywhere to warn about it.
local function boundsFor(token)
    local op, rest = splitOperator(token)
    if rest == nil or rest == '' then
        return nil, ('comparator %q has no version'):format(token)
    end

    -- Wildcards: '*', 'x', '1.x', '1.2.*', '1.2.3.x'. Only the '=' form makes
    -- sense with a wildcard -- '>=1.x' has no meaning, and guessing one would
    -- be worse than refusing.
    local wildcardAt = rest:find('[xX*]')
    if wildcardAt then
        if op ~= '=' then
            return nil, ('wildcard %q cannot carry the %q operator'):format(token, op)
        end
        local prefix = rest:sub(1, wildcardAt - 1):gsub('%.$', '')
        if prefix == '' then
            -- Bare '*' or 'x': any release at all. Still subject to the
            -- prerelease rule applied by the caller.
            return { { op = '>=', v = { major = 0, minor = 0, patch = 0 } } }
        end
        -- '1.x' and '1.2.x' both have to work, so the prefix is a dot-separated
        -- list of numbers rather than one. It is validated by walking the
        -- pieces instead of with `^%d+(%.%d+)*$`: that pattern is the obvious
        -- one-liner, and it does not work here, because a CAPTURE group with a
        -- `*` quantifier fails to match zero repetitions in fengari's pattern
        -- engine -- '1' does not match it, so '1.x' is refused. Walking the
        -- pieces is also the only version that catches '1..x' and '.x', whose
        -- components all look numeric individually.
        local numbers = {}
        local valid = true
        for piece in prefix:gmatch('[^%.]+') do
            if piece:match('^%d+$') then
                numbers[#numbers + 1] = tonumber(piece)
            else
                valid = false
            end
        end
        if not valid or #numbers == 0
            or prefix:sub(1, 1) == '.' or prefix:sub(-1) == '.'
            or prefix:find('..', 1, true) then
            return nil, ('wildcard %q has a non-numeric prefix'):format(token)
        end
        if #numbers > 3 then
            return nil, ('wildcard %q has more than 3 numeric parts'):format(token)
        end
        local low = {
            major = numbers[1] or 0,
            minor = numbers[2] or 0,
            patch = numbers[3] or 0,
        }
        local high
        if #numbers <= 1 then
            high = { major = numbers[1] + 1, minor = 0, patch = 0 }
        elseif #numbers == 2 then
            high = { major = numbers[1], minor = numbers[2] + 1, patch = 0 }
        else
            high = { major = numbers[1], minor = numbers[2], patch = numbers[3] + 1 }
        end
        return { { op = '>=', v = low }, { op = '<', v = high } }
    end

    local parsed, why = CisSemver.parse(rest)
    if not parsed then
        return nil, ('comparator %q: %s'):format(token, why)
    end

    if op == '^' then
        local low = {
            major = parsed.major, minor = parsed.minor, patch = parsed.patch,
            prerelease = parsed.prerelease,
        }
        local high
        if parsed.major > 0 then
            high = { major = parsed.major + 1, minor = 0, patch = 0 }
        elseif parsed.minor > 0 then
            high = { major = 0, minor = parsed.minor + 1, patch = 0 }
        else
            high = { major = 0, minor = 0, patch = parsed.patch + 1 }
        end
        return { { op = '>=', v = low }, { op = '<', v = high } }
    end

    -- Partial upper comparators, which npm reads as a whole component range.
--
-- '<=1.2' means '<1.3.0', not '<=1.2.0', and '>1.2' means '>=1.3.0', not
-- '>1.2.0'. Read literally against the zero-filled parse, '<=1.2' refused every
-- patch release after 1.2.0 -- a range written to allow a whole minor, in a
-- config, rejecting a working resource at boot. '<1.2' and '>=1.2' are already
-- what they say and are left alone.
if op == '<=' or op == '>' then
    local written = writtenComponents(rest)
    if written < 3 then
        return { { op = op == '<=' and '<' or '>=', v = bumpedUpper(parsed, written) } }
    end
end

if op == '~' then
        -- ~1 is >=1.0.0 <2.0.0; ~1.2 is >=1.2.0 <1.3.0; ~1.2.3 is >=1.2.3 <1.3.0.
        -- The bump level is the LAST COMPONENT WRITTEN, which is why the
        -- component count comes from the text: the parsed value has already
        -- zero-filled 1.2 to 1.2.0 and the distinction is gone.
        local written = writtenComponents(rest)
        local low = {
            major = parsed.major, minor = parsed.minor, patch = parsed.patch,
            prerelease = parsed.prerelease,
        }
        local high
        if written <= 1 then
            high = { major = parsed.major + 1, minor = 0, patch = 0 }
        else
            high = { major = parsed.major, minor = parsed.minor + 1, patch = 0 }
        end
        return { { op = '>=', v = low }, { op = '<', v = high } }
    end

    return { { op = op, v = parsed } }
end

-- Evaluate one alternative: a space-separated AND of comparators.
--
-- Returns true, false, or nil plus a reason for a malformed comparator. The
-- three-way return is what lets satisfies() tell "this alternative does not
-- match" apart from "this range is nonsense".
local function satisfiesAlternative(target, text, includePrerelease)
    local tokens = {}
    for token in text:gmatch('%S+') do
        tokens[#tokens + 1] = token
    end
    if #tokens == 0 then
        -- An empty alternative in the MIDDLE of a range -- '^1.0.0 || || ^3.0.0'
        -- -- matches everything, which is what npm does and is the least
        -- surprising reading of a stray '||'. A range that is ENTIRELY empty
        -- ('||' on its own) never reaches here: satisfies() drops empty
        -- alternatives and then refuses, because a range with no comparators
        -- in it at all is a mistake rather than a wildcard.
        return true
    end

    -- THE PRERELEASE RULE. A version carrying a prerelease is only eligible
    -- inside an alternative that names a prerelease at the SAME core version.
    -- So satisfies('2.0.0-rc1', '>=1.0.0') is false even though the numbers
    -- say it qualifies, which is npm's rule and the reason a range means what
    -- it says: 'any 2.x' must not quietly accept last year's alpha.
    if target.prerelease and not includePrerelease then
        local eligible = false
        for _, token in ipairs(tokens) do
            -- Strip the operator before looking for a tag, or the '-' inside
            -- '>=2.0.0-rc0' is found at the wrong offset.
            local body = select(2, splitOperator(token))
            local core, tag = body:match('^([%d%.]+)%-(.+)$')
            if tag and tag ~= '' then
                local c = CisSemver.parse(core)
                if c and c.major == target.major and c.minor == target.minor
                    and c.patch == target.patch then
                    eligible = true
                    break
                end
            end
        end
        if not eligible then
            return false
        end
    end

    -- Bounds are collected first so that a malformed comparator is reported
    -- even when an earlier one has already failed the alternative. A range with
    -- a typo in it should say so, not quietly evaluate to false.
    local all = {}
    for _, token in ipairs(tokens) do
        local bounds, err = boundsFor(token)
        if not bounds then
            return nil, err
        end
        for i = 1, #bounds do
            all[#all + 1] = bounds[i]
        end
    end

    for i = 1, #all do
        local b = all[i]
        local c, why = CisSemver.compare(target, b.v)
        if c == nil then
            return nil, why
        end
        local holds
        if b.op == '>=' then holds = c >= 0
        elseif b.op == '>' then holds = c > 0
        elseif b.op == '<=' then holds = c <= 0
        elseif b.op == '<' then holds = c < 0
        else holds = c == 0 end
        if not holds then
            return false
        end
    end
    return true
end

--- Does `version` satisfy a range expression?
---
--- SUPPORTED, all combinable:
---   * comparators  `>=1.2.3`, `>1.2.3`, `<=1.2`, `<1.2.3`, `=1.2.3`, `1.2.3`
---   * wildcards    `*`, `x`, `1.x`, `1.2.x`, `1.2.3.x`
---   * caret        `^1.2.3` -- >=1.2.3 <2.0.0 ;  `^0.2.3` -- >=0.2.3 <0.3.0
---   * tilde        `~1.2.3` -- >=1.2.3 <1.3.0  ;  `~1.2` -- >=1.2.0 <1.3.0
---   * AND          spaces separate comparators: `>=1.2.0 <2.0.0`
---   * OR           `||` separates alternatives: `^1.0.0 || ^3.0.0`
---
--- PARTIAL COMPARATORS follow npm: an upper comparator written with fewer than
--- three components names a whole component range, so `<=1.2` is `<1.3.0` and
--- `>1.2` is `>=1.3.0`. `<1.2` is `<1.2.0` and `>=1.2` is `>=1.2.0`.
---
--- ONE KNOWN DIVERGENCE: `=1.2` is `=1.2.0` here, while npm expands it to
--- `>=1.2.0 <1.3.0`. Exact equality is the stricter reading and it is left
--- alone deliberately -- widening it changes which versions an existing
--- manifest accepts, and that is a call for whoever owns the contract rather
--- than for a parser. Write `1.2.x` if that is what you meant.
---
--- opts.includePrerelease relaxes the prerelease rule above. It is the only
--- way to, and it is off by default.
---
---@param version
---@param range
---@param opts
--- @return boolean, or `nil, reason` when the range or the version is
---   malformed. A version that simply fails the range is `false`, never nil.
function CisSemver.satisfies(version, range, opts)
    opts = opts or {}
    local includePrerelease = opts.includePrerelease == true
    local target, why = CisSemver.parse(version)
    if not target then
        return nil, why
    end
    if type(range) ~= 'string' then
        return nil, ('range must be a string, got %s'):format(type(range))
    end
    if range:gsub('%s+', '') == '' then
        return nil, 'range is empty'
    end

    local alternatives = {}
    for alt in (range .. '||'):gmatch('(.-)||') do
        local trimmed = alt:gsub('^%s+', ''):gsub('%s+$', '')
        if trimmed ~= '' then
            alternatives[#alternatives + 1] = trimmed
        end
    end
    if #alternatives == 0 then
        return nil, 'range has no comparators in it'
    end

    for i = 1, #alternatives do
        local matched, problem = satisfiesAlternative(target, alternatives[i], includePrerelease)
        if matched == nil then
            return nil, problem
        end
        if matched then
            return true
        end
    end
    return false
end

--- The highest version in a list that satisfies `range`, or nil.
--
--- For "run the newest compatible" logic. The convenience is here because the
--- obvious way to write it -- iterate the list and keep the best so far -- is
-- the version that gets the comparison backwards and silently returns the
-- OLDEST match.
--
---@param candidates
---@param range
---@param opts
--- @return the version string as it appeared in the list, or `nil` when
---   nothing satisfies. A malformed range or candidate is `nil, reason`; both
---   are nil as the first value, so read the second when the difference
---   matters.
function CisSemver.best(candidates, range, opts)
    if type(candidates) ~= 'table' then
        return nil, ('candidates must be a table, got %s'):format(type(candidates))
    end
    local bestRaw, bestParsed
    for i = 1, #candidates do
        local ok, why = CisSemver.satisfies(candidates[i], range, opts)
        if ok == nil then
            return nil, why
        end
        if ok then
            local parsed = CisSemver.parse(candidates[i])
            if bestParsed == nil or CisSemver.compare(parsed, bestParsed) > 0 then
                bestParsed, bestRaw = parsed, candidates[i]
            end
        end
    end
    return bestRaw
end
