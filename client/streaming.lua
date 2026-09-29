local function hashOf(model)
    if type(model) == 'number' then
        return model
    end
    return joaat(model)
end

function RequestModelTimeout(model, timeout)
    local hash = hashOf(model)
    if not IsModelInCdimage(hash) or not IsModelValid(hash) then
        return false, hash
    end
    if HasModelLoaded(hash) then
        return true, hash
    end
    RequestModel(hash)
    local deadline = GetGameTimer() + (timeout or 5000)
    while not HasModelLoaded(hash) and GetGameTimer() < deadline do
        Wait(50)
    end
    if not HasModelLoaded(hash) then
        return false, hash
    end
    return true, hash
end

exports('RequestModelTimeout', RequestModelTimeout)
