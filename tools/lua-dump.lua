-- Serialise a Lua table to JSON from INSIDE Lua.
--
-- The first attempt at gen-types walked api.lua's table off the fengari C-API
-- stack from JavaScript, and got the stack discipline wrong in a way that threw
-- "table expected" several frames from the mistake. That approach is fragile
-- for a reason that has nothing to do with this repository: every level of
-- recursion is an index into a stack whose shape depends on the values above
-- it, and the error names lua_next rather than the table being walked.
--
-- Lua can dump itself with no C API at all, so that is what this does. The
-- output is then JSON.parse'd on the other side, where a malformed document is
-- an ordinary exception with an ordinary message.
--
-- KEYS ARE SORTED, and that is not cosmetic. tools/gen-types.js commits its
-- output and CI fails when the committed copy is stale, so the generator has to
-- be byte-stable across runs. `pairs` order is not, and a generator that
-- reorders its own output on every run would fail CI on every push.

local function isArray(t)
    local n = 0
    for k in pairs(t) do
        if type(k) ~= 'number' then
            return false, n
        end
        n = n + 1
    end
    -- A table is an array only when its keys are exactly 1..n. A table with a
    -- hole is an object, and emitting it as an array would silently drop keys.
    return n > 0, n
end

local function escape(s)
    s = s:gsub('\\', '\\\\')
    s = s:gsub('"', '\\"')
    s = s:gsub('\n', '\\n')
    s = s:gsub('\r', '\\r')
    s = s:gsub('\t', '\\t')
    -- Control characters have no short escape. \uXXXX is what JSON.parse wants,
    -- and emitting them raw would produce a document that fails to parse for a
    -- reason that points nowhere near this file.
    s = s:gsub('[%z\1-\31]', function(c)
        return string.format('\\u%04x', string.byte(c))
    end)
    return s
end

local encode

local function encodeScalar(v)
    local t = type(v)
    if t == 'string' then
        return '"' .. escape(v) .. '"'
    end
    if t == 'number' then
        -- A non-finite number has no JSON form. Emitting it as null is the
        -- honest answer, and it cannot happen here -- api.lua is data.
        if v ~= v or v == math.huge or v == -math.huge then
            return 'null'
        end
        if v == math.floor(v) and math.abs(v) < 2 ^ 53 then
            return string.format('%d', v)
        end
        return string.format('%.14g', v)
    end
    if t == 'boolean' then
        return tostring(v)
    end
    -- Functions and userdata have no JSON form. api.lua is pure data, so a
    -- function here means the file changed shape and the generator should say
    -- so rather than quietly emit null.
    error('cannot encode a ' .. t .. ' -- api.lua is expected to be pure data')
end

encode = function(v, depth)
    if depth > 20 then
        error('table nested too deeply; is api.lua cyclic?')
    end
    local t = type(v)
    if t ~= 'table' then
        return encodeScalar(v)
    end

    local array, n = isArray(v)
    if array and n == #v then
        local parts = {}
        for i = 1, n do
            parts[i] = encode(v[i], depth + 1)
        end
        return '[' .. table.concat(parts, ',') .. ']'
    end

    -- Object. Keys are stringified and sorted, so the output is stable.
    local keys = {}
    for k in pairs(v) do
        keys[#keys + 1] = tostring(k)
    end
    table.sort(keys)
    local parts = {}
    for _, k in ipairs(keys) do
        parts[#parts + 1] = '"' .. escape(k) .. '":' .. encode(v[k], depth + 1)
    end
    return '{' .. table.concat(parts, ',') .. '}'
end

-- A plain global, not arg[]: this is run under fengari from the generator,
-- where arg is a string rather than a table.
local target = CIS_DUMP_TARGET
local chunk = assert(loadfile('./' .. target))
local api = chunk()

-- RETURNED, not printed. fengari's stdout in the node build does not go
-- through process.stdout.write, so swapping it to capture output catches
-- nothing; reading the value off the stack does.
return encode(api, 0)