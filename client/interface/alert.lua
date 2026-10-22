-- Alert dialog. Blocking: 'confirm' or 'cancel'.
--
-- Focus is pushed when it opens and popped in `settle`, the single exit
-- (button, Escape, CloseAlertDialog, the caller stopping, cis_libs stopping,
-- the page reloading, an error while opening). Only one alert at a time: a
-- second call while one is open returns nil and a reason rather than
-- cancelling somebody else's question.

local I = CisInterface

local SIZES = { xs = true, sm = true, md = true, lg = true, xl = true }
local current = nil -- { id, owner, p }

local function settle(s, result)
    if current ~= s then
        return false
    end
    current = nil
    I.focus.pop('alert')
    I.send('alert:close', { id = s.id })
    s.p:resolve(result)
    return true
end

local function labels(t)
    if type(t) ~= 'table' then
        return nil
    end
    return { confirm = I.str(t.confirm, 64), cancel = I.str(t.cancel, 64) }
end

--- @param data table  { header, content, centered, cancel, size, labels }
local function alertDialog(data)
    if type(data) ~= 'table' then
        return nil, ('alert dialog needs a table, got %s'):format(type(data))
    end
    local header = I.str(data.header, 256)
    local content = I.str(data.content, 8000)
    if not header and not content then
        return nil, 'alert dialog needs a header or content'
    end
    local owner = I.caller()
    if current then
        return nil, 'an alert dialog is already open'
    end
    if not I.waitReady() then
        return nil, 'ui not ready'
    end
    if current then
        return nil, 'an alert dialog is already open'
    end
    local s = { id = I.nextId(), owner = owner, p = promise.new() }
    current = s
    local ok, err = pcall(function()
        I.focus.push('alert', {
            owner = owner,
            onEscape = function() settle(s, 'cancel') end,
        })
        I.send('alert:open', {
            id = s.id,
            header = header,
            content = content,
            centered = data.centered == true,
            cancel = data.cancel == true,
            size = SIZES[data.size] and data.size or nil,
            labels = labels(data.labels),
        })
    end)
    if not ok then
        I.log('error', ('alert dialog failed to open: %s'):format(tostring(err)))
        settle(s, 'cancel')
        return nil, 'alert dialog failed to open'
    end
    return Citizen.Await(s.p)
end

local function closeAlertDialog()
    if not current then
        return false
    end
    return settle(current, 'cancel')
end

I.on('alert', { id = 'string', result = 'string' }, function(data)
    if current and current.id == data.id then
        settle(current, data.result == 'confirm' and 'confirm' or 'cancel')
    end
end)

I.onStop(function(resource, all)
    if current and (all or current.owner == resource) then
        settle(current, 'cancel')
    end
end)

I.onReset(function()
    if current then
        settle(current, 'cancel')
    end
end)

exports('AlertDialog', alertDialog)
exports('CloseAlertDialog', closeAlertDialog)

I.alert = { open = alertDialog, close = closeAlertDialog }
