-- Context menus: registerContext / showContext / hideContext.
--
-- OWNERSHIP. Every registered menu records the resource that registered it
-- (CisOwned), and that resource stopping unregisters all of them and closes
-- the one on screen if it was theirs -- without calling its onExit, which
-- would be a call into a resource that no longer exists.
--
-- WHAT THE PAGE CAN DO. It reports an index. The option at that index is
-- looked up in the registered menu, and only then are its onSelect, event and
-- serverEvent used. A disabled or read-only option is refused here as well as
-- in the page.
--
-- serverEvent IS FIRED BY THIS CLIENT, with TriggerServerEvent(name, args),
-- exactly as ox_lib does. The server handler receives it like any other
-- client event, so it MUST validate `source` and `args` itself: a cheater can
-- send that event without ever opening the menu.

local I = CisInterface

local contexts = {}
local owned = CisOwned.new()
local open = nil -- { id, token, owner }
local MAX_OPTIONS = 128

local function readMetadata(meta)
    if type(meta) ~= 'table' then
        return nil
    end
    local out = {}
    if #meta > 0 then
        for _, m in ipairs(meta) do
            if #out >= 32 then break end
            if type(m) == 'table' then
                out[#out + 1] = {
                    label = I.str(m.label, 128) or '',
                    value = I.str(m.value, 512),
                    progress = I.num(m.progress, 0, 100),
                }
            elseif type(m) == 'string' or type(m) == 'number' then
                out[#out + 1] = { label = I.str(m, 512) or '' }
            end
        end
    else
        local keys = {}
        for k in pairs(meta) do
            if type(k) == 'string' then keys[#keys + 1] = k end
        end
        table.sort(keys)
        for i = 1, math.min(#keys, 32) do
            out[#out + 1] = { label = I.str(keys[i], 128), value = I.str(meta[keys[i]], 512) }
        end
    end
    return out
end

-- ox_lib accepts options as a list or as a map keyed by title.
local function optionList(options)
    if type(options) ~= 'table' then
        return {}
    end
    if #options > 0 or next(options) == nil then
        return options
    end
    local keys = {}
    for k, v in pairs(options) do
        if type(k) == 'string' and type(v) == 'table' then keys[#keys + 1] = k end
    end
    table.sort(keys)
    local out = {}
    for i, k in ipairs(keys) do
        local o = {}
        for kk, vv in pairs(options[k]) do o[kk] = vv end
        o.title = o.title or k
        out[i] = o
    end
    return out
end

local function view(ctx)
    local out = {}
    for i, o in ipairs(ctx.options) do
        out[i] = {
            title = I.str(o.title, 256) or '',
            description = I.str(o.description, 1024),
            icon = I.icon(o.icon),
            iconColor = I.color(o.iconColor),
            arrow = o.arrow == true,
            hasMenu = type(o.menu) == 'string',
            disabled = o.disabled == true,
            readOnly = o.readOnly == true,
            progress = I.num(o.progress, 0, 100),
            colorScheme = I.str(o.colorScheme, 32),
            metadata = readMetadata(o.metadata),
            image = I.str(o.image, 1024),
        }
    end
    return out
end

local function register(ctx, owner)
    if type(ctx) ~= 'table' then
        return false, ('a context menu must be a table, got %s'):format(type(ctx))
    end
    local id = ctx.id
    if type(id) ~= 'string' or id == '' or #id > 128 then
        return false, 'a context menu needs a string id'
    end
    local options = optionList(ctx.options)
    if #options > MAX_OPTIONS then
        return false, ('a context menu holds at most %d options'):format(MAX_OPTIONS)
    end
    for i, o in ipairs(options) do
        if type(o) ~= 'table' then
            return false, ('option %d of %s is not a table'):format(i, id)
        end
        if o.event ~= nil and type(o.event) ~= 'string' then
            return false, ('option %d of %s: event must be a string'):format(i, id)
        end
        if o.serverEvent ~= nil and type(o.serverEvent) ~= 'string' then
            return false, ('option %d of %s: serverEvent must be a string'):format(i, id)
        end
        if o.onSelect ~= nil and not CisCallable(o.onSelect) then
            return false, ('option %d of %s: onSelect must be a function'):format(i, id)
        end
    end
    contexts[id] = {
        id = id,
        title = I.str(ctx.title, 256) or '',
        menu = type(ctx.menu) == 'string' and ctx.menu or nil,
        canClose = ctx.canClose ~= false,
        onExit = CisCallable(ctx.onExit) and ctx.onExit or nil,
        onBack = CisCallable(ctx.onBack) and ctx.onBack or nil,
        options = options,
        owner = owner,
    }
    CisOwned.track(owned, owner, 'context', id)
    return true
end

--- @param context table  one context, or a list of them
local function registerContext(context)
    local owner = I.caller()
    if type(context) == 'table' and context.id == nil and #context > 0 then
        for i, ctx in ipairs(context) do
            local ok, err = register(ctx, owner)
            if not ok then
                return false, ('context %d: %s'):format(i, err)
            end
        end
        return true
    end
    return register(context, owner)
end

local function close(callExit)
    local o = open
    if not o then
        return false
    end
    open = nil
    I.focus.pop('context')
    I.send('context:close', {})
    local ctx = contexts[o.id]
    if callExit and ctx and ctx.onExit then
        I.invoke(ctx.onExit)
    end
    return true
end

local function showContext(id)
    local ctx = type(id) == 'string' and contexts[id] or nil
    if not ctx then
        return false, ('no context menu named %s'):format(tostring(id))
    end
    if not I.ready then
        return false, 'ui not ready'
    end
    local token = I.nextId()
    open = { id = id, token = token, owner = ctx.owner }
    local ok, err = pcall(function()
        I.focus.push('context', {
            owner = ctx.owner,
            onEscape = function()
                local cur = contexts[id]
                if open and open.token == token and (not cur or cur.canClose) then
                    close(true)
                end
            end,
        })
        I.send('context:open', {
            token = token,
            id = id,
            title = ctx.title,
            canClose = ctx.canClose,
            hasBack = ctx.menu ~= nil and contexts[ctx.menu] ~= nil,
            options = view(ctx),
        })
    end)
    if not ok then
        -- Never leave the cursor up for a menu that was not drawn.
        I.log('error', ('context menu %s failed to open: %s'):format(id, tostring(err)))
        close(false)
        return false, 'context menu failed to open'
    end
    return true
end

--- @param onExit boolean|nil  true runs the menu's onExit
local function hideContext(onExit)
    return close(onExit == true)
end

local function getOpenContextMenu()
    return open and open.id or nil
end

local function choose(option)
    if type(option.menu) == 'string' and contexts[option.menu] then
        showContext(option.menu)
        return
    end
    close(false)
    if option.onSelect then
        I.invoke(option.onSelect, option.args)
    end
    if type(option.event) == 'string' and option.event ~= '' then
        TriggerEvent(option.event, option.args)
    end
    if type(option.serverEvent) == 'string' and option.serverEvent ~= '' then
        TriggerServerEvent(option.serverEvent, option.args)
    end
end

I.on('context', { token = 'string', action = 'string', index = '?integer' }, function(data)
    if not open or open.token ~= data.token then
        return
    end
    local ctx = contexts[open.id]
    if not ctx then
        close(false)
        return
    end
    if data.action == 'close' then
        if ctx.canClose then close(true) end
    elseif data.action == 'back' then
        if ctx.onBack then I.invoke(ctx.onBack) end
        if ctx.menu and contexts[ctx.menu] then
            showContext(ctx.menu)
        else
            close(false)
        end
    elseif data.action == 'select' then
        local option = data.index and ctx.options[data.index]
        if type(option) ~= 'table' or option.disabled or option.readOnly then
            return
        end
        choose(option)
    end
end)

I.onStop(function(resource, all)
    if all then
        contexts = {}
        CisOwned.clear(owned)
        if open then close(false) end
        return
    end
    for _, rec in ipairs(CisOwned.release(owned, resource)) do
        CisOwned.forget(owned, rec.kind, rec.id)
        if open and open.id == rec.id then
            close(false)
        end
        contexts[rec.id] = nil
    end
end)

I.onReset(function()
    if open then close(false) end
end)

exports('RegisterContext', registerContext)
exports('ShowContext', showContext)
exports('HideContext', hideContext)
exports('GetOpenContextMenu', getOpenContextMenu)

I.context = { register = registerContext, show = showContext, hide = hideContext, getOpen = getOpenContextMenu }
