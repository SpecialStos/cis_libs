-- Server side of the interface layer: NotifyPlayer, a toast on one player's
-- screen (or every player's, with -1).
--
-- The payload is rebuilt here from the known fields only, bounded, before it
-- is sent: a caller cannot push an arbitrary table across the network through
-- this export. The client accepts the event only when it really came from the
-- server (see client/interface/notify.lua).

local TYPES = { inform = true, info = true, success = true, warning = true, error = true }

local function bounded(v, max)
    if type(v) == 'number' then v = tostring(v) end
    if type(v) ~= 'string' or v == '' then return nil end
    -- Cleaned and cut on a character, not a byte: a cut through a character
    -- was invalid UTF-8 on arrival, and the client then turned every
    -- non-ASCII character in the string into '?'.
    return CisUtf8.clip(CisUtf8.clean(v), max)
end

--- @param src integer  a player server id, or -1 for everyone
--- @param data table|string  { id, title, description, type, icon, iconColor, duration, position, showDuration }
local function notifyPlayer(src, data)
    src = tonumber(src)
    if not src or src ~= math.floor(src) or (src < 1 and src ~= -1) then
        return false, ('NotifyPlayer needs a player id or -1, got %s'):format(tostring(src))
    end
    if src ~= -1 and not GetPlayerName(src) then
        return false, ('no player %d'):format(src)
    end
    if type(data) == 'string' then
        data = { description = data }
    end
    if type(data) ~= 'table' then
        return false, ('NotifyPlayer needs a table or a string, got %s'):format(type(data))
    end
    local payload = {
        id = bounded(data.id, 64),
        title = bounded(data.title, 256),
        description = bounded(data.description, 2048),
        type = TYPES[data.type] and data.type or nil,
        icon = bounded(data.icon, 256),
        iconColor = bounded(data.iconColor, 64),
        duration = tonumber(data.duration),
        position = bounded(data.position, 16),
        showDuration = data.showDuration ~= false,
    }
    if not payload.title and not payload.description then
        return false, 'NotifyPlayer needs a title or a description'
    end
    TriggerClientEvent('cis_libs:client:uiNotify', src, payload)
    return true
end

exports('NotifyPlayer', notifyPlayer)
