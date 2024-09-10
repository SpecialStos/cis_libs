fx_version 'bodacious'
game 'gta5'

name "Cisoko - Library System"
description "A library system for FiveM resources."
author "Cisoko"
version "0.1.0"
lua54 'yes'

dependencies {
    '/onesync',
    '/server:4500',
}

client_scripts {
    'client/initialize.lua',
    'client/core.lua',
    'client/utils.lua',
    'client/vehicle.lua',
    'client/weapon.lua',
}

server_scripts {
    'configs/master_config.lua',
    'configs/discordLogs_config.lua',
    'configs/security_config.lua',
    'server/discord.lua',
    'server/initialize.lua',
    'server/events.lua',
}

shared_scripts {
    'shared/functions.lua',
    'shared/security_encrypted.lua'
    --"@es_extended/imports.lua" --UNCOMMENT ME IF YOU ARE USING ESX LEGACY.
}