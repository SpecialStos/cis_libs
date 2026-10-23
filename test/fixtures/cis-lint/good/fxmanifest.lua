fx_version 'cerulean'
game 'gta5'
lua54 'yes'

dependencies {
    '/server:5848',
    '/onesync',
}

ui_page 'web/index.html'
files { 'web/index.html', 'web/style.css', 'web/app.js' }
client_scripts { 'client.lua' }
server_scripts { 'server/*.lua' }
