-- Each handler misses cb on one path. Line numbers are pinned in expect.json.
RegisterNUICallback('noCb', function(data, cb)
    print(data.item, cb ~= nil and 'a test of cb, not a call: answers nothing')
end)

RegisterNUICallback('fallsOffEnd', function(data, _)
    print(data.item)
end)

RegisterNUICallback('earlyReturn', function(data, cb)
    if not data.item then
        return
    end
    cb({ ok = true })
end)

RegisterNUICallback('ifWithoutElse', function(data, cb)
    if data.ok then
        cb({ ok = true })
    end
end)

RegisterNUICallback('loopOnly', function(data, cb)
    for _, v in ipairs(data.list) do
        cb(v)
    end
end)

local function onBuy(data)
    print(data.item)
end
RegisterNUICallback('noCbParam', onBuy)

RegisterNUICallback('external', SomeModule.handler)

RegisterNUICallback('returnInLoop', function(data, cb)
    while data.wait do
        if data.abort then
            return
        end
        Wait(0)
    end
    cb(true)
end)
