-- The owner test's consumer: one zone, twenty points, a text UI and a callback,
-- made around the player on demand so client resmon can be read against the
-- active bar in docs/V1.md section 4. Steps: docs/OWNER-TEST.md.
fx_version 'cerulean'
game 'gta5'
lua54 'yes'

name 'cis_libs_ownertest'
description 'cis_libs owner test consumer (not shipped)'
version '1.0.0'

dependency 'cis_libs'
shared_script '@cis_libs/init.lua'

client_script 'client.lua'
server_script 'server.lua'
