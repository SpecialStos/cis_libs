-- Strict semantic-version parsing, comparison, and range satisfaction.

local M = {}

--- Parse a version string into its parts.
--- @param v
--- @return { major, minor, patch, prerelease, build, raw, normalized }, or
function M.parse(v)
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
        -- The spec's own rule, which surprises people: NUMERIC identifiers must not
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
        -- '01.2.3' from a version that went through a spreadsheet is a real input, not
        if #piece > 1 and piece:sub(1, 1) == '0' then
            return nil, ('%q has a leading zero'):format(piece)
        end
        -- Fifteen digits is the last width a double holds exactly: 2^53 is about
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
        -- %.0f rather than %d ON PURPOSE.
        normalized = ('%.0f.%.0f.%.0f%s%s'):format(major, minor, patch,
            prerelease and ('-' .. prerelease) or '',
            build and ('+' .. build) or ''),
    }
end

-- Compare two prerelease identifier lists per SemVer 2.0.0 section 11.
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
--- @param a
--- @param b
--- @return -1 if a < b, 0 if equal, 1 if a > b -- or `nil, reason` when either
function M.compare(a, b)
    local pa, whyA = M.parse(a)
    if not pa then
        return nil, whyA
    end
    local pb, whyB = M.parse(b)
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

--- @param a
--- @param b
--- @return boolean, or `nil, reason` (see compare).
function M.gte(a, b)
    local c, why = M.compare(a, b)
    if c == nil then return nil, why end
    return c >= 0
end

--- @param a
--- @param b
--- @return boolean, or `nil, reason`.
function M.lt(a, b)
    local c, why = M.compare(a, b)
    if c == nil then return nil, why end
    return c < 0
end

--- @param a
--- @param b
--- @return boolean, or `nil, reason`. Build metadata does not affect equality.
function M.eq(a, b)
    local c, why = M.compare(a, b)
    if c == nil then return nil, why end
    return c == 0
end

-- Split a range token into its operator and its version.
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
local function writtenComponents(rest)
    local core = rest:match('^[^%-%+]+') or rest
    local n = 0
    for _ in core:gmatch('%d+') do
        n = n + 1
    end
    return n
end

-- The bound a PARTIAL upper comparator really means: the last component written, bumped
local function bumpedUpper(parsed, written)
    if written <= 1 then
        return { major = parsed.major + 1, minor = 0, patch = 0 }
    end
    return { major = parsed.major, minor = parsed.minor + 1, patch = 0 }
end

-- Expand one range token into the one or two inclusive/exclusive bounds it means.
local function boundsFor(token)
    local op, rest = splitOperator(token)
    if rest == nil or rest == '' then
        return nil, ('comparator %q has no version'):format(token)
    end

    -- Wildcards: '*', 'x', '1.x', '1.2.*', '1.2.3.x'.
    local wildcardAt = rest:find('[xX*]')
    if wildcardAt then
        if op ~= '=' then
            return nil, ('wildcard %q cannot carry the %q operator'):format(token, op)
        end
        local prefix = rest:sub(1, wildcardAt - 1):gsub('%.$', '')
        if prefix == '' then
            -- Bare '*' or 'x': any release at all.
            return { { op = '>=', v = { major = 0, minor = 0, patch = 0 } } }
        end
        -- '1.x' and '1.2.x' both have to work, so the prefix is a dot-separated list of
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

    local parsed, why = M.parse(rest)
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
if op == '<=' or op == '>' then
    local written = writtenComponents(rest)
    if written < 3 then
        return { { op = op == '<=' and '<' or '>=', v = bumpedUpper(parsed, written) } }
    end
end

if op == '~' then
        -- ~1 is >=1.0.0 <2.0.0; ~1.2 is >=1.2.0 <1.3.0; ~1.2.3 is >=1.2.3 <1.3.0.
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
local function satisfiesAlternative(target, text, includePrerelease)
    local tokens = {}
    for token in text:gmatch('%S+') do
        tokens[#tokens + 1] = token
    end
    if #tokens == 0 then
        -- An empty alternative in the MIDDLE of a range -- '^1.0.0 || || ^3.0.0' --
        return true
    end

    -- THE PRERELEASE RULE. A version carrying a prerelease is only eligible inside an
    if target.prerelease and not includePrerelease then
        local eligible = false
        for _, token in ipairs(tokens) do
            -- Strip the operator before looking for a tag, or the '-' inside
            local body = select(2, splitOperator(token))
            local core, tag = body:match('^([%d%.]+)%-(.+)$')
            if tag and tag ~= '' then
                local c = M.parse(core)
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

    -- Bounds are collected first so that a malformed comparator is reported even when
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
        local c, why = M.compare(target, b.v)
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
--- @param version
--- @param range
--- @param opts
--- @return boolean, or `nil, reason` when the range or the version is
function M.satisfies(version, range, opts)
    opts = opts or {}
    local includePrerelease = opts.includePrerelease == true
    local target, why = M.parse(version)
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

-- the version that gets the comparison backwards and silently returns the OLDEST match.
--- The highest version in a list that satisfies `range`, or nil.
--- @param candidates
--- @param range
--- @param opts
--- @return the version string as it appeared in the list, or `nil` when
function M.best(candidates, range, opts)
    if type(candidates) ~= 'table' then
        return nil, ('candidates must be a table, got %s'):format(type(candidates))
    end
    local bestRaw, bestParsed
    for i = 1, #candidates do
        local ok, why = M.satisfies(candidates[i], range, opts)
        if ok == nil then
            return nil, why
        end
        if ok then
            local parsed = M.parse(candidates[i])
            if bestParsed == nil or M.compare(parsed, bestParsed) > 0 then
                bestParsed, bestRaw = parsed, candidates[i]
            end
        end
    end
    return bestRaw
end

-- A MODULE, NOT A GLOBAL.
if ... ~= 'cis_require' then
    CisSemver = M
end

return M
