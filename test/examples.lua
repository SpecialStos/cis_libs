-- Run the ```lua example fences in README.md and DOCUMENTATION.md against init.lua.
-- Offline: cis_libs' own exports and the FiveM natives are stubbed, and
-- LoadResourceFile answers from the harness' copy of the shipped files.
--
-- What makes this more than "the fence parses":
--   * init.lua is the REAL file, loaded as a consumer loads it, so `Cis.require`,
--     `Cis.zones.*` and friends are the shipped code, not a stand-in;
--   * every fenced lua block in both documents must be tagged `example` (and so
--     run) or be named in NOT_RUN below with a reason, so a new snippet cannot
--     sit in the docs unrun;
--   * a `local x = ...   -- true` line is a claim: it is asserted;
--   * the manifest snippet is checked against the real manifest, and the
--     SetConfig snippet against the real config rules.

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

local FENCE = string.rep('`', 3)

-- Every fence that opens with the lua tag, tagged `example` or not.
local function fences(md)
    local out = {}
    local i = 1
    while true do
        local a, b, tag, code = md:find(FENCE .. 'lua([^\r\n]*)\r?\n(.-)' .. FENCE, i)
        if not a then break end
        tag = tag:gsub('^%s+', ''):gsub('%s+$', '')
        out[#out + 1] = { tag = tag, code = code }
        i = b + 1
    end
    return out
end

-- Fences that are deliberately not run, by their first line. Empty on purpose: a
-- snippet that cannot run belongs here WITH the reason, not silently untagged.
local NOT_RUN = {}

-- ---------------------------------------------------------------- the stubs
-- Every stub is set on BOTH tables. Under fengari they are the same table. Under
-- a real Lua 5.4 this suite's globals live in an environment table, while a
-- module that Cis.require loads reads the real _G -- so a stub set only here
-- would be invisible to the code under test. The real _G is put back at the end.
local saved = {}
local function stub(name, value)
    if saved[name] == nil then saved[name] = { value = rawget(_G, name) } end
    _G[name] = value
    if _ENV ~= _G then _ENV[name] = value end
end

local calls = {}
local libs = {}
function libs:GetCapabilities()
    return { framework = { owner = 'stub' } }
end
function libs:ReadyState() return true, false end
function libs:SetConfig(config, security, discord)
    calls.setConfig = { config = config, security = security, discord = discord }
    return true
end
stub('exports', setmetatable({}, {
    __index = function(_, name)
        if name == 'cis_libs' then return libs end
        return nil
    end,
    __call = function() end,
}))

local Vec = {}
Vec.__index = Vec
Vec.__sub = function(a, b) return vector3(a.x - b.x, a.y - b.y, a.z - b.z) end
Vec.__len = function(a) return math.sqrt(a.x * a.x + a.y * a.y + a.z * a.z) end
stub('vector3', function(x, y, z) return setmetatable({ x = x, y = y, z = z }, Vec) end)

-- Files of the consumer resource: what `locale` reads.
local consumerFiles = {
    ['locales/en.json'] = '{"shop":{"welcome":"Welcome, ${name}!"}}',
}
-- FiveM's `json` global, which `locale` decodes that file with. Only this one
-- file is ever decoded, so the stub knows it and nothing else.
stub('json', {
    decode = function(text)
        if text == consumerFiles['locales/en.json'] then
            return { shop = { welcome = 'Welcome, ${name}!' } }
        end
        return nil
    end,
})
stub('LoadResourceFile', function(resource, rel)
    if resource == 'cis_libs' then return CIS_TEST_FILES[rel] end
    return consumerFiles[rel]
end)
stub('GetCurrentResourceName', function() return 'consumer_res' end)
stub('IsDuplicityVersion', function() return false end)
stub('GetInvokingResource', function() return nil end)
stub('GetConvar', function(_, default) return default end)
stub('GetGameTimer', function() return 0 end)
stub('GetResourceState', function() return 'started' end)
stub('GetPlayerPed', function() return 0 end)
stub('PlayerPedId', function() return 0 end)
stub('GetEntityCoords', function() return vector3(0.0, 0.0, 0.0) end)
for _, name in ipairs({ 'AddEventHandler', 'RegisterNetEvent', 'RegisterCommand', 'RegisterKeyMapping',
    'CreateThread', 'Wait', 'SetTimeout' }) do
    stub(name, function() end)
end

Cis = nil
assert(loadfile('./init.lua'))()
check(type(Cis) == 'table' and type(Cis.require) == 'function',
    'init.lua loads as a consumer loads it, and gives Cis.require')

-- What the examples print. A warning or an error from a snippet that is
-- documented as working is a failure, however quietly it was printed.
local printed = {}
local function capture(...)
    local parts = table.pack(...)
    for i = 1, parts.n do parts[i] = tostring(parts[i]) end
    printed[#printed + 1] = table.concat(parts, ' ')
end
-- Both tables: under Lua 5.4 this suite's globals are an environment table, and
-- a module reads `print` through the real _G; under fengari they are one table.
stub('print', capture)

-- The defaults the SetConfig snippet is checked against.
assert(load(read('shared/defaults.lua'), '@shared/defaults.lua'))()

-- ------------------------------------------------------- run one fenced block
-- A manifest snippet calls these two; they record instead of declaring.
local function manifestEnv(rec)
    return setmetatable({
        dependency = function(name) rec.dependency = name end,
        shared_script = function(path) rec.shared_script = path end,
    }, { __index = _ENV })
end

-- A `local x = expr   -- true` line is a claim in the prose. Turn it into a check.
local function withClaims(code, label)
    local lines = {}
    local n = 0
    for line in (code .. '\n'):gmatch('(.-)\r?\n') do
        lines[#lines + 1] = line
        local name, claim = line:match('^local%s+([%a_][%w_]*)%s*=.*%-%-%s*(%a+)%s*$')
        if name and (claim == 'true' or claim == 'false') then
            n = n + 1
            lines[#lines + 1] = ('assert(%s == %s, %q)'):format(name, claim,
                label .. ': the comment says ' .. name .. ' is ' .. claim)
        end
    end
    return table.concat(lines, '\n'), n
end

local function runBlock(label, code)
    local rec = {}
    local env = manifestEnv(rec)
    local source, claims = withClaims(code, label)
    local fn, err = load(source, '@' .. label, 't', env)
    check(fn ~= nil, label .. ' parses: ' .. tostring(err))
    if not fn then return rec, claims end
    local ok, why = pcall(fn)
    check(ok, label .. ' runs: ' .. tostring(why))
    return rec, claims
end

local total = 0
local sawManifest, sawConfig, sawClaim = false, false, false
for _, doc in ipairs({ 'README.md', 'DOCUMENTATION.md' }) do
    local blocks = fences(read(doc))
    local ran = 0
    for i, block in ipairs(blocks) do
        local first = block.code:match('^[^\r\n]*') or ''
        local label = ('%s lua fence %d'):format(doc, i)
        if block.tag == 'example' then
            ran = ran + 1
            calls.setConfig = nil
            local rec, claims = runBlock(label, block.code)
            if rec.shared_script or rec.dependency then
                sawManifest = true
                check(rec.dependency == 'cis_libs', label .. ': declares dependency cis_libs')
                local rel = tostring(rec.shared_script):match('^@cis_libs/(.+)$')
                check(rel == 'init.lua', label .. ': includes @cis_libs/init.lua and nothing else')
                check(CIS_TEST_FILES[rel or ''] ~= nil, label .. ': the included file ships')
            end
            if calls.setConfig then
                sawConfig = true
                local c = calls.setConfig
                check(type(c.config) == 'table' and type(c.security) == 'table' and type(c.discord) == 'table',
                    label .. ': SetConfig is called with three tables')
                -- The documented config must pass the library's own rules, and the
                -- documented security keys must be keys the defaults know.
                local resolved = CisDefaults.merge(CisDefaults.config(), c.config)
                local okCfg, problems = CisDefaults.validate(resolved)
                check(okCfg, label .. ': the config passes CisDefaults.validate: ' .. table.concat(problems or {}, '; '))
                local known = CisDefaults.security()
                for key in pairs(c.security) do
                    check(known[key] ~= nil, label .. ': Security.' .. tostring(key) .. ' is a real key')
                end
            end
            if claims and claims > 0 then sawClaim = true end
        elseif not NOT_RUN[first] then
            check(false, ('%s is not tagged `lua example` and not in NOT_RUN: %s'):format(label, first))
        end
    end
    check(ran >= 1, doc .. ' has at least one lua example fence')
    total = total + ran
end
local sawWelcome = false
for _, line in ipairs(printed) do
    check(not line:find('[WARN]', 1, true) and not line:find('[ERROR]', 1, true),
        'an example printed a warning or an error: ' .. line)
    if line:find('Welcome, Ana!', 1, true) then sawWelcome = true end
end
check(sawWelcome, 'the locale example prints the translated phrase')
check(sawManifest, 'an example checks the consumer manifest lines')
check(sawConfig, 'an example checks the SetConfig call')
check(sawClaim, 'an example has a `-- true` claim that is asserted')
check(total >= 8, ('at least eight fences run (ran %d)'):format(total))

-- Put the real globals back, so no later suite in this process sees a stub.
for name, was in pairs(saved) do
    _G[name] = was.value
end

io.write(string.format('examples passed=%d failed=%d\n', passed, failed))
if failed > 0 then
    for _, m in ipairs(failures) do io.stderr:write('FAIL(examples): ' .. m .. '\n') end
    os.exit(1)
end
