-- The one server half of the owner test: a callback the client awaits on
-- entering the zone. It answers the server's clock, so a reply that arrives
-- is a reply the server sent.
local ok, why = Cis.callback.register('cis_libs_ownertest:ping', function(src)
    return os.time(), src
end)
if not ok then
    print(('[cis_libs_ownertest] RegisterCallback refused: %s'):format(tostring(why)))
end
