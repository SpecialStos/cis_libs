Security = {}
Security.EventPrefix = "cis_BetterFightEvolved" -- The prefix for all the events. This is used to prevent unauthorized events from being triggered.
Security.Debug = false -- Enable debug mode (Prints in server console)
Security.AuthorizedResources = { -- Authorized resources that can trigger events
    "example", --Add your resources here.
}

--DROP PLAYER -- ADD YOUR CODE HERE -- 
Security.DropPlayer = true -- Drop the player if a blocked event is triggered
function cisAnticheatDropPlayer(src) --Edit Me.
    DropPlayer(src, "cis_anticheat: Kicked for cheating. If you believe this is a mistake, please contact the server owner.")
end
--DROP PLAYER -- ADD YOUR CODE HERE -- 

--CUSTOM ALERT HERE--
RegisterServerEvent('cis_BetterFightEvolved_anticheat:server:alert')
AddEventHandler('cis_BetterFightEvolved_anticheat:server:alert', function(message)
    local src = source

	TriggerEvent(Security.EventPrefix .. ":server:log", message, "cheating")

	if(Security.DropPlayer)then
		cisAnticheatDropPlayer(src)
	end
end)
--CUSTOM ALERT HERE--