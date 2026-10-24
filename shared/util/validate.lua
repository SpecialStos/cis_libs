-- Type, range and shape checking, plus a small schema validator.

local M = {}

-- math.type is Lua 5.3+. FiveM runs CfxLua 5.4 on both realms, so it is there
-- in production; it is feature-detected for the other Lua hosts this file runs
-- on (test interpreters, tooling).
local HAS_MATH_TYPE = type(math.type) == 'function'

local function typeName(v)
    local t = type(v)
    if t == 'number' and HAS_MATH_TYPE and math.type(v) == 'integer' then
        -- Reported as 'integer' because that is what the operator will have to change
        return 'integer'
    end
    return t
end

-- A bound as text. `%d` raises on 2.5 ("number has no integer representation"),
-- and a bound is the caller's number, not ours to assume whole.
local function num(n)
    if type(n) == 'number' and n % 1 == 0 and n > -1e15 and n < 1e15 then
        return ('%.0f'):format(n)
    end
    return tostring(n)
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
---@param v any
---@return boolean  false for NaN and for infinity
function M.isInteger(v)
    if type(v) ~= 'number' then
        return false
    end
    -- Infinity is not an integer, though math.floor(inf) == inf says otherwise.
    if v == math.huge or v == -math.huge then
        return false
    end
    -- NaN fails this too, which is the right answer: NaN is not an integer.
    return v == math.floor(v)
end

--- Whether a number is finite. NaN and +/-inf are rejected.
---@param v any
---@return boolean  true only for a real number: NaN and +/-infinity are rejected
function M.isFinite(v)
    if type(v) ~= 'number' then
        return false
    end
    return v == v and v ~= math.huge and v ~= -math.huge
end

--- Check a number. opts.min, opts.max inclusive bounds, either may be omitted
---@param v any
---@param opts? table  { min, max, integer, name }
---@return boolean
---@return string|nil  why
function M.number(v, opts)
    opts = opts or {}
    local name = nameOf(opts)
    if v == nil then
        return false, missing(name)
    end
    if type(v) ~= 'number' then
        return false, wrongType(name, 'number', typeName(v))
    end
    if not M.isFinite(v) then
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

--- Check that a value has no fractional part.
---@param v any
---@param opts? table  { min, max, name }
---@return boolean
---@return string|nil  why
function M.integer(v, opts)
    opts = opts or {}
    -- A fresh table rather than mutating the caller's: adding `integer = true` to the
    return M.number(v, {
        min = opts.min, max = opts.max, name = opts.name, integer = true,
    })
end

--- Check a string. opts.min, opts.max inclusive LENGTH bounds, in bytes opts.pattern a
---@param v any
---@param opts? table  { min, max, nonEmpty, oneOf, ignoreCase, pattern, trim, name }
---@return boolean
---@return string|nil  why
function M.string(v, opts)
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
        return false, ('%s must be at least %s characters, got %d'):format(name, num(opts.min), len)
    end
    if opts.max ~= nil and len > opts.max then
        return false, ('%s must be at most %s characters, got %d'):format(name, num(opts.max), len)
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
        -- A malformed pattern is the CALLER's bug and must surface: silently treating
        if not ok then
            error(('CisValidate.string: bad pattern for %s: %s'):format(name, tostring(err)), 0)
        end
        if not err then
            return false, ('%s must match %q, got %q'):format(name, tostring(opts.pattern), v)
        end
    end
    if opts.trim then
        -- Local, not CisString.collapse: this file has no dependency on any other
        if v:find('^%s') or v:find('%s$') or v:find('%s%s') then
            return false, ('%s must not have leading, trailing or repeated whitespace'):format(name)
        end
    end
    return true
end

--- Check a boolean. There is no truthy coercion: 1, 'true' and {} all fail, because
---@param v any
---@param opts? table  { name }
---@return boolean
---@return string|nil  why
function M.boolean(v, opts)
    local name = nameOf(opts)
    if v == nil then
        return false, missing(name)
    end
    if type(v) ~= 'boolean' then
        return false, wrongType(name, 'boolean', typeName(v))
    end
    return true
end

-- Shape predicates and the collection walker, declared BEFORE the functions that call
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
    -- An EMPTY table satisfies both shapes.
    if next(t) == nil then
        return true
    end
    return not isArrayShape(t)
end

-- Validate every entry of a collection against `spec`.
local function shapeOf(t, spec, path)
    -- The path uses the ACTUAL key, never a running counter.
    for k, v in pairs(t) do
        local childPath = ('%s[%s]'):format(path, tostring(k))
        -- CisValidate.field is looked up on the global at CALL time, so the forward
        local ok, why = M.field(v, spec, childPath)
        if not ok then
            return false, why
        end
    end
    return true
end

-- Nesting past this is refused by defaults() rather than copied.
local MAX_COPY_DEPTH = 64

-- Why a table cannot be copied: a cycle, or nesting past MAX_COPY_DEPTH. The
-- recursion is bounded by that depth.
local function treeProblem(v)
    local onPath = {}
    local function walk(t, depth)
        if onPath[t] then
            return 'value has a cycle'
        end
        if depth > MAX_COPY_DEPTH then
            return ('value is nested deeper than %d'):format(MAX_COPY_DEPTH)
        end
        onPath[t] = true
        for _, child in next, t do
            if type(child) == 'table' then
                local why = walk(child, depth + 1)
                if why then return why end
            end
        end
        onPath[t] = nil
        return nil
    end
    return walk(v, 1)
end

-- Recursive copy of a plain table.
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
---@param v any
---@param opts? table  { shape, nonEmpty, min, max, of, name }
---@return boolean
---@return string|nil  why
function M.tableValue(v, opts)
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
        return false, ('%s must have at least %s entries, got %d'):format(name, num(opts.min), count)
    end
    if opts.max ~= nil and count > opts.max then
        return false, ('%s must have at most %s entries, got %d'):format(name, num(opts.max), count)
    end
    if opts.of then
        local ok, why = shapeOf(v, opts.of, name)
        if not ok then
            return false, why
        end
    end
    return true
end

--- Validate one value against a field spec.
---@param value any
---@param spec table
---@param path? string
---@return boolean
---@return string|nil  why, carrying the full path
function M.field(value, spec, path)
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
            min = spec.min, max = spec.max, nonEmpty = spec.nonEmpty, pattern = spec.pattern,
            oneOf = spec.oneOf, ignoreCase = spec.ignoreCase, trim = spec.trim,
            name = path,
        }
        local ok, why = M.string(value, opts)
        if not ok then return false, why end
        return true
    end
    if want == 'number' then
        local ok, why = M.number(value, {
            min = spec.min, max = spec.max, integer = spec.integer, name = path,
        })
        if not ok then return false, why end
        return true
    end
    if want == 'integer' then
        local ok, why = M.integer(value, { min = spec.min, max = spec.max, name = path })
        if not ok then return false, why end
        return true
    end
    if want == 'boolean' then
        local ok, why = M.boolean(value, { name = path })
        if not ok then return false, why end
        return true
    end
    if want == 'table' then
        if type(value) ~= 'table' then
            return false, wrongType(path, 'table', typeName(value))
        end
        if spec.min ~= nil or spec.max ~= nil or spec.nonEmpty or spec.of then
            local ok, why = M.tableValue(value, {
                min = spec.min, max = spec.max, nonEmpty = spec.nonEmpty, of = spec.of, name = path,
            })
            if not ok then return false, why end
        end
        if spec.fields then
            local errors = {}
            for field, subSpec in pairs(spec.fields) do
                local ok, why = M.field(value[field], subSpec,
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
        if spec.min ~= nil or spec.max ~= nil or spec.nonEmpty or spec.of then
            local opts = { min = spec.min, max = spec.max, nonEmpty = spec.nonEmpty, name = path }
            local ok, why = M.tableValue(value, opts)
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
---@param value table|nil
---@param schema table
---@param opts? table  { strict, path }
---@return boolean
---@return string|string[]|nil  every problem found
function M.schema(value, schema, opts)
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
        local ok, why = M.field(value[field], spec, at(field))
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

local fillDefaults

--- Apply one FIELD SPEC's defaults to one value. Answers the value, or nil and
--- why; `depth` counts nested schemas, so one that contains itself ends.
local function applyFieldDefaults(value, spec, depth)
    if type(spec) ~= 'table' then
        return type(value) == 'table' and copyTree(value) or value
    end
    local out = (type(value) == 'table') and copyTree(value) or value
    if out == nil and spec.default ~= nil then
        -- The DEFAULT is checked like the value: a default that contains itself
        -- sent copyTree round the cycle until the stack overflowed.
        if type(spec.default) == 'table' then
            local problem = treeProblem(spec.default)
            if problem then
                return nil, ('default %s'):format(problem:gsub('^value ', ''))
            end
        end
        out = copyTree(spec.default)
    end
    -- A nested spec that declares `fields` gets its container created even with no
    if out == nil and spec.fields then
        out = {}
    end
    if type(out) == 'table' then
        if spec.fields then
            -- A nested failure fails the whole call; it used to drop the field.
            local filled, why = fillDefaults(out, spec.fields, depth + 1)
            if not filled then return nil, why end
            out = filled
        end
        if spec.of then
            local nested = {}
            -- The KEY is used, never a running counter.
            for k, v in pairs(out) do
                local item, why = applyFieldDefaults(v, spec.of, depth + 1)
                if why then return nil, why end
                nested[k] = item
            end
            out = nested
        end
    end
    return out
end

fillDefaults = function(value, schema, depth)
    if type(value) ~= 'table' then
        return nil, ('value must be a table, got %s'):format(type(value))
    end
    if type(schema) ~= 'table' then
        return nil, ('schema must be a table, got %s'):format(type(schema))
    end
    -- A schema whose `fields` contain the schema again built containers forever.
    if depth > MAX_COPY_DEPTH then
        return nil, ('schema is nested deeper than %d (does it contain itself?)'):format(MAX_COPY_DEPTH)
    end
    local problem = treeProblem(value)
    if problem then
        return nil, problem
    end
    local out = {}
    -- Supplied values first, so the second pass can tell "absent" from "supplied and
    for k, v in pairs(value) do
        local item, why = applyFieldDefaults(v, schema[k], depth)
        if why then return nil, why end
        out[k] = item
    end
    for key, spec in pairs(schema) do
        if type(spec) == 'table' and out[key] == nil then
            local item, why = applyFieldDefaults(nil, spec, depth)
            if why then return nil, why end
            out[key] = item
        end
    end
    return out
end

--- Fill a table's missing fields from a schema's `default` values.
---@param value table
---@param schema table
---@return table|nil  a NEW filled table
---@return string|nil  why
function M.defaults(value, schema)
    return fillDefaults(value, schema, 1)
end

--- Constrain a number to a range.
---@param v number
---@param min? number
---@param max? number
---@return number|nil
---@return string|nil  why
function M.clamp(v, min, max)
    if type(v) ~= 'number' then
        return nil, ('value must be a number, got %s'):format(typeName(v))
    end
    if not M.isFinite(v) then
        return nil, 'value must be a finite number'
    end
    if min == nil and max == nil then
        return v
    end
    -- A bound must be a number: a string raised a compare error, and a NaN one
    -- failed every comparison, so v came back unclamped.
    if (min ~= nil and (type(min) ~= 'number' or min ~= min))
        or (max ~= nil and (type(max) ~= 'number' or max ~= max)) then
        return nil, ('min and max must be numbers, got %s and %s'):format(tostring(min), tostring(max))
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

-- A MODULE, NOT A GLOBAL.
if ... ~= 'cis_require' then
    CisValidate = M
end

return M
