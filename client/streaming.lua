-- Model streaming. The one place a `Wait` loop is correct, because there is no
-- event for a model finishing loading -- only the poll can find out.
--
-- The IsModelInCdimage/IsModelValid pair runs BEFORE the wait so a bad hash
-- returns immediately instead of sitting out the whole timeout. Both the
-- loaded flag and the hash are returned, because the caller usually needs the
-- hash for the CreatePed/CreateObject call and re-hashing it is a chance to
-- disagree with the value that was validated here.

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
