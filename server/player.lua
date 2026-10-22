-- Server-side mirror of who is online and what job they hold.

local store = CisHistogram.new()

function CisJobCount(jobs)
    return CisHistogram.count(store, jobs)
end

-- Accepts a job table OR a bare job name, because the framework events are not
-- ONLY A CONNECTED PLAYER IS REMEMBERED. Only playerDropped removes an entry, so
-- an id nobody holds would be counted -- as an on-duty officer, say -- until the
-- server restarts.
function CisRememberJob(src, job)
    if type(src) ~= 'number' or src <= 0 or not GetPlayerName(src) then
        return false
    end
    CisHistogram.set(store, src, job)
    return true
end

function CisForgetPlayer(src)
    CisHistogram.remove(store, src)
end

exports('GetOnlineJobCount', CisJobCount)

-- Not tidy: without it the store grows by one entry per connection for the life of the
AddEventHandler('playerDropped', function()
    CisForgetPlayer(source)
end)
