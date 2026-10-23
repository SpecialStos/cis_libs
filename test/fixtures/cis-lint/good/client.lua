-- Correct NUI handlers in the shapes the checker must follow, not flag.
local note = [[ an end, a return and a cb( inside a long string ]]
--[==[ a block comment with end and return inside ]==]

RegisterNUICallback('both', function(data, cb)
    if data.ok then
        cb({ ok = true })
    else
        cb({ ok = false })
    end
end)

RegisterNUICallback('guard', function(data, cb)
    if type(data.item) ~= 'string' then
        return cb({ ok = false, reason = 'bad item' })
    end
    if data.item == '' then
        cb({ ok = false })
        return
    end
    cb({ ok = true, note = note })
end)

RegisterNUICallback('answerFirst', function(data, cb)
    cb({ ok = true })
    for _, v in ipairs(data.list or {}) do
        print(v)
    end
end)

RegisterNUICallback('async', function(data, cb)
    CreateThread(function()
        cb({ ok = data.ok == true })
    end)
end)

local function reply(cb, ok)
    cb({ ok = ok })
end

RegisterNUICallback('delegated', function(data, cb)
    reply(cb, data.ok == true)
end)

local function onClose(_, cb)
    do
        cb({ ok = true })
    end
end
RegisterNUICallback('close', onClose)

RegisterNUICallback('elseif', function(data, cb)
    if data.a then
        return cb(1)
    elseif data.b then
        return cb(2)
    else
        return cb(3)
    end
end)

LocalPlayer.state:set('cisLintFixture', true, false)

UI = {}
function UI.onBuy(data, cb)
    cb({ ok = data.item ~= nil })
end
RegisterNUICallback('buy', UI.onBuy)

RegisterNuiCallbackType('raw')
AddEventHandler('__cfx_nui:raw', function(data, cb)
    cb({ ok = data ~= nil })
end)
