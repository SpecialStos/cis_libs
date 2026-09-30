-- Type, range and shape checking, plus a small schema validator.
--
-- PURE, no natives, no module state, no dependencies. Safe to `shared_script`
-- for a private copy (COMPATIBILITY.md §10.2).
--
-- EVERY checker here returns `true` on success and `false, '<reason>'` on
-- failure. That is the library's refusal convention (DOCUMENTATION.md §0.6): a
-- caller on the other side of an exports boundary cannot read cis_libs'
-- console, so a refusal has to carry its own explanation. Nothing raises.
-- The reason is diagnostic text, not a contract -- branch on the boolean.
--
-- The reason strings always name the FIELD (from opts.name) and what arrived
-- instead, because "invalid value" at 3am is useless and
-- "'UpdateInterval must be a number, got string'" is not.
--
-- NO COERCION, deliberately. A validator that turns the string "5" into the
-- number 5 is not validating, it is hiding the bug one layer down, and the
-- value that reaches the consumer is now something nobody typed. Config
-- parsing is the one place where "be helpful" and "be wrong" look identical;
-- this file is strict on purpose.

CisValidate = {}

-- math.type is Lua 5.3+. A FiveM client runs LuaJIT and does not have it, so
-- the integer test falls back to "has no fractional part".
local HAS_MATH_TYPE = type(math.type) == 'function'

local function typeName(v)
    local t = type(v)
    if t == 'number' and HAS_MATH_TYPE and math.type(v) == 'integer' then
        -- Reported as 'integer' because that is what the operator will have to
        -- change it to, and 'number' next to a rejected 5.0 is confusing.
        return 'integer'
    end
    return t
end

local function nameOf(opts)
    return (opts and opts.name) or 'value'
end

local function missing(name)
    return ('%s is missing'):format(name)
end

local function wrongType(name, want, got)
    return ('%s must be a %s, got %s'):format(name, want, got)
end

--- Whether a number has no fractional part.
---
--- 5.0 IS an integer. In Lua 5.3+ it has math.type 'float', and refusing it
--- would break every value that arrived through JSON, because a JSON `5.0`
--- decodes to a float on this side of the boundary. The wire format does not
--- distinguish them and neither should a config check.
function CisValidate.isInteger(v)
    if type(v) ~= 'number' then
        return false
    end
    -- NaN fails this too, which is the right answer: NaN is not an integer.
    return v == math.floor(v)
end

--- Whether a number is finite. NaN and +/-inf are rejected.
---
--- This exists because range checks silently accept NaN: every comparison
--- against NaN is false, so `n >= 0 and n <= 10` is FALSE for a NaN and the
--- value then reaches arithmetic that poisons everything downstream. The one
--- place it usually shows up is `tonumber('')`, which is nil, and
--- `0/0`, which is not.
function CisValidate.isFinite(v)
    if type(v) ~= 'number' then
        return false
    end
    return v == v and v ~= math.huge and v ~= -math.huge
end

--- Check a number.
---
--- opts.min, opts.max  inclusive bounds, either may be omitted
--- opts.integer       require no fractional part
--- opts.name          used in the reason; defaults to 'value'
---
--- @return `true`, or `false, reason`. nil is reported as MISSING rather than
---   as the wrong type -- for a config field those are different mistakes.
function CisValidate.number(v, opts)
    opts = opts or {}
    local name = nameOf(opts)
    if v == nil then
        return false, missing(name)
    end
    if type(v) ~= 'number' then
        return false, wrongType(name, 'number', typeName(v))
    end
    if not CisValidate.isFinite(v) then
        return false, ('%s must be a finite number'):format(name)
    end
    if opts.integer and v ~= math.floor(v) then
        return false, ('%s must be a whole number, got %s'):format(name, tostring(v))
    end
    if opts.min ~= nil and v < opts.min then
        return false, ('%s must be at least %s, got %s'):format(name, tostring(opts.min), tostring(v))
    end
    if opts.max ~= nil and v > opts.max then
        return false, ('%s must be at most %s, got %s'):format(name, tostring(opts.max), tostring(v))
    end
    return true
end

--- Check that a value has no fractional part. Returns `true` for 5 as well as
--- for 5.0 -- see the note on CisValidate.isInteger for why a float that has
--- no fractional part still counts.
function CisValidate.integer(v, opts)
    opts = opts or {}
    -- A fresh table rather than mutating the caller's: adding `integer = true`
    -- to the opts the caller passed would be a side effect on a table they may
    -- be reusing for the next field in a loop.
    return CisValidate.number(v, {
        min = opts.min, max = opts.max, name = opts.name, integer = true,
    })
end

--- Check a string.
---
--- opts.min, opts.max  inclusive LENGTH bounds, in bytes
--- opts.pattern        a Lua pattern the string must match
--- opts.nonEmpty       shorthand for min = 1; wins over opts.min
--- opts.trim           require that s == collapse(s), i.e. no stray whitespace
--- opts.oneOf          a list of exact accepted values
--- opts.ignoreCase     compare oneOf case-insensitively and keep the given casing
--- opts.name           used in the reason
---
--- @return `true`, or `false, reason`.
function CisValidate.string(v, opts)
    opts = opts or {}
    local name = nameOf(opts)
    if v == nil then
        return false, missing(name)
    end
    if type(v) ~= 'string' then
        return false, wrongType(name, 'string', typeName(v))
    end
    local len = #v
    if opts.nonEmpty and len < 1 then
        return false, ('%s must not be empty'):format(name)
    end
    if opts.min ~= nil and len < opts.min then
        return false, ('%s must be at least %d characters, got %d'):format(name, opts.min, len)
    end
    if opts.max ~= nil and len > opts.max then
        return false, ('%s must be at most %d characters, got %d'):format(name, opts.max, len)
    end
    if opts.oneOf then
        local found = false
        for i = 1, #opts.oneOf do
            local candidate = opts.oneOf[i]
            if type(candidate) == 'string' then
                if opts.ignoreCase then
                    if candidate:lower() == v:lower() then found = true break end
                elseif candidate == v then
                    found = true
                    break
                end
            else
                return false, ('%s: oneOf must hold only strings'):format(name)
            end
        end
        if not found then
            return false, ('%s must be one of [%s], got %q'):format(
                name, table.concat(opts.oneOf, ', '), v)
        end
    end
    if opts.pattern then
        local ok, err = pcall(string.find, v, opts.pattern)
        -- A malformed pattern is the CALLER's bug and must surface: silently
        -- treating it as "did not match" turns a typo in a schema into a field
        -- that can never be set.
        if not ok then
            error(('CisValidate.string: bad pattern for %s: %s'):format(name, tostring(err)), 0)
        end
        if not err then
            return false, ('%s must match %q, got %q'):format(name, tostring(opts.pattern), v)
        end
    end
    if opts.trim then
        -- Local, not CisString.collapse: this file has no dependency on any
        -- other module in this directory, so a consumer can shared_script
        -- validate.lua alone and get a working checker.
        if v:find('^%s') or v:find('%s$') or v:find('%s%s') then
            return false, ('%s must not have leading, trailing or repeated whitespace'):format(name)
        end
    end
    return true
end

--- Check a boolean. There is no truthy coercion: 1, 'true' and {} all fail,
--- because every silent truthiness conversion in a config file is a bug that
--- ships.
function CisValidate.boolean(v, opts)
    local name = nameOf(opts)
    if v == nil then
        return false, missing(name)
    end
    if type(v) ~= 'boolean' then
        return false, wrongType(name, 'boolean', typeName(v))
    end
    return true
end

-- Shape predicates and the collection walker, declared BEFORE the functions
-- that call them. In Lua an upvalue is resolved lexically, so a `local
-- function` written after its caller would make the caller reach for a GLOBAL
-- of that name -- nil, at runtime, with no syntax error to warn about it.
local function isArrayShape(t)
    local n = 0
    for k in pairs(t) do
        if type(k) ~= 'number' then
            return false
        end
        n = n + 1
    end
    for i = 1, n do
        if t[i] == nil then
            return false
        end
    end
    return true
end

local function isMapShape(t)
    -- An EMPTY table satisfies both shapes. No key contradicts either reading,
    -- and refusing `{}` for a field whose schema says 'map' would make every
    -- optional map field fail until the operator invented a dummy entry for it.
    if next(t) == nil then
        return true
    end
    return not isArrayShape(t)
end

-- Validate every entry of a collection against `spec`.
-- Returns true, or false plus the FIRST failing path. First rather than all,
-- because the entry index of an arbitrary map is noise; schema() is the place
-- that accumulates a full list.
local function shapeOf(t, spec, path)
    -- The path uses the ACTUAL key, never a running counter. pairs() on an
    -- array-shaped table is not guaranteed to walk 1, 2, 3 in order -- it is
    -- not even guaranteed to walk the array part first -- so a counter reports
    -- the wrong index for whichever entry pairs happens to visit first, and
    -- the reason then names an entry that passed.
    for k, v in pairs(t) do
        local childPath = ('%s[%s]'):format(path, tostring(k))
        -- CisValidate.field is looked up on the global at CALL time, so the
        -- forward reference to it here is fine and needs no forward declaration.
        local ok, why = CisValidate.field(v, spec, childPath)
        if not ok then
            return false, why
        end
    end
    return true
end

-- Recursive copy of a plain table. Local, and not CisTable.deepCopy, so that
-- this file can be shared_script'd on its own with nothing beside it.
local function copyTree(v)
    if type(v) ~= 'table' then
        return v
    end
    local out = {}
    for k, child in pairs(v) do
        out[k] = copyTree(child)
    end
    return out
end

--- Check a table, and optionally its SHAPE.
---
--- opts.shape    'array' or 'map'; omit to accept either
--- opts.of       a field spec applied to every entry (see CisValidate.field
---               for the spec format).
--- opts.min, opts.max  entry-count bounds
--- opts.nonEmpty       reject `{}`
--- opts.name
---
--- A table with an __index metatable reports its real storage, not what the
--- metamethod would answer, which is what a check wants.
function CisValidate.tableValue(v, opts)
    opts = opts or {}
    local name = nameOf(opts)
    if v == nil then
        return false, missing(name)
    end
    if type(v) ~= 'table' then
        return false, wrongType(name, 'table', typeName(v))
    end
    if opts.shape == 'array' and not isArrayShape(v) then
        return false, ('%s must be an array (keys 1..n, no holes, no named keys)'):format(name)
    end
    if opts.shape == 'map' and not isMapShape(v) then
        return false, ('%s must be a map (named keys, or an empty table)'):format(name)
    end
    local count = 0
    for _ in pairs(v) do
        count = count + 1
    end
    if opts.nonEmpty and count == 0 then
        return false, ('%s must not be empty'):format(name)
    end
    if opts.min ~= nil and count < opts.min then
        return false, ('%s must have at least %d entries, got %d'):format(name, opts.min, count)
    end
    if opts.max ~= nil and count > opts.max then
        return false, ('%s must have at most %d entries, got %d'):format(name, opts.max, count)
    end
    if opts.of then
        local ok, why = shapeOf(v, opts.of, name)
        if not ok then
            return false, why
        end
    end
    return true
end

--- Validate one value against a field spec. The engine behind schema() and
--- tableValue{of=...}; exported because it is the piece you want when you have
--- one value and a spec rather than a table of them.
---
--- A spec is a table:
---   type       'string' | 'number' | 'integer' | 'boolean' | 'array' | 'map' | 'table' | 'any'
---   required   refuse a nil value (the default for a field with no default)
---   default    the value to use when the field is absent -- only ever
---              CONSUMED by defaults(), never by schema()
---   min, max   range for numbers, length for strings, entries for collections
---   pattern    a Lua pattern a string must match
---   oneOf      a list of exact accepted values (strings or numbers)
---   ignoreCase oneOf comparison, case-insensitive
---   trim       reject leading/trailing/repeated whitespace in a string
---   integer    require a whole number
---   of         a nested spec applied to every entry of an array or map
---   fields     a nested spec table, for type = 'table'
---
--- @return `true`, or `false, reason` where reason carries the full path.
function CisValidate.field(value, spec, path)
    path = path or nameOf(spec)
    if type(spec) ~= 'table' then
        return false, ('%s has no field spec'):format(path)
    end
    if value == nil then
        if spec.required then
            return false, ('%s is required'):format(path)
        end
        return true
    end
    local want = spec.type
    if want == nil or want == 'any' then
        return true
    end
    if want == 'string' then
        local opts = {
            min = spec.min, max = spec.max, pattern = spec.pattern,
            oneOf = spec.oneOf, ignoreCase = spec.ignoreCase, trim = spec.trim,
            name = path,
        }
        local ok, why = CisValidate.string(value, opts)
        if not ok then return false, why end
        return true
    end
    if want == 'number' then
        local ok, why = CisValidate.number(value, {
            min = spec.min, max = spec.max, integer = spec.integer, name = path,
        })
        if not ok then return false, why end
        return true
    end
    if want == 'integer' then
        local ok, why = CisValidate.integer(value, { min = spec.min, max = spec.max, name = path })
        if not ok then return false, why end
        return true
    end
    if want == 'boolean' then
        local ok, why = CisValidate.boolean(value, { name = path })
        if not ok then return false, why end
        return true
    end
    if want == 'table' then
        if type(value) ~= 'table' then
            return false, wrongType(path, 'table', typeName(value))
        end
        if spec.fields then
            local errors = {}
            for field, subSpec in pairs(spec.fields) do
                local ok, why = CisValidate.field(value[field], subSpec,
                    ('%s.%s'):format(path, field))
                if not ok then
                    errors[#errors + 1] = why
                end
            end
            if #errors > 0 then
                return false, table.concat(errors, '; ')
            end
        end
        return true
    end
    if want == 'array' or want == 'map' then
        local wantShape = want == 'array' and isArrayShape or isMapShape
        if type(value) ~= 'table' then
            return false, wrongType(path, want, typeName(value))
        end
        if not wantShape(value) then
            return false, ('%s must be %s (keys %s)'):format(path, want,
                want == 'array' and '1..n, no holes' or 'named, or empty')
        end
        if spec.min ~= nil or spec.max ~= nil or spec.of then
            local opts = { min = spec.min, max = spec.max, name = path }
            local ok, why = CisValidate.tableValue(value, opts)
            if not ok then return false, why end
        end
        if spec.of then
            local ok, why = shapeOf(value, spec.of, path)
            if not ok then
                return false, why
            end
        end
        return true
    end
    return false, ('%s has unknown field type %q'):format(path, tostring(want))
end

--- Validate a whole table against a schema of field specs.
---
--- Reports EVERY failure, not just the first. A config that is wrong in three
--- places should be told about all three: fixing a server one boot at a time is
--- the experience this is meant to remove.
---
--- `opts.strict` refuses keys the schema does not mention. Off by default --
--- an operator's extra key is usually forward-compatible intent, not a bug --
--- and the errors are what says so when it is on.
--- `opts.path` prefixes every reason, so a nested schema reports
--- 'Config.Doorlock.Enabled ...' rather than 'Enabled ...'.
---
--- @return `true` when everything matches, or `false, errors` where `errors` is
---   a list of strings, one per problem, in no particular order (pairs order).
---   Use it as `if not ok then for _, e in ipairs(errors) do print(e) end end`.
function CisValidate.schema(value, schema, opts)
    opts = opts or {}
    if type(schema) ~= 'table' then
        return false, ('schema must be a table, got %s'):format(type(schema))
    end
    if value == nil then
        value = {}
    end
    if type(value) ~= 'table' then
        return false, { wrongType(opts.path or 'config', 'table', typeName(value)) }
    end
    local prefix = opts.path
    local function at(field)
        return prefix and ('%s.%s'):format(prefix, field) or tostring(field)
    end
    local errors = {}
    for field, spec in pairs(schema) do
        local ok, why = CisValidate.field(value[field], spec, at(field))
        if not ok then
            errors[#errors + 1] = why
        end
    end
    if opts.strict then
        for key in pairs(value) do
            if schema[key] == nil then
                errors[#errors + 1] = ('%s is not a known field'):format(at(tostring(key)))
            end
        end
    end
    if #errors > 0 then
        return false, errors
    end
    return true
end

--- Apply one FIELD SPEC's defaults to one value. The inner half of defaults().
---
--- It exists because a field spec and a schema are different shapes and the
--- two cannot be conflated: a schema is { field = spec }, and `of` hands you a
--- single spec to apply to each element of a list. Passing a spec where a
--- schema is expected does not error -- it silently fills nothing, because the
--- spec's own keys (`type`, `of`) are not fields. That failure is invisible,
--- which is why the walk has its own function.
---
--- The result is a fresh table whenever a table went in, so a default applied
--- deep in the tree can never write back into the caller's input.
local function applyFieldDefaults(value, spec)
    if type(spec) ~= 'table' then
        return type(value) == 'table' and copyTree(value) or value
    end
    local out = (type(value) == 'table') and copyTree(value) or value
    if out == nil and spec.default ~= nil then
        out = copyTree(spec.default)
    end
    -- A nested spec that declares `fields` gets its container created even
    -- with no default of its own. Without this,
    -- { Door = { type='table', fields={ Dist={default=2.0} } } } does not
    -- produce cfg.Door.Dist for a config that omits Door entirely, and the
    -- default the author wrote is silently never applied.
    --
    -- An `of` spec (a list) is NOT created this way. For a list, absent and
    -- empty are genuinely different facts a caller can act on
    -- (#cfg.Items == 0), and inventing one answers a question nobody asked.
    if out == nil and spec.fields then
        out = {}
    end
    if type(out) == 'table' then
        if spec.fields then
            local filled = CisValidate.defaults(out, spec.fields)
            if not filled then return nil end
            out = filled
        end
        if spec.of then
            local nested = {}
            -- The KEY is used, never a running counter. pairs() does not
            -- guarantee an array-shaped table is visited in index order --
            -- under fengari it demonstrably is not -- so a counter renumbers
            -- the caller's list according to hash layout, which silently
            -- reorders their config.
            for k, v in pairs(out) do
                nested[k] = applyFieldDefaults(v, spec.of)
            end
            out = nested
        end
    end
    return out
end

--- Fill a table's missing fields from a schema's `default` values.
---
--- Returns a NEW table; `value` is not modified, and no table in the result
--- aliases one in the input. Nested `fields` defaults are filled recursively and
--- `of` defaults are applied per element, so a config that supplies one element
--- of a list still gets every element complete.
---
--- It does NOT validate -- composition is the caller's choice, and doing both
--- here would mean defaults() could refuse for a reason schema() has not
--- checked yet:
---
---     local ok, errors = CisValidate.schema(cfg, S)
---     if not ok then ... return end
---     local filled, err = CisValidate.defaults(cfg, S)
---
--- An explicit `false` is a value, not an absence, and survives. Only a nil (or
--- an absent key) takes the default -- a boolean config that always reverts
--- because `x = nil` was written instead of `x = false` is a classic.
---
--- @return the filled table, or `nil, reason` for a non-table value or schema.
function CisValidate.defaults(value, schema)
    if type(value) ~= 'table' then
        return nil, ('value must be a table, got %s'):format(type(value))
    end
    if type(schema) ~= 'table' then
        return nil, ('schema must be a table, got %s'):format(type(schema))
    end
    local out = {}
    -- Supplied values first, so the second pass can tell "absent" from
    -- "supplied and legitimately nil-ish".
    for k, v in pairs(value) do
        out[k] = applyFieldDefaults(v, schema[k])
    end
    for key, spec in pairs(schema) do
        if type(spec) == 'table' and out[key] == nil then
            out[key] = applyFieldDefaults(nil, spec)
        end
    end
    return out
end

--- Constrain a number to a range.
---
--- Differs from validate-then-use on purpose: clamp NEVER refuses a number that
--- is in range and never raises on one that is not. It is the function for a
--- value you have to accept whatever it is -- a wheel spin, a coordinate --
--- where refusing would drop the input entirely.
---
--- @return the clamped number, or `nil, reason` for a non-number, a NaN, or an
---   inverted range. An inverted range is refused rather than silently
---   swapped: min=5, max=1 is a caller's bug and the swap would hide it.
function CisValidate.clamp(v, min, max)
    if type(v) ~= 'number' then
        return nil, ('value must be a number, got %s'):format(typeName(v))
    end
    if not CisValidate.isFinite(v) then
        return nil, 'value must be a finite number'
    end
    if min == nil and max == nil then
        return v
    end
    if min ~= nil and max ~= nil and min > max then
        return nil, ('min %s is greater than max %s'):format(tostring(min), tostring(max))
    end
    if min ~= nil and v < min then
        return min
    end
    if max ~= nil and v > max then
        return max
    end
    return v
end
