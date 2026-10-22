-- cis_libs' streaming exports: the engine in client/core/streaming.lua. A
-- consumer's `Cis.streaming.*` runs the same text in its own VM.

local Streaming = CisCore.streaming
local requestAsset = Streaming.request

function RequestModelTimeout(model, timeout)
    return Streaming.model(model, timeout)
end

-- Exported under its own name rather than through the
exports('RequestModelTimeout', RequestModelTimeout)

-- SEVEN LITERAL REGISTRATIONS, and the loop that was here instead is why four of them
exports('AnimDict', function(name, timeout) return requestAsset('animDict', name, timeout) end)
exports('AnimSet', function(name, timeout) return requestAsset('animSet', name, timeout) end)
exports('Ptfx', function(name, timeout) return requestAsset('ptfx', name, timeout) end)
exports('TextureDict', function(name, timeout) return requestAsset('textureDict', name, timeout) end)
exports('WeaponAsset', function(name, timeout) return requestAsset('weaponAsset', name, timeout) end)
exports('Scaleform', function(name, timeout) return requestAsset('scaleform', name, timeout) end)
exports('AudioBank', function(name, timeout) return requestAsset('audioBank', name, timeout) end)

CisDiagnostics.Register('client', 'streaming', function()
    -- Counts and queries, which are the only two things that can be asked about the
    return {
        pending = GetNumberOfStreamingRequests(),
        allComplete = HaveAllStreamingRequestsCompleted(),
    }
end)
