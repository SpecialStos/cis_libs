-- The streaming ENGINE: every asset kind the platform streams, not just models.
--
-- ONE SOURCE, TWO VMS. Pure functions and a constant table; no state. cis_libs
-- runs this as a client_script behind RequestModelTimeout and the seven kind
-- exports; a consumer's `Cis.streaming.*` loads the same text into its own VM,
-- so the request is the consumer's own (and released by it) and the poll yields
-- the caller's thread rather than a thread in another resource.

local M = {}

local DEFAULT_TIMEOUT_MS = 5000
-- The longest wait a caller may ask for: ten minutes is already no timeout.
local MAX_TIMEOUT_MS = 600000
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
        -- p1 is 31 in every script call of REQUEST_WEAPON_ASSET the native docs
        -- cite, and in ox_lib; 0 asked for none of the weapon's asset parts.
        requestArgs = function(hash) return hash, 31, 0 end,
    },
    scaleform = {
        request = 'RequestScaleformMovie',
        loaded = 'HasScaleformMovieLoaded',
        release = 'SetScaleformMovieAsNoLongerNeeded',
        -- The only kind whose request native ANSWERS something: it returns the movie
        -- HANDLE, and HAS_SCALEFORM_MOVIE_LOADED takes that handle -- not the name.
        -- Asked with the name, it never answers true, and every scaleform request
        -- waited out its whole timeout.
        handleFromRequest = true,
    },
    audioBank = {
        request = 'RequestScriptAudioBank',
        loaded = nil,
        -- The NAMED release. ReleaseScriptAudioBank() takes no argument and drops
        -- every bank this script holds, not the one that timed out.
        release = 'ReleaseNamedScriptAudioBank',
        -- REQUEST_SCRIPT_AUDIO_BANK is its own poll: it answers false while the
        -- bank is still loading and true once it is in, so it is CALLED AGAIN until
        -- true. One false is "not yet", not a refusal.
        requestIsPoll = true,
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
    -- A NaN deadline never passes (`now >= NaN` is false), so a NaN timeout
    -- polled for the rest of the session; an infinite one is the same thing.
    if timeout ~= nil then
        local ms = tonumber(timeout)
        if ms == nil or ms ~= ms or ms < 0 or ms > MAX_TIMEOUT_MS then
            return nil, ('%s timeout must be 0 to %d ms, got %s'):format(kind, MAX_TIMEOUT_MS, tostring(timeout))
        end
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
    -- Not for a scaleform: its probe takes a handle, and only a request makes one.
    if loaded and not spec.handleFromRequest and loaded(hash or name) then
        -- Already resident. Returning without a request is the point of asking twice,
        return hash or name
    end

    local request = native(spec.request)
    if not request then
        return nil, ('%s cannot be requested: %s is not available in this build')
            :format(kind, spec.request)
    end

    local deadline = GetGameTimer() + (tonumber(timeout) or DEFAULT_TIMEOUT_MS)

    if spec.requestIsPoll then
        while not request(spec.requestArgs(name)) do
            if GetGameTimer() >= deadline then
                local release = spec.release and native(spec.release) or nil
                if release then
                    pcall(release, name)
                end
                return nil, ('%s %q did not load within %sms')
                    :format(kind, tostring(name), tonumber(timeout) or DEFAULT_TIMEOUT_MS)
            end
            Wait(POLL_MS)
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
        if loaded and loaded(handle or hash or name) then
            return hash or name, handle
        end
        if GetGameTimer() >= deadline then
            -- THE RELEASE ON THE FAILURE BRANCH, and it is the whole reason this file
            local release = spec.release and native(spec.release) or nil
            if release then
                pcall(release, handle or (hash or name))
            end
            -- %s, not %d: a fractional timeout raised in Lua 5.4 on its way out.
            return nil, ('%s %q did not load within %sms')
                :format(kind, tostring(name), tonumber(timeout) or DEFAULT_TIMEOUT_MS)
        end
        Wait(POLL_MS)
    end
end

function M.model(model, timeout)
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

M.request = requestAsset

--- Release what a request loaded. The same native the timeout path uses, so a
--- caller that is done with an asset does not have to know which of eight
--- release natives (and which argument: a handle for a scaleform, a hash for a
--- model) applies. Answers whether a release native was called.
function M.release(kind, asset)
    local spec = KINDS[kind]
    if not spec or not spec.release or asset == nil then
        return false
    end
    local release = native(spec.release)
    if not release then
        return false
    end
    if spec.returnsHash then
        asset = hashOf(asset)
    end
    release(asset)
    return true
end

-- The kind names, sorted, for a refusal that has to list them.
function M.kinds()
    local valid = {}
    for k in pairs(KINDS) do valid[#valid + 1] = k end
    table.sort(valid)
    return valid
end

-- A MODULE. Published under CisCore when cis_libs runs it as a client_script.
if ... ~= 'cis_require' then
    CisCore = CisCore or {}
    CisCore.streaming = M
end

return M
