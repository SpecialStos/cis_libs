-- 10.2: every ```lua example fence from the shipped README runs on the live
-- server against the real exports table.

-- A manifest snippet calls these two; they record instead of declaring, the
-- same as test/examples.lua does offline. They are fxmanifest directives, not
-- globals of a running resource.
local function manifestEnv(rec)
    return setmetatable({
        dependency = function(name) rec.dependency = name end,
        shared_script = function(path) rec.shared_script = path end,
    }, { __index = _G })
end

CisTestRunner.Suite('examples', { tier = 'server', realm = 'server' }, function(t)
    t.case('README lua example fences run', function()
        local md = LoadResourceFile('cis_libs', 'README.md')
        t.ok(type(md) == 'string' and #md > 0, 'README.md is in the deployed resource')
        local n, ran = 0, 0
        local i = 1
        while md do
            local a, b, code = md:find('```lua example\r?\n(.-)```', i)
            if not a then break end
            n = n + 1
            local rec = {}
            local fn, err = load(code, '@README.md example ' .. n, 't', manifestEnv(rec))
            t.ok(fn ~= nil, 'example ' .. n .. ' parses: ' .. tostring(err))
            if fn then
                local ok, why = pcall(fn)
                t.ok(ok, 'example ' .. n .. ' runs: ' .. tostring(why))
                if ok then ran = ran + 1 end
                if ok and (rec.dependency or rec.shared_script) then
                    t.ok(rec.dependency == 'cis_libs' and rec.shared_script == '@cis_libs/init.lua',
                        ('example %d is a consumer manifest naming cis_libs and @cis_libs/init.lua (%s, %s)')
                            :format(n, tostring(rec.dependency), tostring(rec.shared_script)))
                end
            end
            i = b + 1
        end
        t.ok(n >= 1, 'at least one lua example fence (' .. tostring(n) .. ')')
        t.ok(ran == n, ('every example ran (%d/%d)'):format(ran, n))
    end)
end)
