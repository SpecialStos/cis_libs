-- Test registry, assertions, and a deterministic JSON encoder.
-- Deliberately free of FiveM natives so it can be unit-tested under fengari.
-- The coroutine/timeout execution lives in runner.lua.

CisTestReport = {}

local function nowSeconds()
    if os and os.time then
        return os.time()
    end
    return 0
end

function CisTestReport.new()
    return {
        startedAt = nowSeconds(),
        entries = {},
        order = {},
    }
end

function CisTestReport.record(report, entry)
    -- Tolerate a bare table. A caller that hands us `{}` instead of a report
    -- from new() should not take the whole suite down on a nil index.
    report.entries = report.entries or {}
    report.order = report.order or {}
    report.entries[#report.entries + 1] = entry
    report.order[#report.order + 1] = entry.name
    return entry
end

-- ctx: { pass(msg), fail(msg, detail), skip(reason), equal(a, b, msg), truthy(v, msg),
--        exists(v, msg), set(key, value) }
function CisTestReport.context(report, name)
    local ctx = {
        name = name,
        status = 'passed',
        message = nil,
        detail = nil,
        values = {},
    }

    function ctx.pass(msg)
        if not ctx.message then
            ctx.message = msg
        end
    end

    function ctx.set(key, value)
        ctx.values[key] = value
    end

    function ctx.fail(msg, detail)
        ctx.status = 'failed'
        ctx.message = msg
        ctx.detail = detail
    end

    function ctx.skip(reason)
        ctx.status = 'skipped'
        ctx.message = reason
    end

    function ctx.equal(actual, expected, msg)
        if actual == expected then
            ctx.pass(msg)
            return true
        end
        ctx.fail(msg, ('expected %s, got %s'):format(tostring(expected), tostring(actual)))
        return false
    end

    function ctx.truthy(value, msg)
        if value then
            ctx.pass(msg)
            return true
        end
        ctx.fail(msg, 'value was ' .. tostring(value))
        return false
    end

    function ctx.exists(value, msg)
        return ctx.truthy(value ~= nil, msg or 'expected a non-nil value')
    end

    return ctx
end

function CisTestReport.finish(report, ctx, durationMs)
    return CisTestReport.record(report, {
        name = ctx.name,
        status = ctx.status,
        message = ctx.message,
        detail = ctx.detail,
        durationMs = durationMs or 0,
        values = ctx.values,
    })
end

function CisTestReport.summarize(report)
    local summary = { total = 0, passed = 0, failed = 0, skipped = 0, durationMs = 0 }
    local entries = (report and report.entries) or {}
    for i = 1, #entries do
        local e = entries[i]
        summary.total = summary.total + 1
        summary[e.status] = (summary[e.status] or 0) + 1
        summary.durationMs = summary.durationMs + (e.durationMs or 0)
    end
    return summary
end

-- ---------------------------------------------------------------- JSON encoder
-- Hand-rolled so key order is deterministic: two runs of an unchanged system
-- produce byte-identical output, which makes results diffable.
--
-- Backslash must be escaped before every other replacement, otherwise the
-- backslashes introduced by \n, \t and friends get doubled up.
local function escapeString(s)
    s = s:gsub('\\', '\\\\')
    s = s:gsub('"', '\\"')
    s = s:gsub('\n', '\\n')
    s = s:gsub('\r', '\\r')
    s = s:gsub('\t', '\\t')
    s = s:gsub('\b', '\\b')
    s = s:gsub('\f', '\\f')
    s = s:gsub('(%c)', function(c)
        return string.format('\\u%04x', c:byte())
    end)
    return '"' .. s .. '"'
end

-- An empty table is reported as {} rather than []: every empty table this
-- encoder sees is a field like `values` or `meta`, and {} is the safe reading.
local function isArray(t)
    if #t == 0 then
        return false
    end
    local n = 0
    for k in pairs(t) do
        if type(k) ~= 'number' then
            return false
        end
        n = n + 1
    end
    return n == #t
end

local encodeValue

local function encodeTable(v, indent, level)
    local array = isArray(v)

    if array then
        if #v == 0 then
            return '[]'
        end
        local pad = string.rep(indent, level + 1)
        local closing = string.rep(indent, level)
        local out = {}
        for i = 1, #v do
            out[#out + 1] = pad .. encodeValue(v[i], indent, level + 1)
        end
        return '[\n' .. table.concat(out, ',\n') .. '\n' .. closing .. ']'
    end

    local keys = {}
    for k in pairs(v) do
        keys[#keys + 1] = k
    end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)

    if #keys == 0 then
        return '{}'
    end

    local pad = string.rep(indent, level + 1)
    local closing = string.rep(indent, level)
    local out = {}
    for i = 1, #keys do
        local k = keys[i]
        out[#out + 1] = pad .. escapeString(tostring(k)) .. ': ' .. encodeValue(v[k], indent, level + 1)
    end
    return '{\n' .. table.concat(out, ',\n') .. '\n' .. closing .. '}'
end

encodeValue = function(v, indent, level)
    local t = type(v)
    if v == nil then
        return 'null'
    elseif t == 'boolean' then
        return v and 'true' or 'false'
    elseif t == 'number' then
        if v ~= v or v == math.huge or v == -math.huge then
            return 'null'
        end
        if math.type and math.type(v) == 'integer' then
            return string.format('%d', v)
        end
        return string.format('%.6g', v)
    elseif t == 'string' then
        return escapeString(v)
    elseif t == 'table' then
        return encodeTable(v, indent or '  ', level or 0)
    end
    return escapeString(tostring(v))
end

function CisTestReport.encode(value, indent)
    return encodeValue(value, indent or '  ', 0)
end

function CisTestReport.build(payload)
    return {
        meta = payload.meta or {},
        summary = payload.summary or {},
        server = payload.server or {},
        client = payload.client or {},
    }
end
