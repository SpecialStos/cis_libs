-- Semantic versions: SemVer 2.0.0 parsing and precedence, and npm-style ranges.
--
-- STRICT BY DEFAULT. `parse` accepts exactly the grammar of semver.org 2.0.0:
-- MAJOR.MINOR.PATCH, numeric identifiers without leading zeros, an optional
-- `-prerelease` of non-empty dot-separated [0-9A-Za-z-] identifiers, and an
-- optional `+build` of the same. 'v1.2.3', ' 1.2.3', '1.2', '1..2' and
-- '1.2.3-' are not versions, and are refused with a reason.
--
-- `{ loose = true }` is the explicit escape hatch for versions read from
-- places that do not follow the spec (a manifest someone typed by hand): it
-- trims whitespace, drops leading 'v' / '=' characters, allows leading zeros,
-- and fills a missing minor or patch with 0. A loose parse still refuses
-- empty components and empty identifiers -- '1..2' is not a version in any
-- mode.
--
-- RANGES follow node-semver (npm) for every operator supported here:
-- primitives (<, <=, >, >=, =), X-ranges and partials (*, x, 1, 1.x, 1.2.*),
-- tilde (~, ~>), caret (^), hyphen ranges ('1.2 - 2.3.4'), AND by whitespace
-- and OR by '||'. The prerelease rule is npm's too: a version with a
-- prerelease only satisfies a comparator set that names a prerelease on the
-- same MAJOR.MINOR.PATCH, unless `includePrerelease` is set. The test suite
-- checks these against a table of results produced by node-semver itself.

local M = {}

-- 2^53 - 1: the largest integer a double holds exactly, and node-semver's
-- MAX_SAFE_INTEGER limit for a numeric component.
local MAX_SAFE = 9007199254740991

-- A numeric component as text, validated. Strict: no leading zero.
local function numeric(text, loose, what)
    if text == nil or text == '' then
        return nil, ('%s is empty'):format(what)
    end
    if not text:match('^%d+$') then
        return nil, ('%s %q is not a number'):format(what, text)
    end
    if not loose and #text > 1 and text:sub(1, 1) == '0' then
        return nil, ('%s %q has a leading zero'):format(what, text)
    end
    local digits = text:gsub('^0+(%d)', '%1')
    if #digits > 16 or tonumber(digits) > MAX_SAFE then
        return nil, ('%s %q is larger than 2^53 - 1, the largest integer a double holds exactly')
            :format(what, text)
    end
    return tonumber(digits)
end

-- Dot-separated identifiers. Prerelease identifiers that are numeric must not
-- have a leading zero (SemVer 2.0.0 item 9); build identifiers may (item 10).
local function identifiers(text, what, numericRule)
    if text == '' then
        return nil, ('%s is empty'):format(what)
    end
    local ids = {}
    -- `(.-)%.` over text .. '.' yields EVERY piece, including empty ones, which
    -- is the point: '1.2.3-a..b' has an empty identifier and must be refused.
    for piece in (text .. '.'):gmatch('(.-)%.') do
        if piece == '' then
            return nil, ('%s %q has an empty identifier'):format(what, text)
        end
        if piece:find('[^0-9A-Za-z%-]') then
            return nil, ('%s identifier %q may only use [0-9A-Za-z-]'):format(what, piece)
        end
        if numericRule and piece:match('^%d+$') and #piece > 1 and piece:sub(1, 1) == '0' then
            return nil, ('%s identifier %q has a leading zero'):format(what, piece)
        end
        ids[#ids + 1] = piece
    end
    return ids
end

local function format(major, minor, patch, prerelease, build)
    return ('%.0f.%.0f.%.0f%s%s'):format(major, minor, patch,
        prerelease and ('-' .. prerelease) or '',
        build and ('+' .. build) or '')
end

local function isWhole(n)
    return type(n) == 'number' and n == n and n >= 0 and n <= MAX_SAFE and n % 1 == 0
end

-- Parse one version string. `loose` as described in the header.
local function parseString(v, loose)
    local s = v
    if loose then
        s = s:gsub('^%s+', ''):gsub('%s+$', ''):gsub('^[v=%s]+', '')
    end
    if s == '' then
        return nil, 'version is empty'
    end

    local build
    local plusAt = s:find('+', 1, true)
    if plusAt then
        build = s:sub(plusAt + 1)
        s = s:sub(1, plusAt - 1)
        local ok, why = identifiers(build, 'build metadata', false)
        if not ok then
            return nil, why
        end
    end
    local prerelease
    local dashAt = s:find('-', 1, true)
    if dashAt then
        prerelease = s:sub(dashAt + 1)
        s = s:sub(1, dashAt - 1)
    end
    local preIds = {}
    if prerelease then
        local ids, why = identifiers(prerelease, 'prerelease', true)
        if not ids then
            return nil, why
        end
        preIds = ids
    end

    local core = {}
    for piece in (s .. '.'):gmatch('(.-)%.') do
        core[#core + 1] = piece
    end
    if #core > 3 then
        return nil, ('version %q has %d numeric parts; a version has exactly 3'):format(v, #core)
    end
    if #core < 3 and not loose then
        return nil, ('version %q has %d numeric part%s; a version has exactly 3 '
            .. '(use { loose = true } to fill the rest with 0)'):format(v, #core, #core == 1 and '' or 's')
    end
    local names = { 'major', 'minor', 'patch' }
    local nums = {}
    for i = 1, 3 do
        if core[i] == nil then
            nums[i] = 0
        else
            local n, why = numeric(core[i], loose, names[i])
            if not n then
                return nil, ('version %q: %s'):format(v, why)
            end
            nums[i] = n
        end
    end
    return {
        major = nums[1], minor = nums[2], patch = nums[3],
        prerelease = prerelease, build = build,
        prereleaseIds = preIds,
        raw = v,
        normalized = format(nums[1], nums[2], nums[3], prerelease, build),
    }
end

--- Parse a version into its parts.
---
--- A TABLE is accepted only when it is shaped like a parsed version -- whole,
--- non-negative major/minor/patch, and prerelease/build that are themselves
--- valid -- and the answer is always a fresh, normalised table. A table used
--- to be handed back unvalidated, so `compare({}, '1.0.0')` compared nil.
--- @param v string|table  the version, or a table shaped like parse's result
--- @param opts table|nil  { loose = boolean }
--- @return table|nil parsed  { major, minor, patch, prerelease, build, prereleaseIds, raw, normalized }
--- @return string|nil reason  why it is not a version
function M.parse(v, opts)
    local loose = type(opts) == 'table' and opts.loose == true
    if type(v) == 'table' then
        if not (isWhole(v.major) and isWhole(v.minor) and isWhole(v.patch)) then
            return nil, 'version table needs whole, non-negative major, minor and patch numbers'
        end
        if v.prerelease ~= nil and type(v.prerelease) ~= 'string' then
            return nil, 'version table prerelease must be a string or nil'
        end
        if v.build ~= nil and type(v.build) ~= 'string' then
            return nil, 'version table build must be a string or nil'
        end
        return parseString(format(v.major, v.minor, v.patch, v.prerelease, v.build), false)
    end
    if type(v) ~= 'string' then
        return nil, ('version must be a string, got %s'):format(type(v))
    end
    return parseString(v, loose)
end

-- Compare two numeric identifiers written in decimal without leading zeros:
-- longer is larger, and equal lengths compare as text. Exact at any size,
-- which tonumber is not -- and tonumber also reads '0x1' and '1e3' as numbers.
local function compareDigits(a, b)
    if #a ~= #b then
        return #a < #b and -1 or 1
    end
    if a == b then return 0 end
    return a < b and -1 or 1
end

-- SemVer 2.0.0 item 11: identifier by identifier; numeric identifiers compare
-- numerically and below alphanumeric ones; a longer list wins a shared prefix;
-- a version WITHOUT a prerelease is above any version with one.
local function comparePrerelease(a, b)
    local na, nb = #a, #b
    if na == 0 and nb == 0 then return 0 end
    if na == 0 then return 1 end
    if nb == 0 then return -1 end
    for i = 1, math.max(na, nb) do
        local x, y = a[i], b[i]
        if x == nil then return -1 end
        if y == nil then return 1 end
        local xn, yn = x:match('^%d+$') ~= nil, y:match('^%d+$') ~= nil
        if xn and yn then
            local c = compareDigits(x, y)
            if c ~= 0 then return c end
        elseif xn then
            return -1
        elseif yn then
            return 1
        elseif x ~= y then
            return x < y and -1 or 1
        end
    end
    return 0
end

local function compareParsed(pa, pb)
    if pa.major ~= pb.major then
        return pa.major < pb.major and -1 or 1
    end
    if pa.minor ~= pb.minor then
        return pa.minor < pb.minor and -1 or 1
    end
    if pa.patch ~= pb.patch then
        return pa.patch < pb.patch and -1 or 1
    end
    return comparePrerelease(pa.prereleaseIds or {}, pb.prereleaseIds or {})
end

--- Compare two versions by SemVer precedence. Build metadata is ignored.
--- @param a string|table
--- @param b string|table
--- @param opts table|nil  { loose = boolean }, applied to both
--- @return integer|nil order  -1 if a < b, 0 if equal, 1 if a > b
--- @return string|nil reason  when either side is not a version
function M.compare(a, b, opts)
    local pa, whyA = M.parse(a, opts)
    if not pa then
        return nil, whyA
    end
    local pb, whyB = M.parse(b, opts)
    if not pb then
        return nil, whyB
    end
    return compareParsed(pa, pb)
end

--- @param a string|table
--- @param b string|table
--- @param opts table|nil  { loose = boolean }
--- @return boolean|nil  a >= b, or nil and a reason (see compare)
--- @return string|nil
function M.gte(a, b, opts)
    local c, why = M.compare(a, b, opts)
    if c == nil then return nil, why end
    return c >= 0
end

--- @param a string|table
--- @param b string|table
--- @param opts table|nil  { loose = boolean }
--- @return boolean|nil  a < b, or nil and a reason
--- @return string|nil
function M.lt(a, b, opts)
    local c, why = M.compare(a, b, opts)
    if c == nil then return nil, why end
    return c < 0
end

--- @param a string|table
--- @param b string|table
--- @param opts table|nil  { loose = boolean }
--- @return boolean|nil  equal precedence (build metadata does not count), or nil and a reason
--- @return string|nil
function M.eq(a, b, opts)
    local c, why = M.compare(a, b, opts)
    if c == nil then return nil, why end
    return c == 0
end

-- ------------------------------------------------------------------ ranges
--
-- A range is parsed into sets of COMPARATORS, each { op, version } or the
-- ANY comparator, exactly as node-semver desugars it. The functions below are
-- transliterations of node-semver's replaceTilde / replaceCaret /
-- replaceXRange / replaceHyphen, working on parts instead of strings.

local ANY = { any = true }

-- A partial version: 'x', '1', '1.x', '1.2', '1.2.3', '1.2.3-pre+b', with
-- optional leading 'v' / '='. Missing and wildcard parts are nil.
local function parsePartial(text)
    local s = text:gsub('^[v=]+', '')
    -- An operator with nothing after it ('>=', '~', '^', 'v') is not a range.
    if s == '' then
        return nil
    end
    local build
    local plusAt = s:find('+', 1, true)
    if plusAt then
        build = s:sub(plusAt + 1)
        s = s:sub(1, plusAt - 1)
        if not identifiers(build, 'build metadata', false) then
            return nil
        end
    end
    local pre
    local dashAt = s:find('-', 1, true)
    if dashAt then
        pre = s:sub(dashAt + 1)
        s = s:sub(1, dashAt - 1)
        if not identifiers(pre, 'prerelease', true) then
            return nil
        end
    end
    local parts = {}
    for piece in (s .. '.'):gmatch('(.-)%.') do
        parts[#parts + 1] = piece
    end
    if #parts > 3 then
        return nil
    end
    -- A prerelease or build only follows a full MAJOR.MINOR.PATCH.
    if (pre or build) and #parts ~= 3 then
        return nil
    end
    local out = { pre = pre }
    local names = { 'M', 'm', 'p' }
    for i = 1, #parts do
        local piece = parts[i]
        if piece == 'x' or piece == 'X' or piece == '*' then
            out[names[i]] = nil
        else
            local n = numeric(piece, false, 'part')
            if not n then
                return nil
            end
            out[names[i]] = n
        end
    end
    -- isX in node-semver: a missing part is a wildcard, and every part after
    -- a wildcard is ignored.
    out.xM = out.M == nil
    out.xm = out.xM or out.m == nil
    out.xp = out.xm or out.p == nil
    return out
end

local function preIdsOf(pre)
    if pre == nil then return {} end
    local ids = {}
    for piece in (pre .. '.'):gmatch('(.-)%.') do ids[#ids + 1] = piece end
    return ids
end

-- One comparator: op ('<', '<=', '>', '>=', '=') against M.m.p[-pre].
local function cmp(op, M_, m, p, pre)
    return { op = op, v = { major = M_, minor = m, patch = p, prerelease = pre, prereleaseIds = preIdsOf(pre) } }
end

local function caret(x, incPre)
    local z = incPre and '0' or nil
    if x.xM then return { ANY } end
    if x.xm then
        return { cmp('>=', x.M, 0, 0, z), cmp('<', x.M + 1, 0, 0, '0') }
    end
    if x.xp then
        if x.M == 0 then
            return { cmp('>=', 0, x.m, 0, z), cmp('<', 0, x.m + 1, 0, '0') }
        end
        return { cmp('>=', x.M, x.m, 0, z), cmp('<', x.M + 1, 0, 0, '0') }
    end
    local lowPre = x.pre or (x.M == 0 and z or nil)
    if x.M == 0 then
        if x.m == 0 then
            return { cmp('>=', 0, 0, x.p, lowPre), cmp('<', 0, 0, x.p + 1, '0') }
        end
        return { cmp('>=', 0, x.m, x.p, lowPre), cmp('<', 0, x.m + 1, 0, '0') }
    end
    return { cmp('>=', x.M, x.m, x.p, x.pre), cmp('<', x.M + 1, 0, 0, '0') }
end

local function tilde(x)
    if x.xM then return { ANY } end
    if x.xm then
        return { cmp('>=', x.M, 0, 0), cmp('<', x.M + 1, 0, 0, '0') }
    end
    if x.xp then
        return { cmp('>=', x.M, x.m, 0), cmp('<', x.M, x.m + 1, 0, '0') }
    end
    return { cmp('>=', x.M, x.m, x.p, x.pre), cmp('<', x.M, x.m + 1, 0, '0') }
end

-- A primitive operator with a possibly partial version (replaceXRange).
local function xrange(op, x, incPre)
    if op == '=' and x.xp then op = '' end
    local pr = incPre and '0' or nil
    if x.xM then
        if op == '>' or op == '<' then
            return { cmp('<', 0, 0, 0, '0') }        -- the null set: nothing satisfies it
        end
        return { ANY }
    end
    if op ~= '' and x.xp then
        local M_, m, p = x.M, x.xm and 0 or x.m, 0
        if op == '>' then
            op = '>='
            if x.xm then M_, m = M_ + 1, 0 else m = m + 1 end
        elseif op == '<=' then
            op = '<'
            if x.xm then M_ = M_ + 1 else m = m + 1 end
        end
        if op == '<' then pr = '0' end
        return { cmp(op, M_, m, p, pr) }
    end
    if x.xm then
        return { cmp('>=', x.M, 0, 0, pr), cmp('<', x.M + 1, 0, 0, '0') }
    end
    if x.xp then
        return { cmp('>=', x.M, x.m, 0, pr), cmp('<', x.M, x.m + 1, 0, '0') }
    end
    return { cmp(op == '' and '=' or op, x.M, x.m, x.p, x.pre) }
end

local function hyphen(from, to, incPre)
    local out = {}
    if not from.xM then
        if from.xm then
            out[#out + 1] = cmp('>=', from.M, 0, 0, incPre and '0' or nil)
        elseif from.xp then
            out[#out + 1] = cmp('>=', from.M, from.m, 0, incPre and '0' or nil)
        else
            out[#out + 1] = cmp('>=', from.M, from.m, from.p, from.pre or (incPre and '0' or nil))
        end
    end
    if not to.xM then
        if to.xm then
            out[#out + 1] = cmp('<', to.M + 1, 0, 0, '0')
        elseif to.xp then
            out[#out + 1] = cmp('<', to.M, to.m + 1, 0, '0')
        elseif to.pre then
            out[#out + 1] = cmp('<=', to.M, to.m, to.p, to.pre)
        elseif incPre then
            out[#out + 1] = cmp('<', to.M, to.m, to.p + 1, '0')
        else
            out[#out + 1] = cmp('<=', to.M, to.m, to.p)
        end
    end
    if #out == 0 then
        out[1] = ANY
    end
    return out
end

-- One token: operator plus partial version.
local function comparatorsFor(token, incPre)
    local op, rest
    if token:sub(1, 2) == '~>' then
        op, rest = '~', token:sub(3)
    else
        op, rest = token:match('^([<>]?=?)(.*)$')
        if op == '' then
            local first = token:sub(1, 1)
            if first == '~' or first == '^' then
                op, rest = first, token:sub(2)
            end
        end
    end
    local x = parsePartial(rest)
    if not x then
        return nil, ('comparator %q is not a version, partial version or wildcard'):format(token)
    end
    if op == '^' then return caret(x, incPre) end
    if op == '~' then return tilde(x) end
    return xrange(op, x, incPre)
end

-- One '||' alternative into a list of comparators, or nil and a reason.
local function parseSet(text, incPre)
    text = text:gsub('^%s+', ''):gsub('%s+$', '')
    -- Hyphen range: exactly 'A - B', spaces required around the hyphen.
    local a, b = text:match('^(%S+)%s+%-%s+(%S+)$')
    if a then
        local from, to = parsePartial(a), parsePartial(b)
        if not from or not to then
            return nil, ('hyphen range %q has a side that is not a version'):format(text)
        end
        return hyphen(from, to, incPre)
    end
    -- An operator may be separated from its version by spaces ('>= 1.2.3',
    -- '~ 1.2', '^ 1'); join them first, as node-semver does.
    text = text:gsub('([<>]=?)%s+', '%1'):gsub('(=)%s+', '%1')
        :gsub('~>%s+', '~>'):gsub('~%s+', '~'):gsub('%^%s+', '^')
    local out = {}
    for token in text:gmatch('%S+') do
        local list, why = comparatorsFor(token, incPre)
        if not list then
            return nil, why
        end
        for i = 1, #list do out[#out + 1] = list[i] end
    end
    if #out == 0 then
        out[1] = ANY            -- an empty alternative means any version, as in npm
    end
    return out
end

local function holds(target, c)
    if c.any then
        return true
    end
    local order = compareParsed(target, c.v)
    local op = c.op
    if op == '>=' then return order >= 0 end
    if op == '>' then return order > 0 end
    if op == '<=' then return order <= 0 end
    if op == '<' then return order < 0 end
    return order == 0
end

local function testSet(target, set, incPre)
    for i = 1, #set do
        if not holds(target, set[i]) then
            return false
        end
    end
    -- THE PRERELEASE RULE (npm's testSet). A prerelease only gets in through a
    -- comparator that names a prerelease on the very same MAJOR.MINOR.PATCH,
    -- so '^1.2.3' does not admit 1.3.0-beta by accident.
    if #target.prereleaseIds > 0 and not incPre then
        for i = 1, #set do
            local c = set[i]
            if not c.any and #c.v.prereleaseIds > 0 and c.v.major == target.major
                and c.v.minor == target.minor and c.v.patch == target.patch then
                return true
            end
        end
        return false
    end
    return true
end

--- Does `version` satisfy a range expression?
--- @param version string|table
--- @param range string  npm range syntax; '' and '*' mean any release
--- @param opts table|nil  { includePrerelease = boolean, loose = boolean (for the version) }
--- @return boolean|nil ok  nil when the version or the range is malformed
--- @return string|nil reason
function M.satisfies(version, range, opts)
    opts = opts or {}
    local incPre = opts.includePrerelease == true
    local target, why = M.parse(version, { loose = opts.loose == true })
    if not target then
        return nil, why
    end
    if type(range) ~= 'string' then
        return nil, ('range must be a string, got %s'):format(type(range))
    end
    -- Every alternative is parsed before any is tested, so a malformed one is
    -- reported even when an earlier alternative would have matched.
    local sets = {}
    for alt in (range .. '||'):gmatch('(.-)||') do
        local set, problem = parseSet(alt, incPre)
        if not set then
            return nil, problem
        end
        sets[#sets + 1] = set
    end
    for i = 1, #sets do
        if testSet(target, sets[i], incPre) then
            return true
        end
    end
    return false
end

--- The highest version in a list that satisfies `range`.
--- @param candidates table  array of version strings (or parsed tables)
--- @param range string
--- @param opts table|nil  as satisfies
--- @return any|nil  the candidate exactly as it appeared in the list, or nil when none match
--- @return string|nil reason  when the list, the range or a candidate is malformed
function M.best(candidates, range, opts)
    if type(candidates) ~= 'table' then
        return nil, ('candidates must be a table, got %s'):format(type(candidates))
    end
    local loose = { loose = type(opts) == 'table' and opts.loose == true }
    local bestRaw, bestParsed
    for i = 1, #candidates do
        local ok, why = M.satisfies(candidates[i], range, opts)
        if ok == nil then
            return nil, why
        end
        if ok then
            local parsed = M.parse(candidates[i], loose)
            if bestParsed == nil or compareParsed(parsed, bestParsed) > 0 then
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
