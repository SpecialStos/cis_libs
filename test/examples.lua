-- Extract ```lua example fences and run them. Offline, GetCapabilities is stubbed.

local passed, failed = 0, 0
local failures = {}
TEST_CASES = {}

local function check(cond, msg)
    if cond then
        passed = passed + 1
    else
        failed = failed + 1
        failures[#failures + 1] = msg
    end
    TEST_CASES[#TEST_CASES + 1] = { name = msg, status = cond and 'passed' or 'failed' }
end

local function read(rel)
    if CIS_TEST_FILES and CIS_TEST_FILES[rel] then
        return CIS_TEST_FILES[rel]
    end
    local fh = io.open('./' .. rel, 'rb')
    check(fh ~= nil, 'can open ' .. rel)
    if not fh then return '' end
    local body = fh:read('a')
    fh:close()
    return body or ''
end

local function extract(md)
    local out = {}
    local i = 1
    while true do
        local a, b, code = md:find('```lua example\r?\n(.-)```', i)
        if not a then break end
        out[#out + 1] = code
        i = b + 1
    end
    return out
end

local libs = {}
function libs:GetCapabilities()
    return { framework = { owner = 'stub' } }
end
exports = { ['cis_libs'] = libs }

local blocks = extract(read('README.md'))
check(#blocks >= 1, 'README.md has at least one lua example fence')
for i, code in ipairs(blocks) do
    local fn, err = load(code, '@README.md example ' .. i)
    check(fn ~= nil, 'example ' .. i .. ' parses: ' .. tostring(err))
    if fn then
        local ok, why = pcall(fn)
        check(ok, 'example ' .. i .. ' runs: ' .. tostring(why))
    end
end

io.write(string.format('examples passed=%d failed=%d\n', passed, failed))
if failed > 0 then
    for _, m in ipairs(failures) do io.stderr:write('FAIL(examples): ' .. m .. '\n') end
    os.exit(1)
end
