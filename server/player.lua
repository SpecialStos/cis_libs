local store = CisHistogram.new()

function CisJobCount(jobs)
    return CisHistogram.count(store, jobs)
end

function CisRememberJob(src, job)
    CisHistogram.set(store, src, job)
end

function CisForgetPlayer(src)
    CisHistogram.remove(store, src)
end

exports('GetOnlineJobCount', CisJobCount)

AddEventHandler('playerDropped', function()
    CisForgetPlayer(source)
end)
