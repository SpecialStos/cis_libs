fx_version 'cerulean'
game 'gta5'

name "Cisoko - Library System - Framework Bridge"
description "A library system & framework bridge for FiveM resources."
author "Cisoko"
version "0.1.0"
lua54 'yes'

dependencies {
    '/onesync',
    '/server:4500',
}

client_scripts {
    '@ox_lib/init.lua',
    '@PolyZone/client.lua', 
    '@PolyZone/BoxZone.lua',
    'client/initialize.lua',
    'client/core.lua',
    'client/utils.lua',
    'client/vehicle.lua',
    'client/weapon.lua',
    'client/logging.lua',
    'client/polyzones.lua',
    'client/doorlock.lua',
    'client/target.lua',
    'framework/framework_client.lua',
}

server_scripts {
    'configs/master_config.lua',
    'configs/discordLogs_config.lua',
    'configs/security_config.lua',
    'framework/framework_server.lua',
    'server/discord.lua',
    'server/database.lua',
    'server/initialize.lua',
    'server/logging.lua',
    'server/doorlock.lua',
    'server/server_error_handler.lua',
    'server/versionCheck.lua',
}

shared_scripts {}