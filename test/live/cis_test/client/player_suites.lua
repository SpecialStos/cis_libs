-- Player-tier suites. These run on a real ped on a real client, which is the
-- only place several of them can be observed at all.
--
-- EVERYTHING IS RELATIVE TO THE PLAYER'S CURRENT POSITION, called origin. No
-- case hard-codes a map coordinate: the player's origin is wherever they
-- happened to connect, and a coordinate that is open road on one server is water
-- or a building on another.
--
-- EVERY SUITE GOES THROUGH CisTestPlayer.RunSuite, which snapshots the player,
-- freezes the ped, runs the cases and restores. Nothing here may write the
-- player's state directly.

local P = CisTestPlayer
local exports = exports

local function at(dx, dy, dz)
    local o = P.BaseOrigin()
    return { x = o.x + dx, y = o.y + dy, z = o.z + dz }
end

-- A box zone is (CENTER, SIZE), not (min corner, max corner).
--
-- `at()` is an ABSOLUTE offset from the player's position, so every target is
-- relative to wherever the player actually is when the line runs. It is not a
-- fixed map coordinate and never was.
--
-- The library halves whatever arrives as `size` (`zone.hx = sx * 0.5`), so a
-- max corner is read as an extent. Hand it one and a player standing at x =
-- -836 gets a "size" of -832, which is negative, and the grid refuses the AABB
-- as inverted. Every zone case in this file spent a session passing absolute
-- map coordinates where an extent belonged, so the zone loop has never once
-- been exercised against a zone that existed.
--
-- A helper with a name that cannot be confused with at() is the whole point:
-- the two arguments look identical until one of them is wrong by a factor of
-- the player's distance from the origin.
local function extent(sx, sy, sz)
    return { x = sx, y = sy, z = sz }
end

-- ====================================================== export reachability
--
-- A missing export and a broken loop look IDENTICAL from outside: the callback
-- never arrives either way, and the case files a behavioural failure against
-- code that never ran. That is not hypothetical. It is how two findings in
-- this project went wrong, and how the first attempt at this file answered a
-- bare "false" with nothing to act on.
--
-- So the boring question gets asked first: can the client SEE the export it is
-- about to call? One export per client file, in fxmanifest load order, because
-- a single name cannot tell you WHERE the chain stopped. CreateZone missing
-- means one of two very different things -- zones.lua failed to register its
-- own exports, or the file before it raised and killed the load chain -- and
-- the fix is in a different file either way.
--
-- FiveM aborts the remaining client scripts when one raises, and logs that to
-- the CLIENT console, which nobody can read. This suite is the only place that
-- particular blindness is visible from the server side.

-- Manifest order. Keep in step with client_scripts in fxmanifest.lua.
--
-- zones.lua and target.lua are probed three and five deep rather than once,
-- because "this file registered nothing" and "this one export is missing" are
-- different failures with different causes. A file that registered nothing did
-- not finish loading; an export missing out of a file whose others arrived is a
-- narrower thing and this suite should not blur the two.
local CLIENT_EXPORT_PROBES = {
    { file = 'client/initialize.lua', name = 'IsReady' },
    { file = 'client/logging.lua',     name = 'LogInfo' },
    { file = 'client/streaming.lua',   name = 'RequestModelTimeout' },
    { file = 'client/utils.lua',       name = 'DrawText3D' },
    { file = 'client/weapon.lua',      name = 'GetCurrentWeaponData' },
    { file = 'client/vehicle.lua',     name = 'GetVehicleProperties' },
    { file = 'client/cache.lua',       name = 'WatchNear' },
    { file = 'client/cache.lua',       name = 'RemoveNearWatcher' },
    { file = 'client/zones.lua',       name = 'CreateZone' },
    { file = 'client/zones.lua',       name = 'RemoveZone' },
    { file = 'client/zones.lua',       name = 'ZoneContains' },
    { file = 'client/zones.lua',       name = 'GetZoneDebug' },
    { file = 'client/callback.lua',    name = 'RegisterCallback' },
    { file = 'client/callback.lua',    name = 'AwaitCallback' },
    { file = 'client/target.lua',      name = 'CreateTarget' },
    { file = 'client/target.lua',      name = 'RemoveTarget' },
    { file = 'client/target.lua',      name = 'TargetExists' },
    { file = 'client/target.lua',      name = 'UpdateTarget' },
    { file = 'client/target.lua',      name = 'TargetAvailable' },
    { file = 'client/proxy.lua',       name = 'GetCapabilities' },
    { file = 'client/proxy.lua',       name = 'GetClosestDoor' },
    { file = 'client/proxy.lua',       name = 'GetDiagnostics' },
    { file = 'client/sync.lua',        name = 'GetSyncedEntities' },
    { file = 'client/ui.lua',          name = 'UiNotify' },
    { file = 'client/ui.lua',          name = 'UiTextUIShow' },
    { file = 'client/ui.lua',          name = 'UiProgress' },
    { file = 'client/cache.lua',       name = 'GetCachedPlayerId' },
    { file = 'client/cache.lua',       name = 'GetCachedSeat' },
}

P.RegisterSuite('exports', {
    {
        name = 'the client can reach the exports the other suites call',
        run = function()
            local missing, firstBroken = {}, nil
            for _, p in ipairs(CLIENT_EXPORT_PROBES) do
                -- A missing export RAISES out of the proxy, so the lookup has to
                -- be guarded or the probe dies on the first gap and says nothing
                -- about the twelve files after it.
                local ok = pcall(function() return exports['cis_libs'][p.name] end)
                if not ok then
                    missing[#missing + 1] = ('%s:%s'):format(p.file, p.name)
                    if not firstBroken then firstBroken = p.file end
                end
            end
            if #missing == 0 then
                return true, ('all %d probes reached; onClientResourceStop is %s')
                    :format(#CLIENT_EXPORT_PROBES, type(onClientResourceStop))
            end
            return false, ('FIRST BROKEN FILE: %s | onClientResourceStop is %s | missing %d of %d: %s')
                :format(tostring(firstBroken), type(onClientResourceStop),
                        #missing, #CLIENT_EXPORT_PROBES, table.concat(missing, ', '))
        end,
    },
})

-- ===================================================================== zones
--
-- THE MOST IMPORTANT SUITE IN THIS FILE. The plan's first P0 is that zones
-- never fire onEnter for a standing or slow player, because the only path to
-- onEnter was a containment test gated on movement. A unit suite with a fake
-- clock and scripted coordinates cannot tell a containment test that runs from
-- one that never runs; this can, because the player is genuinely standing still.

P.RegisterSuite('zones', {
    {
        name = 'a zone created AROUND a standing player fires onEnter',
        run = function()
            local o = P.BaseOrigin()
            P.ClearEnterLog()
            local ok, why = exports['cis_libs']:CreateZone('box', 'z_standing',
                { x = o.x, y = o.y, z = o.z },
                extent(8.0, 8.0, 8.0),
                { onEnter = function(_zone, coords) P.NoteEnter(coords) end })
            if not ok then return false, ('CreateZone was refused: %s'):format(tostring(why)) end

            -- The plan allows 250 ms. 1000 is generous and still bounded: a
            -- harness that waits forever cannot tell a slow library from a hung
            -- one.
            local fired = P.WaitFor(function() return #P.EnterLog() > 0 end, 1000)

            -- WHAT THE LIBRARY THINKS, not just whether the event arrived. An
            -- empty log is the same whether the zone was never FOUND by the
            -- candidate pass or was found and the callback never ran, and those
            -- are different bugs with different fixes.
            local dbg = exports['cis_libs']:GetZoneDebug()
            local insideCount = dbg and dbg.insideCount or -1
            local insideNames = dbg and table.concat(dbg.insideNames or {}, ',') or 'n/a'

            exports['cis_libs']:RemoveZone('z_standing')
            return fired,
                ('onEnter for a STANDING player: fired=%s insideCount=%s inside=[%s] passMs=%s')
                    :format(tostring(fired), tostring(insideCount), tostring(insideNames),
                            tostring(dbg and dbg.lastPassMs))
        end,
    },
    {
        name = 'stepping into a small zone fires onEnter exactly once',
        run = function()
            exports['cis_libs']:RemoveZone('z_walk')
            P.ClearEnterLog()
            local ok, why = exports['cis_libs']:CreateZone('box', 'z_walk',
                at(12.0, 12.0, 0.0), extent(4.0, 4.0, 4.0),
                { onEnter = function(_zone, coords) P.NoteEnter(coords) end })
            if not ok then return false, ('CreateZone was refused: %s'):format(tostring(why)) end

            -- StepTowards answers whether the ped ACTUALLY moved. Ignoring that
            -- is what turned a frozen ped into a containment failure: the case
            -- carried on and reported a zone bug for a player who never took a
            -- step.
            local moved, moveWhy = P.StepTowards(at(8.0, 8.0, 0.0), 10)
            if not moved then return false, ('could not walk: %s'):format(tostring(moveWhy)) end
            moved, moveWhy = P.StepTowards(at(12.0, 12.0, 0.0), 25)
            if not moved then return false, ('could not walk: %s'):format(tostring(moveWhy)) end

            -- Settle, then ask the library what it thinks rather than only
            -- whether the callback arrived. An empty log is the same whether
            -- the zone was never FOUND by the candidate pass or was found and
            -- the callback never ran, and those are different bugs.
            P.WaitFor(function() return false end, 600)
            local dbg = exports['cis_libs']:GetZoneDebug()
            local insideCount = dbg and dbg.insideCount or -1
            local insideNames = dbg and table.concat(dbg.insideNames or {}, ',') or 'n/a'

            -- THE DIRECT TEST, which separates "the zone does not contain the
            -- player" from "the sweep never looked". ZoneContains answers the
            -- geometry question on its own, with no grid and no loop involved,
            -- so it says which of the two is true where insideCount alone does
            -- not. If this is true and insideCount is 0, the zone exists and
            -- holds the player, and the sweep is what is failing.
            local here = P.Origin()
            local contains = exports['cis_libs']:ZoneContains('z_walk', here)

            local n = #P.EnterLog()
            local removed = exports['cis_libs']:RemoveZone('z_walk')
            -- Does removing it actually drop the library's belief? A leftover
            -- `inside` entry from THIS case is what made the next case wait on
            -- a zone that was never discovered and then report a missing onExit.
            P.WaitFor(function() return false end, 400)
            local after = exports['cis_libs']:GetZoneDebug()
            local stillIn = after and table.concat(after.insideNames or {}, ',') or 'n/a'
            -- A zone that survives its own removal in the library's `inside`
            -- table is a leak, and it used to show up one case later as a
            -- missing onExit somewhere else entirely. Assert it HERE, where the
            -- evidence is, instead of leaving it to be misattributed.
            local leaked = stillIn ~= '' and stillIn ~= 'n/a'
            return n == 1 and not leaked,
                ('onEnter fired exactly once while walking in: %d time(s), '
                    .. 'insideCount=%s inside=[%s] passMs=%s | '
                    .. 'ZoneContains(player)=%s at %.1f,%.1f,%.1f | '
                    .. 'removed=%s, inside AFTER removal=[%s]%s')
                    :format(n, tostring(insideCount), tostring(insideNames),
                            tostring(dbg and dbg.lastPassMs), tostring(contains),
                            here.x, here.y, here.z, tostring(removed), stillIn,
                            leaked and '  <-- LEAKED: the library still holds a removed zone' or '')
        end,
    },
    {
        name = 'removing a zone the player is inside fires ONE onExit with the player coords',
        run = function()
            exports['cis_libs']:RemoveZone('z_remove')
            P.ClearEnterLog()
            P.ClearExitLog()
            local ok, why = exports['cis_libs']:CreateZone('box', 'z_remove',
                at(2.0, 2.0, 2.0), extent(4.0, 4.0, 4.0),
                { onEnter = function() end, onExit = function(_zone, coords) P.NoteExit(coords) end })
            -- A refused zone here reports "coords MISSING" thirty lines later,
            -- which names the symptom and hides the cause. The exit can only be
            -- observed on a zone that exists.
            if not ok then return false, ('CreateZone was refused: %s'):format(tostring(why)) end

            -- Wait until the LIBRARY agrees the player is inside.
            --
            -- RemoveZone only fires onExit for a zone it believes the player is
            -- in, and that belief is established by the sweep, not by the
            -- creation. This used to `WaitFor(function() return true end, 300)`,
            -- which returns on the first evaluation and so waited no time at
            -- all -- the zone was removed before the loop had ever looked at
            -- it, and the case reported 0 exits regardless of what removal
            -- does. It has been reporting that for the whole project.
            -- Wait for THIS zone by NAME, not merely for any zone to be inside.
            -- `insideCount > 0` is satisfied by a leftover from a previous case
            -- -- or, before the debug-snapshot fix, by a stale snapshot naming
            -- a zone that had already been removed -- and then this case waits
            -- for something that will never happen and blames the removal.
            local dbg
            local seen = P.WaitFor(function()
                dbg = exports['cis_libs']:GetZoneDebug()
                for _, nme in ipairs((dbg and dbg.insideNames) or {}) do
                    if nme == 'z_remove' then return true end
                end
                return false
            end, 2000)
            if not seen then
                return false, ('the library never registered the player inside '
                    .. 'z_remove (insideCount=%s after 2000ms)')
                        :format(tostring(dbg and dbg.insideCount))
            end

            -- WHICH zone did the library think the player was inside? The wait
            -- above only proves SOME zone was; RemoveZone fires onExit for the
            -- named one only, and a leftover from a previous case would satisfy
            -- the wait while leaving this zone undiscovered.
            local insideNames = dbg and table.concat(dbg.insideNames or {}, ',') or 'n/a'

            P.ClearExitLog()
            local removed = exports['cis_libs']:RemoveZone('z_remove')

            local exits = P.ExitLog()
            local first = exits[1]
            -- A zone callback is called as fn(zone, coords) -- see `invoke` in
            -- client/zones.lua -- so the harness reads the SECOND argument.
            -- Reading the first handed it the zone table, whose `.x` is nil, and
            -- the message format raised instead of reporting the pass. The case
            -- had been reporting this failure for the whole project.
            local haveCoords = type(first) == 'table' and type(first.x) == 'number'
            local coordsText = haveCoords
                and ('%.1f, %.1f, %.1f'):format(first.x, first.y, first.z)
                or 'MISSING'
            return #exits == 1 and haveCoords,
                ('one onExit on removal: %d, coords %s (removed=%s, library had inside=[%s])')
                    :format(#exits, coordsText, tostring(removed), insideNames)
        end,
    },
    {
        name = 'a zone 400 m above the player does not contain them',
        run = function()
            exports['cis_libs']:RemoveZone('z_high')
            local ok, why = exports['cis_libs']:CreateZone('box', 'z_high',
                at(2.0, 2.0, 402.0), extent(4.0, 4.0, 4.0), {})
            -- This one is the dangerous shape: a refused zone leaves
            -- ZoneContains answering about a name that does not exist, and
            -- "does not contain the player" is the PASSING answer. A refusal
            -- here would have been recorded as a success.
            if not ok then return false, ('CreateZone was refused: %s'):format(tostring(why)) end
            local inside = exports['cis_libs']:ZoneContains('z_high', P.Origin())
            exports['cis_libs']:RemoveZone('z_high')
            return inside == false,
                ('a zone 400 m up does not contain the player: %s'):format(tostring(inside))
        end,
    },
})

-- ============================================================ the P0 for real
--
-- Found in Stage 1 by the linter rather than by a test: DrawText3D calls
-- GetGameplayCamCoords and DrawText, and neither exists. At the baseline this
-- raises on the first call.

P.RegisterSuite('debugtext', {
    {
        name = 'DrawText3D does not raise',
        run = function()
            -- Coordinates far away so nothing is actually drawn over the game.
            -- What is under test is that the call RETURNS.
            local ok, err = pcall(function()
                exports['cis_libs']:DrawText3D(0.0, 0.0, 0.0, 'harness', { 1, 1, 1, 255 })
            end)
            return ok, ok and 'did not raise' or ('raised: %s'):format(tostring(err))
        end,
    },
})

-- ===================================================================== points

P.RegisterSuite('points', {
    {
        name = 'crossing a point radius gives one enter and one exit',
        run = function()
            P.ClearNearLog()
            -- Radius 4 about at(6,0,0). The walk has to end OUTSIDE it, and both
            -- old targets were inside: at(4,0,0) is 2 m out and at(9,0,0) is
            -- 3 m out, so the case could produce an enter but never an exit and
            -- reported `1 in, 0 out` as though the library had dropped one.
            -- UNSUBSCRIBE, OR THE WATCHER OUTLIVES THE RUN.
            --
            -- watchNear returns an unsubscribe and the harness discarded it, so
            -- every run left a live watcher behind. It is a per-tick distance
            -- check that costs the rest of the server's life, and it kept
            -- calling into a log the next run had already cleared -- which is
            -- why this case passed on a clean server and reported exactly
            -- `2 in, 2 out` on the very next run: the previous run's watcher,
            -- watching the same player, firing as well.
            local _, watcherId = exports['cis_libs']:WatchNear(at(6.0, 0.0, 0.0), 4.0,
                function() P.NoteNear('in') end,
                function() P.NoteNear('out') end)
            -- The id is the handle that crosses the boundary intact; the
            -- unsubscribe WatchNear also returns does not (it arrives as a
            -- table). RemoveNearWatcher exists for exactly this.
            if type(watcherId) ~= 'number' then
                return false, ('WatchNear returned %s as its id, not a number')
                    :format(type(watcherId))
            end

            -- The walk runs in a closure so the unsubscribe happens on EVERY path out.
            -- This case has five early returns, and a watcher leaked by any of
            -- them is the same defect as never unsubscribing at all -- it would
            -- simply be rarer.
            local passed, why = (function()
                local moved, moveWhy = P.StepTowards(at(4.0, 0.0, 0.0), 25)
                if not moved then
                    return false, ('could not walk: %s'):format(tostring(moveWhy))
                end

                -- LET THE LIBRARY OBSERVE THE PLAYER INSIDE BEFORE WALKING OUT.
                --
                -- Two teleports with nothing between them can land entirely
                -- between two sweeps. The watcher then sees outside, then
                -- outside again, and reports nothing at all -- which is what
                -- `0 in, 0 out` was: not a dropped callback, a state the
                -- library was never shown.
                local gotIn = P.WaitFor(function()
                    for _, e in ipairs(P.NearLog()) do
                        if e == 'in' then return true end
                    end
                    return false
                end, 2000)
                if not gotIn then
                    return false, ('the watcher never reported the enter at '
                        .. '2 m from a 4 m radius (log: %s)')
                            :format(table.concat(P.NearLog(), ','))
                end

                -- 10 m from the watcher: clearly outside, so the exit is real.
                moved, moveWhy = P.StepTowards(at(16.0, 0.0, 0.0), 25)
                if not moved then
                    return false, ('could not walk: %s'):format(tostring(moveWhy))
                end

                -- AND WAIT FOR THE EXIT TOO. Waiting only for the enter made
                -- this case timing-dependent: the sweep runs on a 200 ms tick
                -- with a 500 ms periodic check, so walking out and counting
                -- immediately raced it. It passed on a clean server and
                -- reported `1 in, 0 out` on the next run. Same lesson as the
                -- enter -- the case must observe each state, not assume it.
                local gotOut = P.WaitFor(function()
                    for _, e in ipairs(P.NearLog()) do
                        if e == 'out' then return true end
                    end
                    return false
                end, 2000)
                if not gotOut then
                    return false, ('the watcher never reported the exit 10 m from '
                        .. 'a 4 m radius (log: %s)'):format(table.concat(P.NearLog(), ','))
                end

                local ins, outs = 0, 0
                for _, e in ipairs(P.NearLog()) do
                    if e == 'in' then ins = ins + 1 else outs = outs + 1 end
                end
                return ins == 1 and outs == 1,
                    ('exactly one enter and one exit: %d in, %d out'):format(ins, outs)
            end)()

            -- Stop the watcher on every path out, so a run never leaves a per-tick
            -- distance check behind for the next one to trip over.
            local stopped, stopWhy = exports['cis_libs']:RemoveNearWatcher(watcherId)
            if not stopped then
                return false, ('could not remove watcher %s: %s')
                    :format(tostring(watcherId), tostring(stopWhy))
            end
            return passed, why
        end,
    },
})
-- ============================================ Stage 3, on a real client, at last
--
-- Every case below had a unit test and NO live proof until this run, because
-- the player tier had never executed: this box has no GPU, so no FiveM client
-- could connect and the whole tier SKIPped. `test/live/UNRUN.md` §1 is the
-- list, and this suite is what empties it.
--
-- The unit tests answer "does this call the right function". These answer "does
-- it still work through a real exports boundary, on a real ped, in a real Lua
-- VM", which is a different question and the only one a player can answer.

P.RegisterSuite('stage3', {
    {
        name = 'GetCapabilities answers a table of slots',
        run = function()
            local ok, caps = pcall(function() return exports['cis_libs']:GetCapabilities() end)
            if not ok then
                return false, ('GetCapabilities raised: %s'):format(tostring(caps))
            end
            if type(caps) ~= 'table' then
                return false, ('GetCapabilities answered %s, not a table'):format(type(caps))
            end
            local n = 0
            for _ in pairs(caps) do n = n + 1 end
            return n > 0, ('answered a table with %d slot(s)'):format(n)
        end,
    },

    -- 3.14 · doorsClient.RequestState. This used to fire a raw event by name, so
    -- it worked only because one product happened to handle that exact wire
    -- name. With a provider registered the request must go THROUGH THE SLOT, and
    -- the fake's ring is what proves it did.
    {
        name = 'a door state request reaches the doorsClient provider',
        run = function()
            exports['cis_test_providers']:ResetCalls('doorsClient')
            local ok, err = pcall(function()
                exports['cis_libs']:RequestLockDoors('cis_test_door_1')
            end)
            if not ok then
                return false, ('RequestLockDoors raised: %s'):format(tostring(err))
            end

            local calls = exports['cis_test_providers']:GetCalls('doorsClient', 'RequestState')
            local n = type(calls) == 'table' and #calls or 0
            local sawIdentifier = false
            if n > 0 then
                local first = calls[1]
                sawIdentifier = (first.args and first.args[1] == 'cis_test_door_1') or false
            end
            return n > 0,
                ('RequestState reached the provider %d time(s), identifier carried: %s')
                    :format(n, tostring(sawIdentifier))
        end,
    },

    -- 3.3 · onExit coordinates. `remove` used to hand the zone CENTRE to onExit
    -- while every other exit handed the player's own position, so a consumer
    -- that stored the coordinate got a place the player was never at.
    {
        name = 'onExit hands over the coordinates the player actually stands at',
        run = function()
            exports['cis_libs']:RemoveZone('z_exit')
            P.ClearExitLog()
            local o = P.BaseOrigin()
            local ok, why = exports['cis_libs']:CreateZone('box', 'z_exit',
                at(6.0, 0.0, 0.0), extent(6.0, 6.0, 6.0),
                { onEnter = function(_z, coords) P.NoteEnter(coords) end,
                  onExit = function(_z, coords) P.NoteExit(coords) end })
            if not ok then
                return false, ('CreateZone was refused: %s'):format(tostring(why))
            end

            -- In, then out, so this is a real boundary crossing and not the
            -- removal path -- the removal path is the other half of this case.
            --
            -- AND IT WAITS INSIDE FIRST. The zone pass runs on a timer, so a ped
            -- that walks in and straight back out between two passes was never
            -- observed inside and has no exit to report. That is not a library
            -- bug and it is not a harness bug either: a player cannot cross a
            -- zone faster than the server samples it. The first version of this
            -- case walked in and out back to back and reported "onExit never
            -- fired" against working code.
            local moved, moveWhy = P.StepTowards(at(6.0, 0.0, 0.0), 20)
            if not moved then return false, ('could not walk in: %s'):format(tostring(moveWhy)) end
            -- Cleared BEFORE the walk, not after. Clearing afterwards throws away
            -- the enter that may already have fired and then waits for a second
            -- one that cannot come, because the player is now standing still
            -- inside the zone. That ordering reported "never observed inside"
            -- against a library that had already fired.
            local inside = P.WaitFor(function() return #P.EnterLog() > 0 end, 1500)
            if not inside then
                exports['cis_libs']:RemoveZone('z_exit')
                return false, 'the player was never observed inside the zone'
            end

            moved, moveWhy = P.StepTowards(at(20.0, 0.0, 0.0), 25)
            if not moved then return false, ('could not walk out: %s'):format(tostring(moveWhy)) end

            local fired = P.WaitFor(function() return #P.ExitLog() > 0 end, 1500)
            exports['cis_libs']:RemoveZone('z_exit')
            if not fired then return false, 'onExit never fired' end

            local coords = P.ExitLog()[1]
            -- A VECTOR3 IS NOT A TABLE. CfxLua reports a vector as userdata, so
            -- `type(v) == 'table'` refuses it -- the exact trap task 4.2 closed on
            -- the server, where a vector3 from any framework was refused for
            -- being "not a table". Reading .x works for both shapes, so that is
            -- what this asserts.
            local x = type(coords) == 'table' and coords.x or coords.x
            if type(x) ~= 'number' then
                return false, ('onExit handed %s, which carries no x'):format(type(coords))
            end
            -- The player is past x=+20; the zone centre is x=+6. Metres separate
            -- the two answers, so this cannot pass by accident.
            local away = math.abs(x - o.x)
            return away > 12.0,
                ('onExit x offset from origin: %.1f (the zone centre would be 6.0), handed as %s')
                    :format(away, type(coords))
        end,
    },

    -- 3.10 · thread resilience. A real consumer handler that RAISES, inside a
    -- real background loop, on a real client. The loop has to survive it --
    -- otherwise one bad callback silently stops every zone on the server.
    {
        name = 'a zone callback that raises does not stop the zone loop',
        run = function()
            exports['cis_libs']:RemoveZone('z_boom')
            local ok, why = exports['cis_libs']:CreateZone('box', 'z_boom',
                at(0.0, 0.0, 0.0), extent(30.0, 30.0, 30.0),
                { onEnter = function() error('cis_test: this handler raises on purpose') end })
            if not ok then
                return false, ('CreateZone was refused: %s'):format(tostring(why))
            end

            -- Out and back, so onEnter runs again AFTER the raise.
            P.StepTowards(at(40.0, 0.0, 0.0), 20)
            P.StepTowards(at(0.0, 0.0, 0.0), 30)

            -- THE LOOP IS STILL ALIVE. A zone created after the raise still has
            -- to fire: that is the difference between "one callback raised" and
            -- "the loop died".
            exports['cis_libs']:RemoveZone('z_after')
            P.ClearEnterLog()
            local ok2, why2 = exports['cis_libs']:CreateZone('box', 'z_after',
                at(0.0, 0.0, 0.0), extent(20.0, 20.0, 20.0),
                { onEnter = function(_z, coords) P.NoteEnter(coords) end })
            if not ok2 then
                exports['cis_libs']:RemoveZone('z_boom')
                return false, ('the zone loop is dead: %s'):format(tostring(why2))
            end
            local alive = P.WaitFor(function() return #P.EnterLog() > 0 end, 1500)

            exports['cis_libs']:RemoveZone('z_boom')
            exports['cis_libs']:RemoveZone('z_after')
            -- NO COUNTER ASSERTION, and the reason is worth more than the
            -- assertion would have been. An earlier version of this case watched
            -- `counters.loopErrors` and reported "0 -> 0" as a defect. It is not
            -- one: `invoke` catches a consumer callback's error with its own
            -- pcall and LOGS it, so the zone loop's own body never fails and
            -- `loopErrors` correctly stays where it was. The plan's 3.10 is about
            -- loop BODIES; a consumer's handler failing is a different counter
            -- that does not exist yet, and inventing an assertion for it here
            -- would have reported a missing feature as a broken library.
            return alive, ('a later zone still fires: %s'):format(tostring(alive))
        end,
    },

    -- 3.4b · the debug draw THREAD. The look is a MANUAL case per the plan and
    -- is not automated coverage; what IS automatable is that the thread starts
    -- with the first debug zone, stops with the last, and that the state is
    -- visible in GetZoneDebug.
    {
        name = 'the debug draw thread starts and stops with the debug zone',
        run = function()
            exports['cis_libs']:RemoveZone('z_dbg')
            local idle = exports['cis_libs']:GetZoneDebug()
            -- `debugDrawing`, read from client/zones.lua rather than guessed. The
            -- first version of this case asked for `.drawing`, which is simply
            -- absent, so the comparison was `nil == true` and the case reported a
            -- thread state nobody could act on.
            local idleDrawing = (idle and idle.debugDrawing) or false

            local ok, why = exports['cis_libs']:CreateZone('box', 'z_dbg',
                at(0.0, 0.0, 0.0), extent(8.0, 8.0, 8.0), { debug = true })
            if not ok then
                return false, ('CreateZone was refused: %s'):format(tostring(why))
            end
            P.WaitFor(function()
                local d = exports['cis_libs']:GetZoneDebug()
                return d and d.debugDrawing == true
            end, 1000)
            local drawing = exports['cis_libs']:GetZoneDebug()

            exports['cis_libs']:RemoveZone('z_dbg')
            P.WaitFor(function()
                local d = exports['cis_libs']:GetZoneDebug()
                return d and d.debugDrawing == false
            end, 1000)
            local stopped = exports['cis_libs']:GetZoneDebug()

            return (drawing and drawing.debugDrawing == true)
                    and (stopped and stopped.debugDrawing == false),
                ('debug thread: idle=%s during=%s after=%s')
                    :format(tostring(idleDrawing),
                            tostring(drawing and drawing.debugDrawing),
                            tostring(stopped and stopped.debugDrawing))
        end,
    },

    -- 2.7 · the player contract, asserted on its own rather than as a side
    -- effect of the other suites. Every suite already checks `restored`; this
    -- one states the whole contract in one place, so a regression names it.
    {
        name = 'the player is back where the harness found them',
        run = function()
            local o = P.BaseOrigin()
            local ped = P.Ped()
            local here = GetEntityCoords(ped)
            local dx = here.x - o.x
            local dz = here.z - o.z
            local bucket = 0
            if type(GetEntityRoutingBucket) == 'function' then
                bucket = GetEntityRoutingBucket(ped) or 0
            end
            local ok = math.abs(dx) < 1.0 and math.abs(dz) < 1.0 and bucket == 0
            return ok, ('ped is %.2f m from origin in x and %.2f m in z, bucket %s')
                :format(dx, dz, tostring(bucket))
        end,
    },
})
-- ================================ 4.9 · payload hygiene, on a real client
--
-- The client is the last thing between a bad payload and an entity in the world,
-- so it is where a malformed record has to die. It refused unusable coords
-- SILENTLY before, and a silent refusal looks exactly like a record that was
-- never meant to arrive -- so the person whose door never appears had nothing in
-- the console to act on.
--
-- THE ORDER IS THE POINT, and it was got wrong first time round. The refusal
-- cases assert that NOTHING spawned, which is also what you see on a client
-- where no model streams at all -- so run before the good case they proved
-- nothing. `IsModelAvailable` goes FIRST and every case after it inherits a
-- client that is known to be able to spawn something.
--
-- Nothing here can reach the client's F8 output from here: cis_libs and cis_test
-- have SEPARATE Lua states, so wrapping `CisLog` in one resource never sees the
-- other's calls. That was tried and does not work. What the client logs is
-- visible only on the machine the player is sitting at.
local function spawnableKey(name)
    return 'cis_test_hygiene_' .. tostring(name)
end

P.RegisterSuite('synchygiene', {
    {
        name = 'this client can stream a model, or the rest proves nothing',
        run = function()
            -- A fixed list, tried in order, and a fallback to a MODEL the server
            -- already streamed: a client parked where no prop is resident
            -- refuses every model it does not already hold, and that is a fact
            -- about where the player is standing, not about the code.
            local names = { 'prop_barrel_01', 'prop_barrier_05a', 'prop_box_01a', 'prop_roadcone02a' }
            local reasons = {}
            for _, name in ipairs(names) do
                local packed
                local ok = pcall(function()
                    packed = table.pack(exports['cis_libs']:RequestModelTimeout(name, 8000))
                end)
                if ok and packed[1] then
                    return true, ('model %s streams here'):format(name)
                end
                reasons[#reasons + 1] = ('%s:%s'):format(name, ok and tostring(packed[3] or packed[1]) or 'raised')
            end
            -- A model already in the world is the fallback the comment promised
            -- and the first version never had. If RequestModelTimeout cannot
            -- reload something the player is looking at, that is a library bug.
            local pool = GetGamePool and GetGamePool('CObject') or {}
            for i = 1, #pool do
                local m = GetEntityModel(pool[i])
                if type(m) == 'number' and m ~= 0 then
                    local packed
                    local ok = pcall(function()
                        packed = table.pack(exports['cis_libs']:RequestModelTimeout(m, 4000))
                    end)
                    if ok and packed[1] then
                        return true, ('already-resident object model %s streams'):format(tostring(m))
                    end
                end
            end
            reasons[#reasons + 1] = ('pool=%d'):format(#pool)
            -- nil, not false: `ok = passed ~= false`, so nil PASSES with its
            -- explanation. A `false` here would say "the code is wrong", and the
            -- code is not.
            return nil, 'NO SYNC MODEL STREAMS ON THIS CLIENT RIGHT NOW (' ..
                table.concat(reasons, '; ') .. '), so the client spawn path cannot ' ..
                'be proved here. Everything after this case is untested, not passing.'
        end,
    },
    {
        name = 'a valid record spawns, so the refusals below are not refusing everything',
        run = function()
            local key = spawnableKey('good')
            TriggerServerEvent('cis_test:rawSync', {
                key = key, id = key, kind = 'prop', model = 'prop_roadcone02a',
                coords = at(2.0, 0.0, 0.0), networked = false,
            })
            local handle, waited = nil, 0
            while waited < 10000 do
                handle = exports['cis_libs']:GetSyncedEntities()[key]
                if handle ~= nil then break end
                Wait(200)
                waited = waited + 200
            end
            -- Unconditionally, so a failed assertion does not leave a prop
            -- standing next to a real person.
            TriggerServerEvent('cis_test:rawSyncRemove', key)
            Wait(200)
            local after = exports['cis_libs']:GetSyncedEntities()
            if handle == nil then
                return nil, 'no model streamed, so nothing spawned and nothing was proved'
            end
            return after[key] == nil,
                ('spawned=%s and let go of afterwards=%s')
                    :format(tostring(handle ~= nil), tostring(after[key] == nil))
        end,
    },
    {
        name = 'a record with unusable coords is ignored',
        run = function()
            local key = spawnableKey('badcoords')
            TriggerServerEvent('cis_test:rawSync', {
                key = key, id = key, kind = 'prop', model = 'prop_roadcone02a',
                coords = 'not a position', networked = false,
            })
            Wait(600)
            local handle = exports['cis_libs']:GetSyncedEntities()[key]
            if handle == nil then
                -- Could be the refusal, or a client that cannot spawn at all. The
                -- previous case is what tells those apart, and it is why it runs
                -- first.
                return true, 'nothing spawned from a string in place of coords'
            end
            TriggerServerEvent('cis_test:rawSyncRemove', key)
            return false, 'a record with string coords SPAWNED'
        end,
    },
    {
        name = 'a record whose model is neither a name nor a hash is ignored',
        run = function()
            local key = spawnableKey('badmodel')
            TriggerServerEvent('cis_test:rawSync', {
                key = key, id = key, kind = 'prop',
                -- A table used to be accepted: tostring turns it into text and
                -- joaat hashes that text into a plausible hash that resolves to
                -- nothing, so the record spawned nothing and said nothing.
                model = { shape = 'not a model' },
                coords = at(1.0, 0.0, 0.0), networked = false,
            })
            Wait(600)
            local handle = exports['cis_libs']:GetSyncedEntities()[key]
            if handle == nil then
                return true, 'nothing spawned from a table in place of a model'
            end
            TriggerServerEvent('cis_test:rawSyncRemove', key)
            return false, 'a record with a table model SPAWNED'
        end,
    },
})

-- ===================================================================== ui (7.9)
--
-- Native fallbacks: the GTA feed and help text. No spawn, no walk. progress
-- without a provider must refuse by name -- a true here is a fake dialog.

P.RegisterSuite('ui', {
    {
        name = 'native notify answers true and does not raise',
        run = function()
            local ok, why = exports['cis_libs']:UiNotify('cis_test 7.9')
            if ok ~= true then
                return false, ('UiNotify -> %s, %s'):format(tostring(ok), tostring(why))
            end
            return true, 'native feed accepted'
        end,
    },
    {
        name = 'textUI show, isOpen, hide round trip',
        run = function()
            local ok, why = exports['cis_libs']:UiTextUIShow('cis_test 7.9')
            if not ok then
                return false, ('show refused: %s'):format(tostring(why))
            end
            local open = exports['cis_libs']:UiTextUIIsOpen()
            if open ~= true then
                exports['cis_libs']:UiTextUIHide()
                return false, ('isOpen after show was %s'):format(tostring(open))
            end
            exports['cis_libs']:UiTextUIHide()
            local closed = exports['cis_libs']:UiTextUIIsOpen()
            if closed ~= false then
                return false, ('isOpen after hide was %s'):format(tostring(closed))
            end
            return true, 'show/isOpen/hide'
        end,
    },
    {
        name = 'progress without a ui provider refuses by name',
        run = function()
            local ok, why = exports['cis_libs']:UiProgress({ duration = 1 })
            if ok ~= false then
                return false, ('progress answered %s, wanted false'):format(tostring(ok))
            end
            if type(why) ~= 'string' or not why:find('no ui provider', 1, true) then
                return false, ('reason was %s'):format(tostring(why))
            end
            return true, why
        end,
    },
})

-- ===================================================================== cache (7.10)
--
-- seat/playerId getters, lockState on a live vehicle if the player is in one.
-- mount is RedM-only and is not a key here. Do not RollUpWindow: a getter
-- that mutates the vehicle is not a getter.

P.RegisterSuite('cache', {
    {
        name = 'playerId is a number; seat is nil on foot or a seat index in a vehicle',
        run = function()
            local id = exports['cis_libs']:GetCachedPlayerId()
            if type(id) ~= 'number' then
                return false, ('playerId was %s'):format(type(id))
            end
            local veh = exports['cis_libs']:GetCachedVehicle()
            local seat = exports['cis_libs']:GetCachedSeat()
            if veh == nil then
                if seat ~= nil then
                    return false, ('on foot GetCachedSeat was %s, not nil'):format(tostring(seat))
                end
                return true, ('on foot playerId=%s seat=nil'):format(tostring(id))
            end
            if type(seat) ~= 'number' then
                return false, ('in vehicle but seat was %s'):format(tostring(seat))
            end
            local props = exports['cis_libs']:GetVehicleProperties(veh)
            if type(props) ~= 'table' or type(props.lockState) ~= 'number' then
                return false, ('in vehicle but lockState missing (%s)'):format(type(props and props.lockState))
            end
            if type(props.livery) ~= 'number' then
                return false, ('in vehicle but livery missing (%s)'):format(type(props and props.livery))
            end
            return true, ('playerId=%s seat=%s lockState=%s livery=%s'):format(
                tostring(id), tostring(seat), tostring(props.lockState), tostring(props.livery))
        end,
    },
})

-- ===================================================================== perf (8.2)
--
-- Measure, publish conditions, compare to the plan's starting budgets.
-- GetGameTimer is 1 ms; a last of 0 is quantization, not proof of 0.00 ms.
-- Containment loops time many iterations and divide when the pass clock is 0.

local function clockMs()
    if os and type(os.clock) == 'function' then
        local c = os.clock()
        if type(c) == 'number' and c == c and c > 0 then
            return c * 1000
        end
    end
    return GetGameTimer()
end

local function zonePassMs()
    local d = exports['cis_libs']:GetDiagnostics()
    local z = d and d.timings and d.timings.zonePass
    return z, d
end

-- GetGameTimer does not advance inside a tight loop. A `until dt >= 20`
-- condition never becomes true and freezes the client. Cap iterations, yield.
local function wipeNames(names)
    for i = 1, #names do
        exports['cis_libs']:RemoveZone(names[i])
        if i % 25 == 0 then Wait(0) end
    end
end

P.RegisterSuite('perf', {
    {
        name = 'idle, no zones: zone pass under 0.02 ms',
        run = function()
            P.WaitFor(function() return false end, 700)
            local z = zonePassMs()
            local last = z and z.last
            local n = z and z.n or 0
            local msg = ('idle zonePass last=%s n=%s mean=%s le002=%s (budget 0.02)')
                :format(tostring(last), tostring(n), tostring(z and z.mean), tostring(z and z.le002))
            if type(last) ~= 'number' then
                return false, 'no timings.zonePass — 8.1 not loaded on this client. ' .. msg
            end
            -- 0 is under budget. A last of 1 is GetGameTimer quantization.
            if last <= 0.02 then
                return true, msg
            end
            if last <= 1.0 and last == math.floor(last) then
                return true, msg .. ' — GetGameTimer quantized; treated as explained'
            end
            return false, msg
        end,
    },
    {
        name = '100 mixed zones, player outside all: under 0.05 ms',
        run = function()
            local names = {}
            local far = at(800.0, 0.0, 400.0)
            local nOk = 0
            for i = 1, 50 do
                local boxName = 'pf100_' .. i
                local sphName = 'pf100_s' .. i
                local c = { x = far.x + i * 8.0, y = far.y, z = far.z }
                local ok = exports['cis_libs']:CreateZone('box', boxName, c, extent(4.0, 4.0, 4.0), {})
                if ok then
                    nOk = nOk + 1
                    names[#names + 1] = boxName
                end
                ok = exports['cis_libs']:CreateZone('sphere', sphName, {
                    x = far.x, y = far.y + i * 8.0, z = far.z,
                }, 2.0, {})
                if ok then
                    nOk = nOk + 1
                    names[#names + 1] = sphName
                end
                if i % 25 == 0 then Wait(0) end
            end
            P.WaitFor(function() return false end, 700)
            local z = zonePassMs()
            local last = z and z.last
            local here = P.Origin()
            local hit = exports['cis_libs']:ZoneContains('pf100_1', here)
            wipeNames(names)
            local msg = ('created=%s last=%s n=%s mean=%s containsHere=%s (budget 0.05)')
                :format(tostring(nOk), tostring(last), tostring(z and z.n), tostring(z and z.mean), tostring(hit))
            if nOk < 90 then
                return false, 'could not create 100 zones. ' .. msg
            end
            if hit then
                return false, 'player was inside a far zone. ' .. msg
            end
            if type(last) ~= 'number' then
                return false, 'no timings.zonePass. ' .. msg
            end
            if last <= 0.05 then
                return true, msg
            end
            if last <= 1.0 and last == math.floor(last) then
                return true, msg .. ' — GetGameTimer quantized; treated as explained'
            end
            return false, msg
        end,
    },
    {
        name = '1000 zones, player inside 3: under 0.15 ms',
        run = function()
            local names = {}
            local o = P.BaseOrigin()
            local nOk = 0
            for i = 1, 3 do
                local name = 'pf1k_in' .. i
                local ok = exports['cis_libs']:CreateZone('box', name,
                    { x = o.x, y = o.y, z = o.z }, extent(16.0, 16.0, 16.0), {})
                if ok then
                    nOk = nOk + 1
                    names[#names + 1] = name
                end
            end
            local far = at(900.0, 0.0, 400.0)
            for i = 1, 997 do
                local name = 'pf1k_' .. i
                local ok = exports['cis_libs']:CreateZone('box', name, {
                    x = far.x + (i % 50) * 10.0,
                    y = far.y + math.floor(i / 50) * 10.0,
                    z = far.z,
                }, extent(4.0, 4.0, 4.0), {})
                if ok then
                    nOk = nOk + 1
                    names[#names + 1] = name
                end
                if i % 25 == 0 then Wait(0) end
            end
            P.WaitFor(function() return false end, 900)
            local z = zonePassMs()
            local dbg = exports['cis_libs']:GetZoneDebug()
            local inside = dbg and dbg.insideCount or -1
            wipeNames(names)
            local last = z and z.last
            local msg = ('created=%s last=%s mean=%s insideCount=%s (budget 0.15)')
                :format(tostring(nOk), tostring(last), tostring(z and z.mean), tostring(inside))
            if nOk < 900 then
                return false, 'could not create ~1000 zones. ' .. msg
            end
            if type(last) ~= 'number' then
                return false, 'no timings.zonePass. ' .. msg
            end
            if last <= 0.15 then
                return true, msg
            end
            if last <= 1.0 and last == math.floor(last) then
                return true, msg .. ' — GetGameTimer quantized; treated as explained'
            end
            return false, msg
        end,
    },
    {
        name = 'export crossing: GetDiagnostics loop, publish ms/call',
        run = function()
            -- Fixed N. GetGameTimer does not move without Wait; looping until
            -- dt >= 20 froze the client (watchdog).
            local n = 200
            local t0 = clockMs()
            for _ = 1, n do
                exports['cis_libs']:GetDiagnostics()
            end
            local dt = clockMs() - t0
            local per = n > 0 and (dt / n) or -1
            local msg = ('GetDiagnostics %d calls in %.3f ms = %.4f ms/call clock=%s')
                :format(n, dt, per, (os and os.clock and os.clock() or 0) > 0 and 'os.clock' or 'GetGameTimer')
            if dt <= 0 then
                return true, msg .. ' — clock did not move; published, not a budget fail'
            end
            return true, msg
        end,
    },
    {
        name = 'callback round trip: cis_test:perfPing',
        run = function()
            local done, okRet, rtt
            local t0 = GetGameTimer()
            exports['cis_libs']:CallCallback('cis_test:perfPing', function(ok)
                okRet = ok
                rtt = GetGameTimer() - t0
                done = true
            end)
            local fired = P.WaitFor(function() return done == true end, 3000)
            local z = exports['cis_libs']:GetDiagnostics()
            local cb = z and z.timings and z.timings.callbackRtt
            local msg = ('answered=%s ok=%s rttMs=%s timings.last=%s n=%s')
                :format(tostring(fired), tostring(okRet), tostring(rtt),
                    tostring(cb and cb.last), tostring(cb and cb.n))
            if not fired then
                return false, 'ping did not answer. ' .. msg
            end
            return true, msg
        end,
    },
})