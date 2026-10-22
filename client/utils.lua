-- Shared client helpers. Stateless.
--
-- NO NATIVE IS REBOUND HERE. CreatePed and GetDistanceBetweenCoords used to be
-- globals that REPLACED the game natives of those names for every file in
-- cis_libs -- the distance one dropping the native's `useZ` argument on the way.
-- The wrappers are CisCreatePed and CisGetDistanceBetweenCoords; the exports keep
-- their published names.

function DebugLog(message)
    if Config and Config.Printing and Config.Printing.Debug then
        print('[cis_libs] ' .. tostring(message))
    end
end

-- Returns 0 rather than nil on failure, so every caller can test one shape.
-- A ped handle is never nil; "0" is the game's own "no entity" and comparing
-- it needs no special case at each call site.
function CisCreatePed(model, coords, heading, options)
    options = options or {}
    -- Refused before the model is requested: indexing a nil coords raised inside
    -- the caller's export call AFTER the model had been loaded and never released.
    if type(coords) ~= 'table' and type(coords) ~= 'vector3' and type(coords) ~= 'vector4' then
        DebugLog('CisCreatePed received no coords: ' .. tostring(coords))
        return 0
    end
    if type(coords.x) ~= 'number' or type(coords.y) ~= 'number' or type(coords.z) ~= 'number' then
        DebugLog('CisCreatePed received coords with no numeric x/y/z')
        return 0
    end
    local loaded, modelHash = RequestModelTimeout(model, options.timeout or 5000)
    if not loaded then
        DebugLog('CisCreatePed received an invalid or unloaded model: ' .. tostring(model))
        return 0
    end

    local ped = CreatePed(
        options.pedType or 4,
        modelHash,
        coords.x,
        coords.y,
        coords.z,
        heading or 0.0,
        options.networked ~= false,
        options.missionEntity == true
    )

    if ped ~= 0 then
        if options.freeze then FreezeEntityPosition(ped, true) end
        if options.invincible then SetEntityInvincible(ped, true) end
        if options.blockEvents then SetBlockingOfNonTemporaryEvents(ped, true) end
        if options.scenario then TaskStartScenarioInPlace(ped, options.scenario, 0, true) end
    end

    SetModelAsNoLongerNeeded(modelHash)
    return ped
end

-- LOCAL, published only as the `Round` export. A global named Round rebound the
-- ROUND native for every file in cis_libs.
local function round(num, numDecimalPlaces)
    return tonumber(string.format('%.' .. (numDecimalPlaces or 0) .. 'f', num))
end

-- The native's own contract, useZ included: `useZ == false` measures on the
-- ground plane. Omitted, it is 3D, which is what every existing caller got.
function CisGetDistanceBetweenCoords(x1, y1, z1, x2, y2, z2, useZ)
    local dx, dy = x1 - x2, y1 - y2
    if useZ == false then
        return math.sqrt(dx * dx + dy * dy)
    end
    local dz = z1 - z2
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

-- ADD_TEXT_COMPONENT_SUBSTRING_PLAYER_NAME holds 99 bytes. A longer string is
-- added in pieces, each ending on a UTF-8 character boundary: a cut through a
-- multi-byte character renders as garbage on both sides of the cut.
local COMPONENT_MAX = 99

local function addTextComponents(text)
    local n = #text
    if n == 0 then
        AddTextComponentSubstringPlayerName('')
        return
    end
    local i = 1
    while i <= n do
        local j = math.min(i + COMPONENT_MAX - 1, n)
        -- Step back while the next byte is a continuation byte (10xxxxxx).
        while j < n and j > i do
            local b = text:byte(j + 1)
            if b < 0x80 or b >= 0xC0 then break end
            j = j - 1
        end
        AddTextComponentSubstringPlayerName(text:sub(i, j))
        i = j + 1
    end
end

-- Screen-projected 3D text. Returns without drawing when the point is behind
-- the camera or clipped to it: the projection would otherwise produce a
-- degenerate scale and a rectangle in the wrong place, which reads as a broken
-- UI rather than as a missed frame.
function DrawText3D(x, y, z, text, settings)
    if type(settings) == 'table' and settings[1] then
        settings = { color = settings }
    end

    local onScreen, _x, _y = World3dToScreen2d(x, y, z)
    if not onScreen then
        return
    end
    -- `GetGameplayCamCoord`, SINGULAR, and it is the only such name in
    -- FiveM's native database. This used to be `GetGameplayCamCoords()`, which
    -- does not exist, so this function raised on its first call and nobody
    -- noticed because no test called it.
    local p = GetGameplayCamCoord()
    local distance = #(p - vector3(x, y, z))
    if distance <= 0.01 then
        return
    end
    local scale = (1 / distance) * 2 * (1 / GetGameplayCamFov()) * 100
    local textScale = settings and settings.scale or vec2(0.35 * scale, 0.35 * scale)
    local font = settings and settings.font or 4
    local color = settings and settings.color or { 255, 255, 255, 215 }
    local center = settings and settings.center or 1
    local alpha = color[4] or 215

    SetTextScale(textScale.x, textScale.y)
    SetTextFont(font)
    SetTextProportional(1)
    SetTextColour(color[1], color[2], color[3], alpha)
    SetTextCentre(center)
    -- BEGIN_TEXT_COMMAND_DISPLAY_TEXT TAKES A GXT LABEL, NOT THE TEXT. The label
    -- 'STRING' is the one that renders its substring components verbatim; handing
    -- the caller's text in as the label drew nothing (or a missing-label
    -- placeholder) for anything that was not, by luck, a real GXT key. The text
    -- itself goes in as ADD_TEXT_COMPONENT_SUBSTRING_PLAYER_NAME.
    --   HUD/BEGIN_TEXT_COMMAND_DISPLAY_TEXT  (char* text)  -- the label
    --   HUD/END_TEXT_COMMAND_DISPLAY_TEXT    (float x, float y)
    BeginTextCommandDisplayText('STRING')
    addTextComponents(tostring(text))
    EndTextCommandDisplayText(_x, _y)

    local factor = (string.len(tostring(text))) / 370
    DrawRect(_x, _y + 0.0125, 0.015 + factor, 0.03, 0, 0, 0, 100)
end

function RandomFloat(lower, greater)
    return lower + math.random() * (greater - lower)
end

function GetTableSize(t)
    local count = 0
    for _ in pairs(t) do
        count = count + 1
    end
    return count
end

exports('Round', round)
exports('GetDistanceBetweenCoords', CisGetDistanceBetweenCoords)
exports('DebugLog', DebugLog)
exports('DrawText3D', DrawText3D)
exports('CreatePed', CisCreatePed)
exports('RandomFloat', RandomFloat)
exports('GetTableSize', GetTableSize)
