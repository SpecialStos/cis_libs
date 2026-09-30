-- =============================================================================
--  CIsoko Library System -- framework bridge for FiveM
--
--  WHAT THIS IS: a library, not a standalone script. On its own it shows
--  nothing and does nothing visible. It exists to be CONSUMED by your own
--  resources, which call it through its exports and its net events:
--
--      local doors = exports["cis_libs"]:GetClosestDoor(coords)
--
--  It depends on no other library -- not ox_lib, not PolyZone. It sits beside
--  your framework (ESX / ESX-LEGACY / QBCore / QBOX) and, where you use them,
--  beside ox_inventory and ox_target, which it detects rather than requires.
--
--  START ORDER -- THIS IS THE ONE THAT BITES PEOPLE:
--
--      ensure cis_libs        -- must come FIRST
--      ensure my_resource     -- anything that consumes it, AFTER
--
--  In your server.cfg, cis_libs has to be started before every resource that
--  uses it, and it has to be started before your framework's own scripts if you
--  want framework helpers available on the first frame. A consumer that starts
--  first finds no exports and fails on its first call, usually with a nil index
--  that points nowhere near the cause. To be immune to ordering entirely, add
--  a dependency to the CONSUMING resource instead:
--
--      dependencies { 'cis_libs' }
--
--  REQUIREMENTS, both enforced below and not negotiable:
--
--    * OneSync must be on. This library reads and mutates entity state on both
--      sides of the wire and cannot run in legacy session mode.
--    * Server build 4500 or newer. Older builds lack natives this calls; they
--      fail at the call, not at startup, so the symptom is a runtime error in
--      your console rather than a refused boot.
--
--  api.lua IS DELIBERATELY NOT LISTED BELOW, and that is intentional. It is the
--  machine-readable data contract -- every export, every net event, every
--  argument and return shape -- written as a Lua table so tools can read it.
--  It defines nothing and runs nothing. Listing it here would only load it
--  into the Lua state at every boot and cache a copy per client for no gain.
--  Read it on demand instead: it is documentation a machine can check, and
--  `npm run test:api` validates it against the real registered surface.
--
--  Configuration lives in configs/ -- start with configs/master_config.lua.
-- =============================================================================

fx_version 'cerulean'
game 'gta5'

name "Cisoko - Library System - Framework Bridge"
description "A standalone library and framework bridge for FiveM resources."
author "Cisoko"
version "1.0.0"
lua54 'yes'

dependencies {
    '/onesync',
    '/server:4500',
}

shared_scripts {
    'shared/grid.lua',
    'shared/pending.lua',
    'shared/config.lua',
    'shared/histogram.lua',
    'shared/ready.lua',
    'shared/detect.lua',
    'init.lua',
}

client_scripts {
    'client/initialize.lua',
    'client/logging.lua',
    'client/streaming.lua',
    'client/utils.lua',
    'client/weapon.lua',
    'client/vehicle.lua',
    'client/cache.lua',
    'client/zones.lua',
    'client/callback.lua',
    'client/inventory.lua',
    'framework/framework_client.lua',
    'client/target.lua',
    'client/doorlock.lua',
    'client/sync.lua',
}

server_scripts {
    'configs/master_config.lua',
    'configs/discordLogs_config.lua',
    'configs/security_config.lua',
    'server/discord.lua',
    'server/logging.lua',
    'server/security.lua',
    'server/callback.lua',
    'server/player.lua',
    'server/database.lua',
    'server/inventory.lua',
    'framework/framework_server.lua',
    'server/doorlock.lua',
    'server/sync.lua',
    'server/initialize.lua',
    'server/version.lua',
}
