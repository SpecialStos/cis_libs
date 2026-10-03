-- One guarded loop, for every loop this library runs on a timer.
--
-- WHY THIS EXISTS. Every `while true do ... Wait(n) end` in cis_libs used to
-- run its body bare. A raise inside one -- a consumer's handler, a driver that
-- answered with the wrong shape, a nil where a table was expected -- unwound
-- the thread, and a thread that has unwound is GONE. It does not come back on
-- the next tick. It is not retried and it is not reported: the loop that was
-- sweeping expired callbacks, or streaming records, or refreshing the player
-- cache simply stops, silently, and the symptom arrives minutes later as
-- "callbacks time out" or "props stopped spawning".
--
-- That is the worst shape a background job can fail in, because the failure
-- and the symptom are in different places and nothing connects them.
--
-- WHAT IT GUARANTEES.
--
--   * The body runs under `pcall`, so one bad tick costs one tick.
--   * The error is COUNTED, in `GetDiagnostics().counters.loopErrors`, so a
--     harness can diff around a case and see it. Before this, a loop that
--     raised was indistinguishable from a loop that had nothing to do.
--   * The error is LOGGED AT MOST ONCE EVERY TEN SECONDS, per loop. A loop that
--     raises every tick would otherwise flood the console and train the operator
--     to ignore that console -- which is the same failure as not logging at all,
--     reached faster.
--
-- THE LOOP ITSELF IS NOT RETRIED AFTER A FATAL WEAVE FAIL. `Wait` is called
-- outside the pcall on purpose: a Wait that cannot complete is not a bad tick,
-- it is a broken scheduler, and a loop that survives that is a loop spinning.

CisLoopGuard = {}

local LOG_EVERY_MS = 10000

-- `body` is the per-tick work. `intervalMs` is how long to wait BETWEEN ticks,
-- so a loop that takes time does not also sleep on top of it.
function CisLoopGuard.Run(name, intervalMs, body)
    local label = tostring(name)
    -- NIL, NOT ZERO. The clock starts at 0 on a real server, so seeding this to
    -- 0 and testing `now - lastLogged >= 10000` means the FIRST error is never
    -- logged -- for the first ten seconds of the process, which is precisely
    -- when a boot-time failure happens and precisely when the operator is still
    -- watching. Nil says "never logged", which is what it means.
    local lastLogged = nil
    return function()
        while true do
            local ok, err = pcall(body)
            if not ok then
                CisLoopGuard.Raises[label] = (CisLoopGuard.Raises[label] or 0) + 1
                -- Counted even when nothing is logged. The console is for people;
                -- the counter is for the harness, and the harness must see it
                -- even in the ten seconds where it would be quiet.
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

--- The same protection for a loop that paces ITSELF.
---
-- `Run` sleeps a fixed interval between ticks, which is right for the sweeps.
-- A loop that decides its own next wait -- every frame while it has something to
-- draw, every quarter-second when it does not -- cannot use `Run` without
-- changing when it runs, and a resilience fix must not change timing. So this
-- wraps a single pass and the caller keeps its `while true do ... end` and its
-- own `Wait`.
--
-- The `Wait` stays inside the body, inside the pcall. That is deliberate and it
-- is safe here: this library already calls consumer callbacks under `pcall`,
-- and yielding across one is ordinary in CfxLua.
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
            -- nil, so a caller written as `Wait(tick() or default)` falls back
            -- to its default rather than waiting zero.
            return nil
        end
        -- THE BODY'S OWN RETURN VALUE, NOT `true`. The body reports the interval
        -- it wants and the caller waits on it. Returning pcall's `ok` here made
        -- `Wait(tick() or 250)` into `Wait(true)`, which is zero milliseconds --
        -- an infinite tight loop that spins the client's whole frame budget on
        -- nothing.
        return table.unpack(packed, 2, packed.n)
    end
end

--- How many times each named loop has raised. Exposed so a diagnostic can
--- name WHICH loop is unhappy rather than reporting only a total -- a count with
--- no name attached sends the reader looking at every loop in the library.
CisLoopGuard.Raises = {}

CisDiagnostics.Register('both', 'loops', function()
    return CisLoopGuard.Raises
end)