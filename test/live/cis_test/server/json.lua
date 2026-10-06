-- JSON encoding for the harness's own output.
--
-- cis_libs ships CisJson, but the harness must not use it: a results file
-- written with the library's encoder cannot report a fault in the library's
-- encoder, and the results file is the one artefact this whole exercise exists
-- to produce. So this is a separate, small, deliberately dull encoder.
--
-- The output has to be MACHINE-READABLE FIRST (plan 2.1), and one JSON object
-- per line is what makes a run readable with `grep` while it is still going and
-- parseable in full afterwards.

CisTestJson = {}

local function escape(s)
    return (tostring(s)
        :gsub('\\', '\\\\')
        :gsub('"', '\\"')
        :gsub('\n', '\\n')
        :gsub('\r', '\\r')
        :gsub('\t', '\\t'))
end

-- Keys are sorted so two runs of the same thing produce byte-identical output.
-- A results file that differs run to run cannot be diffed, and diffing two runs
-- is how a leak that only appears on Tuesday gets noticed.
local function sortedKeys(t)
    local keys = {}
    for k in pairs(t) do keys[#keys + 1] = tostring(k) end
    table.sort(keys)
    return keys
end

function CisTestJson.encode(value)
    local kind = type(value)
    if kind == 'nil' then return 'null' end
    if kind == 'boolean' then return tostring(value) end
    if kind == 'number' then
        -- NaN and infinity are not JSON and would produce a file no parser can
        -- read. A diagnostic that divided badly should say so, not corrupt the
        -- file the answer is supposed to be in.
        if value ~= value or value == math.huge or value == -math.huge then
            return '"' .. tostring(value) .. '"'
        end
        if value == math.floor(value) and math.abs(value) < 1e15 then
            return ('%d'):format(value)
        end
        return tostring(value)
    end
    if kind == 'string' then return '"' .. escape(value) .. '"' end
    if kind == 'table' then
        -- An empty table is ambiguous in JSON. Every one here is either a list
        -- or a map and the distinction matters, so emptiness is reported
        -- explicitly rather than guessed: an array is one whose keys are exactly
        -- 1..n.
        local n = 0
        local maxKey = 0
        for k in pairs(value) do
            n = n + 1
            if type(k) ~= 'number' then
                -- a map
                local parts = {}
                for _, mk in ipairs(sortedKeys(value)) do
                    parts[#parts + 1] = ('"%s":%s'):format(mk, CisTestJson.encode(value[mk]))
                end
                return '{' .. table.concat(parts, ',') .. '}'
            end
            maxKey = math.max(maxKey, k)
        end
        if n == 0 then return '[]' end
        if maxKey ~= n then
            local parts = {}
            for _, mk in ipairs(sortedKeys(value)) do
                parts[#parts + 1] = ('"%s":%s'):format(mk, CisTestJson.encode(value[mk]))
            end
            return '{' .. table.concat(parts, ',') .. '}'
        end
        local parts = {}
        for i = 1, n do parts[#parts + 1] = CisTestJson.encode(value[i]) end
        return '[' .. table.concat(parts, ',') .. ']'
    end
    return '"<' .. kind .. '>"'
end

-- One object per line, prefixed, exactly as the plan's output protocol says.
function CisTestJson.Line(obj)
    print('[cis_test] ' .. CisTestJson.encode(obj))
end