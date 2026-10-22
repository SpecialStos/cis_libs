-- The NUI bridge: the one place Lua talks to web/ and the one place web/
-- talks back.
--
-- EVERY CALLBACK IS VALIDATED HERE, BEFORE ANY COMPONENT SEES IT. The page is
-- a browser: anything in it (a devtools console, a compromised image URL
-- someone put in a menu) can POST any JSON to any callback name. So a callback
-- declares the exact shape it accepts, a payload that does not match is
-- dropped and counted, and a component only ever gets typed fields. Ids are
-- matched against the component's own open state, so an unknown or stale id
-- is a no-op. Nothing the page sends can name an event: a selection is an
-- index, and what that index does is looked up in Lua.
--
-- IDLE COST IS ZERO. Nothing here runs per frame. Components that need a
-- per-frame thread (progress, list menu, radial, skill check) start one when
-- they open and let it end when they close.

CisInterface = CisInterface or {}
local I = CisInterface

I.ready = false
I.stats = { sent = 0, received = 0, rejected = 0, errors = 0 }
local stopHandlers = {}
local resetHandlers = {}
local readyHandlers = {}
local buffered = {}
local nextId = 0
local MAX_STRING = 4096
local MAX_BUFFER = 32

function I.log(level, message)
    if CisLog then
        CisLog(level, 'cis_libs ui: ' .. tostring(message))
    end
end

-- The resource on whose behalf a call is being made. Captured at the top of
-- each export, before any Wait: a blocking call outlives the stack it came in on.
function I.caller()
    return GetInvokingResource() or GetCurrentResourceName() or 'cis_libs'
end

function I.nextId()
    nextId = nextId + 1
    return nextId
end

-- A UTF-8 safe, bounded copy of a string, or nil. json.encode raises on an
-- invalid byte sequence, and one bad string would drop the whole message.
function I.str(value, max)
    if type(value) == 'number' then
        value = tostring(value)
    end
    if type(value) ~= 'string' or value == '' then
        return nil
    end
    max = max or MAX_STRING
    if utf8.len(value) == nil then
        value = value:gsub('[\128-\255]', '?')
    end
    if #value > max then
        local cut = utf8.offset(value, max + 1)
        if cut then
            value = value:sub(1, cut - 1)
        end
    end
    return value
end

function I.num(value, lo, hi, default)
    value = tonumber(value)
    if value == nil or value ~= value then
        return default
    end
    if lo and value < lo then value = lo end
    if hi and value > hi then value = hi end
    return value
end

-- A CSS colour the page can hand to style.color unexamined.
function I.color(value)
    if type(value) ~= 'string' or #value > 64 then
        return nil
    end
    if value:match('^#%x%x%x%x?%x?%x?%x?%x?$')
        or value:match('^rgba?%([%d%s%.,%%/]+%)$')
        or value:match('^hsla?%([%d%s%.,%%/deg]+%)$')
        or value:match('^%a+$') then
        return value
    end
    return nil
end

function I.send(action, data, buffer)
    if not I.ready then
        if buffer and #buffered < MAX_BUFFER then
            buffered[#buffered + 1] = { action = action, data = data }
        end
        return false
    end
    I.stats.sent = I.stats.sent + 1
    SendNuiMessage(json.encode({ action = action, data = data or {} }))
    return true
end

-- Shape check. spec: { field = 'string' | 'integer' | 'number' | 'boolean' |
-- 'table', ... }, a leading '?' marks the field optional. Extra fields are
-- ignored; a missing or mistyped required one rejects the whole payload.
local function fieldOk(value, kind)
    if kind == 'string' then
        return type(value) == 'string' and #value <= MAX_STRING
    elseif kind == 'integer' then
        return type(value) == 'number' and value == math.floor(value)
            and value >= -2147483648 and value <= 2147483647
    elseif kind == 'number' then
        return type(value) == 'number' and value == value
    elseif kind == 'boolean' then
        return type(value) == 'boolean'
    elseif kind == 'table' then
        return type(value) == 'table'
    end
    return false
end

function I.validate(data, spec)
    if type(data) ~= 'table' then
        return false
    end
    for field, kind in pairs(spec) do
        local optional = kind:sub(1, 1) == '?'
        if optional then
            kind = kind:sub(2)
        end
        local value = data[field]
        if value == nil then
            if not optional then
                return false
            end
        elseif not fieldOk(value, kind) then
            return false
        end
    end
    return true
end

function I.on(name, spec, handler)
    RegisterNUICallback(name, function(data, cb)
        I.stats.received = I.stats.received + 1
        local ok = I.validate(data, spec)
        -- Answered first: a handler may yield (an onSelect that opens a
        -- dialog), and the page's fetch should not hang on it.
        cb({ ok = ok })
        if not ok then
            I.stats.rejected = I.stats.rejected + 1
            return
        end
        local okCall, err = pcall(handler, data)
        if not okCall then
            I.stats.errors = I.stats.errors + 1
            I.log('error', ('callback %s raised: %s'):format(name, tostring(err)))
        end
    end)
end

-- Call a consumer's function (a local function, or a funcref from another
-- resource) without letting it break the caller.
function I.invoke(fn, ...)
    if not CisCallable(fn) then
        return false
    end
    local ok, err = pcall(fn, ...)
    if not ok then
        I.stats.errors = I.stats.errors + 1
        I.log('error', ('a ui callback raised: %s'):format(tostring(err)))
    end
    return ok
end

-- Wait (at most `ms`) for the page to report ready. A blocking component that
-- opened on a page that never loaded would hold NUI focus with nothing drawn.
function I.waitReady(ms)
    if I.ready then
        return true
    end
    local deadline = GetGameTimer() + (ms or 3000)
    while not I.ready and GetGameTimer() < deadline do
        Wait(50)
    end
    return I.ready
end

-- fn(resource) runs when any resource stops; components close what that
-- resource owns. When cis_libs itself stops, `all` is true.
function I.onStop(fn)
    stopHandlers[#stopHandlers + 1] = fn
end

-- fn() runs when the page reloads: whatever was open there is gone.
function I.onReset(fn)
    resetHandlers[#resetHandlers + 1] = fn
end

-- fn() runs every time the page reports ready, after `init`: a component
-- whose state outlives the page (the text UI) re-sends it.
function I.onReady(fn)
    readyHandlers[#readyHandlers + 1] = fn
end

local function runAll(list, ...)
    for i = 1, #list do
        local ok, err = pcall(list[i], ...)
        if not ok then
            I.log('error', ('cleanup raised: %s'):format(tostring(err)))
        end
    end
end

function I.markReady(initial)
    local wasReady = I.ready
    I.ready = true
    if wasReady then
        runAll(resetHandlers)
    end
    I.send('init', initial)
    local pending = buffered
    buffered = {}
    for i = 1, #pending do
        I.send(pending[i].action, pending[i].data)
    end
    runAll(readyHandlers)
end

-- The page reports its own uncaught errors here, so a broken component is a
-- line in the client log rather than a silent blank.
I.on('error', { message = 'string' }, function(data)
    I.stats.errors = I.stats.errors + 1
    I.log('error', 'page: ' .. data.message)
end)

AddEventHandler('onResourceStop', function(resource)
    -- A forged stop from another client script is ignored (shared/owned.lua).
    if not CisRealStop(resource) then
        return
    end
    local all = resource == GetCurrentResourceName()
    runAll(stopHandlers, resource, all)
end)

CisDiagnostics.Register('client', 'interface', function()
    local out = {
        ready = I.ready,
        sent = I.stats.sent,
        received = I.stats.received,
        rejected = I.stats.rejected,
        errors = I.stats.errors,
    }
    if I.focus then
        out.focusDepth = #I.focus.stack()
    end
    return out
end)
