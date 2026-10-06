-- Server-side mirror of who is online and what job they hold.

local store = CisHistogram.new()

function CisJobCount(jobs)
    return CisHistogram.count(store, jobs)
end

-- Accepts a job table OR a bare job name, because the framework events are not
function CisRememberJob(src, job)
    CisHistogram.set(store, src, job)
end

function CisForgetPlayer(src)
    CisHistogram.remove(store, src)
end

exports('GetOnlineJobCount', CisJobCount)

-- Not tidy: without it the store grows by one entry per connection for the life of the
AddEventHandler('playerDropped', function()
    CisForgetPlayer(source)
end)
