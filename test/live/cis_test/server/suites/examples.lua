-- 10.2: every ```lua example fence from the shipped README runs on the live
-- server against the real exports table.

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
            local fn, err = load(code, '@README.md example ' .. n)
            t.ok(fn ~= nil, 'example ' .. n .. ' parses: ' .. tostring(err))
            if fn then
                local ok, why = pcall(fn)
                t.ok(ok, 'example ' .. n .. ' runs: ' .. tostring(why))
                if ok then ran = ran + 1 end
            end
            i = b + 1
        end
        t.ok(n >= 1, 'at least one lua example fence (' .. tostring(n) .. ')')
        t.ok(ran == n, ('every example ran (%d/%d)'):format(ran, n))
    end)
end)
