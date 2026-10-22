-- Notifications. Fire and forget: no focus, no thread, no state in Lua. The
-- queue (max visible per position, waiting list, dedupe by id) lives in the
-- page, in web/js/queue.js.
--
-- A notification sent before the page has loaded is buffered (bounded) and
-- delivered on `ready`, so a resource that notifies from its first frame is
-- not silently dropped.
--
-- The server reaches this through NotifyPlayer (server/interface.lua) and the
-- `cis_libs:client:uiNotify` net event. The handler accepts it ONLY from the
-- network: on a client, an event from the server carries a numeric `source`,
-- and the same event raised locally with TriggerEvent by another client
-- resource carries an empty string. So no client script can spoof a
-- "server" notification through this path.

local I = CisInterface

local TYPES = { inform = 'inform', info = 'inform', success = 'success', warning = 'warning', error = 'error' }
local POSITIONS = {
    top = true, ['top-right'] = true, ['top-left'] = true, bottom = true,
    ['bottom-right'] = true, ['bottom-left'] = true, ['center-right'] = true, ['center-left'] = true,
}

local function build(data)
    if type(data) == 'string' then
        data = { description = data }
    end
    if type(data) ~= 'table' then
        return nil, ('notify needs a table or a string, got %s'):format(type(data))
    end
    local title = I.str(data.title, 256)
    local description = I.str(data.description, 2048)
    if not title and not description then
        return nil, 'notify needs a title or a description'
    end
    return {
        id = I.str(data.id, 64),
        title = title,
        description = description,
        type = TYPES[data.type] or 'inform',
        icon = I.icon(data.icon),
        iconColor = I.color(data.iconColor),
        duration = math.floor(I.num(data.duration, 500, 60000, 3000)),
        position = POSITIONS[data.position] and data.position or nil,
        showDuration = data.showDuration ~= false,
    }, data
end

--- @param data table|string  { id, title, description, type, icon, iconColor, duration, position, showDuration, sound }
local function notify(data)
    local payload, source_ = build(data)
    if not payload then
        return false, source_
    end
    local sound = type(source_) == 'table' and source_.sound or nil
    if type(sound) == 'table' and type(sound.name) == 'string' and type(sound.set) == 'string' then
        PlaySoundFrontend(-1, sound.name, sound.set, true)
    end
    I.send('notify', payload, true)
    return true
end

RegisterNetEvent('cis_libs:client:uiNotify', function(data)
    if type(source) ~= 'number' then
        return
    end
    notify(data)
end)

-- Not 'Notify': that name is the framework notify (client/proxy.lua), a
-- different signature, and a second registration would silently replace it.
exports('Toast', notify)

I.notify = notify
