fx_version 'bodacious'
game 'gta5'

name "Store Robberies Evolved"
description "The best store robbery system for FiveM."
author "Cisoko"
version "2.6.5"
lua54 'yes'

dependencies {
    "PolyZone",
    '/onesync',
    '/server:4500',
}

client_scripts {
    '@PolyZone/client.lua',
    '@PolyZone/BoxZone.lua',
    'client/polyzone.lua',
    'client/stores.lua',
    'client/commands_encrypted.lua',
    'client/events.lua',
    'client/mainLoop.lua',
    'client/ai_npc_encrypted.lua',
    'client/ai_npc_open.lua',
    'client/doorlock.lua',
    'client/framework.lua',
    'client/lockpick.lua',
    'client/safeCracking.lua',
    'client/blips.lua',
    'utils.lua'
}

server_scripts {
    'configs/security_config.lua',
    'configs/discordLogs_config.lua',
    'configs/stores_config.lua',
    'configs/master_config.lua',
    'configs/ai_config.lua',
    'server/mainLoop.lua',
    'server/discord.lua',
    'server/events.lua',
    'server/framework.lua',
    'server/ai_npc_encrypted.lua',
    'server/versionCheck.lua',
}

shared_scripts {
    'shared/functions.lua',
    'shared/security_encrypted.lua'
    --"@es_extended/imports.lua" --UNCOMMENT ME IF YOU ARE USING ESX LEGACY.
}

ui_page "client/html/index.html"

files {
    'client/html/index.html',
    'client/html/css/style.css',
    'client/html/css/reset.css',
    'client/html/sounds/*.ogg',
    'client/html/js/script.js',
    'client/html/css/img/*.png',
}

escrow_ignore {
    'utils.lua',
    'client/blips.lua',
    'client/doorlock.lua',
    'client/events.lua',
    'client/framework.lua',
    'client/lockpick.lua',
    'client/mainLoop.lua',
    'client/polyzone.lua',
    'client/ai_npc_open.lua',
    'client/safeCracking.lua',
    'client/html/css/reset.css',
    'client/html/css/style.css',
    'client/html/js/script.js',
    'client/html/index.html',
    'client/stores.lua',

    'configs/security_config.lua',
    'configs/discordLogs_config.lua',
    'configs/stores_config.lua',
    'configs/master_config.lua',
    'configs/ai_config.lua',
    'server/mainLoop.lua',
    'server/discord.lua',
    'server/events.lua',
    'server/framework.lua',
    'server/versionCheck.lua',

    'shared/functions.lua',
    
}
