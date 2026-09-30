-- Server-side mirror of who is online and what job they hold.
--
-- A companion resource needs to answer "how many cops are on right now" for
-- a dispatch balance, and it must not ask the client -- a client answering that
-- is a client a cheater controls. The framework already knows the answer, but
-- no single framework export answers "count across every job" without the
-- caller walking every player and resolving job objects itself. So the library
-- keeps its own histogram, fed by the framework's own load and job events.

local store = CisHistogram.new()

function CisJobCount(jobs)
    return CisHistogram.count(store, jobs)
end

-- Accepts a job table OR a bare job name, because the framework events are not
-- consistent about which they deliver: QBCore's job-update event carries a
-- table, ESX's carries a name, and normalising here means no consumer has to
-- know which framework it is running on.
function CisRememberJob(src, job)
    CisHistogram.set(store, src, job)
end

function CisForgetPlayer(src)
    CisHistogram.remove(store, src)
end

exports('GetOnlineJobCount', CisJobCount)

-- Not tidy: without it the store grows by one entry per connection for the life
-- of the process, and a stale entry is worse than a missing one -- a job count
-- would keep counting a player who left.
AddEventHandler('playerDropped', function()
    CisForgetPlayer(source)
end)
