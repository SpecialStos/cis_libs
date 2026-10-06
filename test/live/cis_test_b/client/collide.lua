-- cis_test_b's client half: the same zone name and the same target name
-- cis_test uses.
--
-- The zone collision is the interesting one. A zone name is the key a product
-- looks its own zone up by, so if two resources share a name and the second one
-- silently takes it, the first stops getting its enter and exit callbacks and
-- finds out when a player walks somewhere they should not be. That is
-- invisible in a unit test and obvious on a live server, which is why it is
-- here.

CisTestBClient = { created = {}, refusals = {} }

local function note(kind, key, detail)
    CisTestBClient.created[#CisTestBClient.created + 1] = { kind = kind, key = key, detail = detail }
    print(('[cis_test_b:client] %s %s %s'):format(kind, key, tostring(detail)))
end

exports('Created', function() return CisTestBClient.created end)
exports('Refusals', function() return CisTestBClient.refusals end)
exports('Clear', function()
    CisTestBClient.created = {}
    CisTestBClient.refusals = {}
    return true
end)

-- The SAME names cis_test uses. If ownership is enforced these are separate
-- objects and both resources keep their own; if it is not, one of them has
-- silently lost its zone.
exports('CreateCollidingZone', function()
    local ok, why = exports['cis_libs']:CreateZone('box', 'shared-zone',
        { x = 0.0, y = 0.0, z = 0.0 }, { x = 8.0, y = 8.0, z = 8.0 }, {})
    if ok then
        note('zone', 'shared-zone', 'created')
    else
        CisTestBClient.refusals[#CisTestBClient.refusals + 1] = {
            kind = 'zone', key = 'shared-zone', why = why,
        }
        print(('[cis_test_b:client] zone shared-zone refused: %s'):format(tostring(why)))
    end
    return ok, why
end)

-- And one under its OWN name, so the resource can prove it still has one zone
-- even after colliding. A resource that ended up with nothing at all would look
-- identical to a resource that was correctly refused, and those need telling
-- apart.
exports('CreateOwnZone', function()
    local ok, why = exports['cis_libs']:CreateZone('box', 'cis_test_b_zone',
        { x = 0.0, y = 0.0, z = 0.0 }, { x = 4.0, y = 4.0, z = 4.0 }, {})
    if ok then
        note('zone', 'cis_test_b_zone', 'created')
    else
        print(('[cis_test_b:client] own zone refused: %s'):format(tostring(why)))
    end
    return ok, why
end)

exports('RemoveZones', function()
    exports['cis_libs']:RemoveZone('shared-zone')
    exports['cis_libs']:RemoveZone('cis_test_b_zone')
    return true
end)