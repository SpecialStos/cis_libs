-- One guarded loop, for every loop this library runs on a timer.

CisLoopGuard = {}

local LOG_EVERY_MS = 10000

-- `body` is the per-tick work.
function CisLoopGuard.Run(name, intervalMs, body)
    local label = tostring(name)
    -- NIL, NOT ZERO. The clock starts at 0 on a real server, so seeding this to 0 and
    local lastLogged = nil
    return function()
        while true do
            local ok, err = pcall(body)
            if not ok then
                CisLoopGuard.Raises[label] = (CisLoopGuard.Raises[label] or 0) + 1
                -- Counted even when nothing is logged.
                if CisDiagnostics and CisDiagnostics.Inc then
                    CisDiagnostics.Inc('loopErrors', 1)
                end
                local now = GetGameTimer()
                if lastLogged == nil or (now - lastLogged) >= LOG_EVERY_MS then
                    lastLogged = now
                    local message = ('cis_libs: loop %s raised %s time(s); last: %s')
                        :format(label, tostring(CisLoopGuard.Raises[label]), tostring(err))
                    if Logging and Logging.Error then
                        Logging.Error(message)
                    else
                        print(message)
                    end
                end
            end
            Wait(intervalMs)
        end
    end
end

-- `Run` sleeps a fixed interval between ticks, which is right for the sweeps.
--- The same protection for a loop that paces ITSELF.
function CisLoopGuard.Body(name, body)
    local label = tostring(name)
    local lastLogged = nil
    return function()
        local packed = table.pack(pcall(body))
        if not packed[1] then
            local err = packed[2]
            CisLoopGuard.Raises[label] = (CisLoopGuard.Raises[label] or 0) + 1
            if CisDiagnostics and CisDiagnostics.Inc then
                CisDiagnostics.Inc('loopErrors', 1)
            end
            local now = GetGameTimer()
            if lastLogged == nil or (now - lastLogged) >= LOG_EVERY_MS then
                lastLogged = now
                local message = ('cis_libs: loop %s raised %s time(s); last: %s')
                    :format(label, tostring(CisLoopGuard.Raises[label]), tostring(err))
                if Logging and Logging.Error then
                    Logging.Error(message)
                else
                    print(message)
                end
            end
            -- nil, so a caller written as `Wait(tick() or default)` falls back to its
            return nil
        end
        -- THE BODY'S OWN RETURN VALUE, NOT `true`.
        return table.unpack(packed, 2, packed.n)
    end
end

--- How many times each named loop has raised.
CisLoopGuard.Raises = {}

CisDiagnostics.Register('both', 'loops', function()
    return CisLoopGuard.Raises
end)
