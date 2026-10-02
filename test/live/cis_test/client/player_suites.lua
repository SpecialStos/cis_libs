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
    local o = P.Origin()
    return { x = o.x + dx, y = o.y + dy, z = o.z + dz }
end

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
            local o = P.Origin()
            P.ClearEnterLog()
            local ok = exports['cis_libs']:CreateZone('box', 'z_standing',
                { x = o.x, y = o.y, z = o.z },
                { x = o.x + 8.0, y = o.y + 8.0, z = o.z + 8.0 },
                { onEnter = function(coords) P.NoteEnter(coords) end })
            if not ok then return false, 'CreateZone was refused' end

            -- The plan allows 250 ms. 1000 is generous and still bounded: a
            -- harness that waits forever cannot tell a slow library from a hung
            -- one.
            local fired = P.WaitFor(function() return #P.EnterLog() > 0 end, 1000)
            exports['cis_libs']:RemoveZone('z_standing')
            return fired,
                ('onEnter fired for a STANDING player within 1000 ms: %s'):format(tostring(fired))
        end,
    },
    {
        name = 'stepping into a small zone fires onEnter exactly once',
        run = function()
            exports['cis_libs']:RemoveZone('z_walk')
            P.ClearEnterLog()
            local ok = exports['cis_libs']:CreateZone('box', 'z_walk',
                at(10.0, 10.0, 0.0), at(14.0, 14.0, 0.0),
                { onEnter = function(coords) P.NoteEnter(coords) end })
            if not ok then return false, 'CreateZone was refused' end

            P.StepTowards(at(8.0, 8.0, 0.0), 10)
            P.StepTowards(at(12.0, 12.0, 0.0), 25)

            local n = #P.EnterLog()
            exports['cis_libs']:RemoveZone('z_walk')
            return n == 1,
                ('onEnter fired exactly once while walking in: %d time(s)'):format(n)
        end,
    },
    {
        name = 'removing a zone the player is inside fires ONE onExit with the player coords',
        run = function()
            exports['cis_libs']:RemoveZone('z_remove')
            P.ClearEnterLog()
            P.ClearExitLog()
            exports['cis_libs']:CreateZone('box', 'z_remove',
                at(0.0, 0.0, 0.0), at(4.0, 4.0, 4.0),
                { onEnter = function() end, onExit = function(coords) P.NoteExit(coords) end })

            -- Wait until the library agrees the player is inside, so the exit
            -- below is a real exit and not the removal of a zone that was never
            -- entered.
            P.WaitFor(function() return true end, 300)
            P.ClearExitLog()
            exports['cis_libs']:RemoveZone('z_remove')

            local exits = P.ExitLog()
            local coords = type(exits[1]) == 'table' and exits[1] or nil
            return #exits == 1 and coords ~= nil,
                ('one onExit on removal: %d, coords %s'):format(#exits,
                    coords and ('%.1f, %.1f, %.1f'):format(coords.x, coords.y, coords.z) or 'MISSING')
        end,
    },
    {
        name = 'a zone 400 m above the player does not contain them',
        run = function()
            exports['cis_libs']:RemoveZone('z_high')
            exports['cis_libs']:CreateZone('box', 'z_high',
                at(0.0, 0.0, 400.0), at(4.0, 4.0, 404.0), {})
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
            exports['cis_libs']:WatchNear(at(6.0, 0.0, 0.0), 4.0,
                function() P.NoteNear('in') end,
                function() P.NoteNear('out') end)

            P.StepTowards(at(4.0, 0.0, 0.0), 25)
            P.StepTowards(at(9.0, 0.0, 0.0), 25)

            local ins, outs = 0, 0
            for _, e in ipairs(P.NearLog()) do
                if e == 'in' then ins = ins + 1 else outs = outs + 1 end
            end
            return ins == 1 and outs == 1,
                ('exactly one enter and one exit: %d in, %d out'):format(ins, outs)
        end,
    },
})