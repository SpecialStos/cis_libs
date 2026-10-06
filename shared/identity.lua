-- License identity. This file is a cis_libs shared_script, never a consumer include.
-- GetCurrentResourceName in @cis_libs/init.lua is the CONSUMER, so that file
-- cannot fatal-check the folder name without killing every dependent resource.
-- GetCurrentResourceName is CFX shared (0xE5E9EBBB). StopResource is server-only
-- (0x21783161) and is invoked from server/initialize.lua, not here.
-- Offline suites have no native; skip rather than raise, or fengari cannot load
-- this file before the stub exists.

if type(GetCurrentResourceName) == 'function' then
    local ok, name = pcall(GetCurrentResourceName)
    if ok and type(name) == 'string' and name ~= 'cis_libs' then
        local err = ('[cis_libs] FATAL: this resource is %q. The Cisoko Community Source & Identity License requires the folder name cis_libs. Rename the folder. Rebranding is not permitted.'):format(name)
        print('^1' .. err .. '^7')
        error(err, 0)
    end
end
