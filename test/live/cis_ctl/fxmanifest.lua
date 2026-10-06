-- The agent's console. Not shipped, not part of the library, never deployed to
-- a production server.
--
-- ONE SERVER SCRIPT AND NO CLIENT FILES, deliberately. This resource exists so
-- the agent never types into a web console, and every line of it is attack
-- surface for that capability: a client script would run on a player's machine
-- and the whole point of the file bridge is that the command arrives from the
-- server side, over the server's own file, with the server doing the deciding.
--
-- NO dependencies BLOCK. If it declared one, starting it would drag cis_libs
-- and the harness with it, and the one thing a recovery tool must survive is
-- those resources being in a bad state. It depends on nothing, so it is up
-- whenever they are down.
--
-- WHAT IT MAY WRITE. inbox.json and outbox.json in its own folder, nothing
-- else. cis_libs writes no files at all; that boundary is enforced against the
-- library and is deliberately not inherited by this or the harness.

fx_version 'cerulean'
game 'gta5'
lua54 'yes'

name 'cis_ctl'
description 'Command-file console bridge for the cis_libs live harness. Not shipped.'
author 'cis_libs'
version '0.0.0'

server_script 'server/ctl.lua'