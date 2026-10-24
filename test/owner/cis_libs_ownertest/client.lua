-- `/cis_ownertest` builds the active case around the player: a 10 m sphere
-- zone that shows a text UI and awaits a server callback on entry, and twenty
-- points on a 6 m ring, each 8 m wide, so standing at the centre is inside all
-- of them. `/cis_ownertest_clear` removes everything, which is the idle case.
local ZONE = 'cis_libs_ownertest'
local POINTS = 20
local RING_M = 6.0
local POINT_M = 8.0
local ZONE_M = 10.0

local points = {}
local inside = 0

local function say(text)
    print('[cis_libs_ownertest] ' .. text)
    Cis.ui.notify(text, 'inform')
end

local function clear()
    for i = 1, #points do
        Cis.points.remove(points[i])
    end
    points = {}
    inside = 0
    Cis.zones.remove(ZONE)
    Cis.ui.textUI.hide()
end

RegisterCommand('cis_ownertest', function()
    clear()
    local c = GetEntityCoords(PlayerPedId())
    local ok, why = Cis.zones.sphere(ZONE, c, ZONE_M, {
        onEnter = function()
            Cis.ui.textUI.show('[cis_libs] owner test zone')
            CreateThread(function()
                local okCb, serverTime = Cis.callback.tryAwait('cis_libs_ownertest:ping')
                say(('callback ok=%s server time=%s'):format(tostring(okCb), tostring(serverTime)))
            end)
        end,
        onExit = function()
            Cis.ui.textUI.hide()
        end,
    })
    if not ok then
        say('zone refused: ' .. tostring(why))
        return
    end
    for i = 1, POINTS do
        local a = (i - 1) * (2 * math.pi / POINTS)
        local id, reason = Cis.points.add({
            coords = vector3(c.x + RING_M * math.cos(a), c.y + RING_M * math.sin(a), c.z),
            distance = POINT_M,
            onEnter = function() inside = inside + 1 end,
            onExit = function() inside = inside - 1 end,
        })
        if not id then
            say(('point %d refused: %s'):format(i, tostring(reason)))
            return
        end
        points[#points + 1] = id
    end
    say(('built: 1 zone, %d points. Step out and back in to see the text UI.'):format(#points))
end, false)

RegisterCommand('cis_ownertest_status', function()
    say(('zones now: %s; points inside: %d of %d'):format(
        table.concat(Cis.zones.getCurrent(), ','), inside, #points))
end, false)

RegisterCommand('cis_ownertest_clear', function()
    clear()
    say('cleared: no zone, no point, no text UI')
end, false)
