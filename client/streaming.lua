-- Streaming for every asset kind the platform streams, not just models.

local DEFAULT_TIMEOUT_MS = 5000
local POLL_MS = 50

-- The one kind that has no existence probe.
local KINDS = {
    model = {
        request = 'RequestModel',
        loaded = 'HasModelLoaded',
        release = 'SetModelAsNoLongerNeeded',
        -- Models are the one kind where the hash is what a caller needs back: the
        returnsHash = true,
        -- IN_CDIMAGE only. IsModelValid is false for many legal props until they have
        valid = function(hash) return IsModelInCdimage(hash) end,
        invalid = function(hash) return not IsModelInCdimage(hash) end,
    },
    animDict = {
        request = 'RequestAnimDict',
        loaded = 'HasAnimDictLoaded',
        release = 'RemoveAnimDict',
        exists = 'DoesAnimDictExist',
    },
    animSet = {
        request = 'RequestAnimSet',
        loaded = 'HasAnimSetLoaded',
        release = 'RemoveAnimSet',
    },
    ptfx = {
        request = 'RequestNamedPtfxAsset',
        loaded = 'HasNamedPtfxAssetLoaded',
        release = 'RemoveNamedPtfxAsset',
    },
    textureDict = {
        request = 'RequestStreamedTextureDict',
        loaded = 'HasStreamedTextureDictLoaded',
        release = 'SetStreamedTextureDictAsNoLongerNeeded',
        -- The second argument is the streamed flag, and it is NOT optional in the
        requestArgs = function(name) return name, true end,
    },
    weaponAsset = {
        request = 'RequestWeaponAsset',
        loaded = 'HasWeaponAssetLoaded',
        release = 'RemoveWeaponAsset',
        requestArgs = function(hash) return hash, 0, 0 end,
    },
    scaleform = {
        request = 'RequestScaleformMovie',
        loaded = 'HasScaleformMovieLoaded',
        release = 'SetScaleformMovieAsNoLongerNeeded',
        -- The only kind whose request native ANSWERS something: it returns the movie
        handleFromRequest = true,
    },
    audioBank = {
        request = 'RequestScriptAudioBank',
        loaded = nil,
        release = 'ReleaseScriptAudioBank',
        -- `RequestScriptAudioBank` returns BOOL directly -- there is nothing to poll --
        answersDirectly = true,
        requestArgs = function(name) return name, false end,
    },
}

-- A number is a hash, a string is joaat'd.
local function hashOf(asset)
    if type(asset) == 'number' then
        return asset
    end
    return joaat(asset)
end

-- Resolving a native name to the function, at CALL time and never cached in a local at
local function native(name)
    -- `_ENV` first. The lua54 suite loads this file into a sandbox whose stubs live on
    local fn = _ENV[name]
    if type(fn) ~= 'function' then
        fn = _G[name]
    end
    if type(fn) ~= 'function' then
        return nil, name
    end
    return fn
end

--- Request one asset of `kind` and wait for it.
--- @return `asset, reason` on success, or `nil, reason` on refusal. The asset
local function requestAsset(kind, asset, timeout)
    local spec = KINDS[kind]
    if not spec then
        local valid = {}
        for k in pairs(KINDS) do valid[#valid + 1] = k end
        table.sort(valid)
        return nil, ('unknown asset kind %q; valid kinds are %s')
            :format(tostring(kind), table.concat(valid, ', '))
    end
    if asset == nil then
        return nil, ('%s was requested with no asset name'):format(kind)
    end
    if type(asset) ~= 'string' and type(asset) ~= 'number' then
        return nil, ('%s was requested with a %s; a name or a hash, not %s')
            :format(kind, type(asset), type(asset))
    end

    -- The hash, for the kinds that are keyed by one.
    local name = type(asset) == 'string' and asset or nil
    local hash = (name == nil or spec.returnsHash) and hashOf(asset) or nil

    -- EXISTENCE FIRST, for the one kind that can answer it cheaply.
    if spec.exists then
        local probe = native(spec.exists)
        if probe and not probe(name) then
            return nil, ('%s %q does not exist on this server'):format(kind, tostring(name))
        end
    end

    local loaded = spec.loaded and native(spec.loaded) or nil
    if loaded and loaded(hash or name) then
        -- Already resident. Returning without a request is the point of asking twice,
        return hash or name
    end

    local request = native(spec.request)
    if not request then
        return nil, ('%s cannot be requested: %s is not available in this build')
            :format(kind, spec.request)
    end

    local deadline = GetGameTimer() + (tonumber(timeout) or DEFAULT_TIMEOUT_MS)

    if spec.answersDirectly then
        -- A BOOL answer and nothing to poll.
        local ok = request(spec.requestArgs(name))
        if not ok then
            return nil, ('the engine refused %s %q'):format(kind, tostring(name))
        end
        return name
    end

    local handle
    if spec.handleFromRequest then
        handle = request(name)
        if not handle or handle == 0 then
            return nil, ('the engine refused %s %q'):format(kind, tostring(name))
        end
    elseif spec.requestArgs then
        -- AN EXPLICIT BRANCH, and not `spec.requestArgs and spec.requestArgs(x) or x`.
        request(spec.requestArgs(hash or name))
    else
        request(hash or name)
    end

    while true do
        if loaded and loaded(hash or name) then
            return hash or name, handle
        end
        if GetGameTimer() >= deadline then
            -- THE RELEASE ON THE FAILURE BRANCH, and it is the whole reason this file
            local release = spec.release and native(spec.release) or nil
            if release then
                pcall(release, handle or (hash or name))
            end
            return nil, ('%s %q did not load within %dms')
                :format(kind, tostring(name), tonumber(timeout) or DEFAULT_TIMEOUT_MS)
        end
        Wait(POLL_MS)
    end
end

function RequestModelTimeout(model, timeout)
    -- Published shape: the first slot
    local hash = hashOf(model)
    -- Do not ask IsModelValid here.
    if IsModelInCdimage(hash) then
        local got, why = requestAsset('model', hash, timeout)
        if got then
            return true, hash
        end
        return false, hash, why
    end
    return false, hash, ('model %s is not in the cdimage'):format(tostring(model))
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
