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
