-- Server bootstrap: config pull, ready gate, diagnostics, console commands.
-- See DECISIONS.md for the incident narratives.

CisNetOn('cis_libs:server:getData', function(src)
    -- Rebuilt per request. A cache would leak a stale Config after a re-point.
    local payload = CisConfigUtil.clientPayload(Config, Security)
    TriggerClientEvent('cis_libs:client:getData', src, payload)
end)

exports('WaitReady', function(timeout)
    return CisReadyState.wait(timeout)
end)

-- Ready when THIS resource has booted, not when a framework is detected.
CreateThread(function()
    Wait(0)
    CisReadyState.markReady()
end)

-- Resolved values only. Nil if not ready. See DECISIONS.md.
exports('GetConfigSummary', function()
    if not CisReadyState.wait(15000) then
        return nil
    end
    local framework = Config and Config.Framework or {}
    local database = framework.Database or {}
    local caps = CisRegistry.snapshot()
    return {
        ready = CisReadyState.ready == true,
        -- Configured type; NONE means detection failed, not "operator left it blank".
        framework = framework.Type or 'NONE',
        inventory = framework.Inventory or 'NONE',
        target = (framework.Target and framework.Target.Type) or 'NONE',
        -- Driver vs whether anything answers. They disagree when the driver is late.
        database = database.Type or 'NONE',
        databaseReady = caps.database ~= nil and caps.database.owner ~= nil
            and caps.database.resolved == true,
        providers = {
            framework = caps.framework and caps.framework.owner or nil,
            database = caps.database and caps.database.owner or nil,
            target = caps.target and caps.target.owner or nil,
            inventory = caps.inventory and caps.inventory.owner or nil,
            doors = caps.doors and caps.doors.owner or nil,
        },
        missing = (function()
            local out = {}
            for slot, entry in pairs(caps) do
                if not entry.owner then
                    out[#out + 1] = slot
                end
            end
            table.sort(out)
            return out
        end)(),
        syncEnabled = not (Config and Config.Sync and Config.Sync.Enabled == false),
        eventPrefix = (Security and Security.EventPrefix) or 'cis_libs',
        callbackTimeout = (Config and Config.CallbackTimeout) or 10000,
        allowListConfigured = type(Security and Security.AuthorizedResources) == 'table'
            and #Security.AuthorizedResources > 0,
    }
end)

-- Derived state only. No secrets. See DECISIONS.md (call, not resolve).
RegisterCommand('cis_debug', function(src)
    if src ~= 0 then
        -- call, not resolve. Test ok AND allowed (the second value is the permission).
        local ok, allowed = CisRegistry.call('framework', 'HasPermission', src, 'admin')
        if not (ok and allowed) then
            return
        end
    end
    print(('[cis_libs] ready=%s jobs=%s'):format(
        tostring(CisReadyState.ready),
        json.encode({ police = CisJobCount('police') })
    ))
    local payload = CisConfigUtil.clientPayload(Config, Security)
    -- false is the expected answer. true means the whitelist drifted.
    print('[cis_libs] client payload has secrets: ' .. tostring(CisConfigUtil.containsSecret(payload)))

    print('[cis_libs] --- capabilities ---')
    local caps = CisRegistry.snapshot()
    local slots = {}
    for slot in pairs(caps) do
        slots[#slots + 1] = slot
    end
    table.sort(slots)
    for _, slot in ipairs(slots) do
        local entry = caps[slot]
        if entry.owner then
            print(('[cis_libs]   %-18s %-16s %s'):format(
                slot, entry.owner, entry.resolved and 'resolved' or 'UNRESOLVED'))
            if entry.missing and #entry.missing > 0 then
                print(('[cis_libs]   %-18s missing: %s'):format('', table.concat(entry.missing, ', ')))
            end
        else
            print(('[cis_libs]   %-18s %-16s %s'):format(slot, '-', 'no provider installed'))
        end
    end

    local known = {}
    if CisDetect then
        for _, k in ipairs(CisDetect.FRAMEWORKS) do known[#known + 1] = k.resource end
        for _, k in ipairs(CisDetect.DATABASES) do known[#known + 1] = k.resource end
    end
    for _, res in ipairs(known) do
        print(('[cis_libs]   %s: %s'):format(res, tostring(GetResourceState(res))))
    end
    print(('[cis_libs] configuration supplied by: %s'):format(
        tostring(Config and Config.__owner or 'built-in defaults (no cis_core)')))
end, true)

-- Restricted console: each problem names its fix. No secrets.
RegisterCommand('cis_doctor', function(src)
    if src ~= 0 then
        return
    end
    print('[cis_libs] --- doctor ---')
    local okCheck, check = pcall(function()
        return exports['cis_libs']:GetSelfCheck()
    end)
    if not okCheck or type(check) ~= 'table' then
        print('[cis_libs] GetSelfCheck unavailable')
    elseif check.ok then
        print('[cis_libs] self-check: ok')
    else
        local problems = check.problems or {}
        print(('[cis_libs] self-check: %d problem(s)'):format(#problems))
        for i = 1, #problems do
            local p = problems[i]
            print(('[cis_libs]   %s: %s'):format(tostring(p.code or '?'), tostring(p.message or '')))
            if p.fix then
                print(('[cis_libs]     fix: %s'):format(tostring(p.fix)))
            end
        end
    end
    local caps = CisRegistry.snapshot()
    local slots = {}
    for slot in pairs(caps) do
        slots[#slots + 1] = slot
    end
    table.sort(slots)
    print('[cis_libs] --- slots ---')
    for _, slot in ipairs(slots) do
        local entry = caps[slot]
        if entry.owner then
            print(('[cis_libs]   %s owner=%s %s'):format(
                slot, entry.owner, entry.resolved and 'resolved' or 'UNRESOLVED'))
        else
            print(('[cis_libs]   %s: no provider. RegisterCapability(%q, "resource:Export")')
                :format(slot, slot))
        end
    end
    print(('[cis_libs] config owner: %s'):format(
        tostring(Config and Config.__owner or 'built-in defaults')))
end, true)

-- Name/path/functions only. A function cannot cross the exports boundary.
exports('ModuleInfo', function(name, opts)
    return Cis.moduleInfo(name, opts)
end)

-- Expected empty: cis_libs installs none of the fifteen module globals.
CisDiagnostics.Register('server', 'modules', function()
    return Cis.moduleProbe()
end)
