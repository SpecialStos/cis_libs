-- cis_libs — shared boundary. Owns no table, no config file, no framework.
-- ensure cis_libs first. Consumers need a dependency and the init shared_script.
-- OneSync on. Server build 4500+. api.lua is the contract; not loaded at runtime.

fx_version 'cerulean'
game 'gta5'

name "Cisoko - Library System"
description "Zero-dependency shared library. Owns no table, no config, no framework."
author "Cisoko"
version "1.0.0"
lua54 'yes'

dependencies {
    '/onesync',
    '/server:4500',
}

-- Load order is load-bearing: identity before anything that could run as a
-- rename, diagnostics before loops, defaults/registry before config, init.lua
-- last so it captures a complete exports table.
-- Folder name must stay cis_libs (LICENSE.md). Consumers never load identity.lua.
shared_scripts {
    'shared/identity.lua',
    'shared/diagnostics.lua',
    'shared/timing.lua',
    'shared/loopguard.lua',
    'shared/defaults.lua',
    'shared/registry.lua',
    'shared/grid.lua',
    'shared/zonegeom.lua',
    'shared/hooks.lua',
    'shared/pending.lua',
    'shared/owned.lua',
    'shared/config.lua',
    'shared/histogram.lua',
    'shared/ready.lua',
    'shared/detect.lua',
    'shared/statebag.lua',
    'init.lua',
}

-- Declared for Cis.require, not executed at boot.
-- Quoted paths only: a test harness matches .lua paths anywhere in this file.
files {
    'shared/algo/curve.lua',
    'shared/algo/heap.lua',
    'shared/algo/interp.lua',
    'shared/algo/lru.lua',
    'shared/algo/random.lua',
    'shared/algo/rate.lua',
    'shared/algo/sparse.lua',
    'shared/algo/window.lua',
    'shared/util/id.lua',
    'shared/util/json.lua',
    'shared/util/semver.lua',
    'shared/util/string.lua',
    'shared/util/table.lua',
    'shared/util/time.lua',
    'shared/util/validate.lua',
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
    'client/points.lua',
    'client/world.lua',
    'client/raycast.lua',
    'client/keybind.lua',
    'client/ui.lua',
    'client/callback.lua',
    'client/target.lua',
    'client/proxy.lua',
    'client/sync.lua',
}

server_scripts {
    'server/logging.lua',
    'server/security.lua',
    'server/callback.lua',
    'server/player.lua',
    'server/version.lua',
    'server/proxy.lua',
    'server/sync.lua',
    'server/command.lua',
    'server/zones.lua',
    'server/initialize.lua',
    'server/selfcheck.lua',
}
