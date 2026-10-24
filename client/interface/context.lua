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
-- `event` IS FIRED FROM CIS_LIBS' OWN VM, so every handler sees
-- GetInvokingResource() == 'cis_libs'. Handlers that trust that invoker (the
-- cache mirror, CisRealStop for a stop of cis_libs) would take an option firing
-- 'onResourceStop' with args 'cis_libs' as the library itself stopping. So an
-- option's local event must start with the registering resource's own
-- '<resource>:' prefix (the zone rule, client/core/zones.lua eventNameOk), and
-- a lifecycle, 'cis_libs:' or '__cfx_' name is refused for everyone. Any other
-- event is fired from onSelect, in the consumer's own VM. Checked when the menu
-- is registered, and again on the click.
--
-- AN ID BELONGS TO ITS REGISTRANT. Another resource registering the same id is
-- refused with the holder named (the D3 rule zones, targets and callbacks
-- follow), instead of silently taking the menu over. The holder's records are
-- released when it stops, so a held id always names a running resource.
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
local MAX_EVENT_NAME = 128
local LIB = GetCurrentResourceName() or 'cis_libs'

-- Names no context option may fire as a local event, whoever registered it.
local RESERVED_EVENTS = {
    onResourceStart = true, onResourceStop = true, onResourceStarting = true,
    onClientResourceStart = true, onClientResourceStop = true,
}
local RESERVED_PREFIXES = { LIB .. ':', 'cis_libs:', '__cfx_' }

-- nil when `name` may be fired as a local event for `owner`, else the reason.
local function localEventRefused(name, owner)
    if name == nil then
        return nil
    end
    if type(name) ~= 'string' or name == '' or #name > MAX_EVENT_NAME then
        return ('event must be a non-empty string of at most %d bytes'):format(MAX_EVENT_NAME)
    end
    if RESERVED_EVENTS[name] then
        return ('event %q is reserved'):format(name)
    end
    for i = 1, #RESERVED_PREFIXES do
        local prefix = RESERVED_PREFIXES[i]
        if name:sub(1, #prefix) == prefix then
            return ('event %q is reserved (%s*)'):format(name, prefix)
        end
    end
    if owner ~= LIB then
        local prefix = tostring(owner) .. ':'
        if name:sub(1, #prefix) ~= prefix then
            return ('event %q is fired from cis_libs, so it must start with %q; fire any other event from onSelect')
                :format(name, prefix)
        end
    end
    return nil
end

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

-- Raises when the page refuses the message (over the NUI cap), so both callers
-- run their cleanup: showContext releases focus, redraw closes the menu.
local function sendOpen(ctx, token)
    local sent, why = I.send('context:open', {
        token = token,
        id = ctx.id,
        title = ctx.title,
        canClose = ctx.canClose,
        hasBack = ctx.menu ~= nil and contexts[ctx.menu] ~= nil,
        options = view(ctx),
    })
    if sent == false and I.ready then
        error(why or 'the page refused the message', 0)
    end
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
    local session = { id = id, token = token, owner = ctx.owner }
    open = session
    local ok, err = pcall(function()
        I.focus.push('context', {
            owner = ctx.owner,
            onEscape = function()
                -- The session, not the token: a redraw rotates the token.
                local cur = contexts[id]
                if open == session and (not cur or cur.canClose) then
                    close(true)
                end
            end,
        })
        sendOpen(ctx, token)
    end)
    if not ok then
        -- Never leave the cursor up for a menu that was not drawn.
        I.log('error', ('context menu %s failed to open: %s'):format(id, tostring(err)))
        close(false)
        return false, 'context menu failed to open'
    end
    return true
end

-- The open menu, drawn again from its registered options under a fresh token,
-- so a click the page sends for the old list is stale. Focus is not touched.
local function redraw()
    local o = open
    local ctx = o and contexts[o.id]
    if not ctx then
        return
    end
    local token = I.nextId()
    o.token = token
    local ok, err = pcall(sendOpen, ctx, token)
    if not ok then
        I.log('error', ('context menu %s failed to redraw: %s'):format(o.id, tostring(err)))
        close(false)
    end
end

-- The menu as it will be stored, or false and why. Changes nothing, so a list
-- is checked whole before any of it is stored.
local function prepare(ctx, owner)
    if type(ctx) ~= 'table' then
        return false, ('a context menu must be a table, got %s'):format(type(ctx))
    end
    local id = ctx.id
    if type(id) ~= 'string' or id == '' or #id > 128 then
        return false, 'a context menu needs a string id'
    end
    local holder = CisOwned.ownerOf(owned, 'context', id)
    if holder and holder ~= owner then
        return false, ('context %q is registered by %s; pick a different id'):format(id, tostring(holder))
    end
    local options = optionList(ctx.options)
    if #options > MAX_OPTIONS then
        return false, ('a context menu holds at most %d options'):format(MAX_OPTIONS)
    end
    for i, o in ipairs(options) do
        if type(o) ~= 'table' then
            return false, ('option %d of %s is not a table'):format(i, id)
        end
        local refused = localEventRefused(o.event, owner)
        if refused then
            return false, ('option %d of %s: %s'):format(i, id, refused)
        end
        if o.serverEvent ~= nil and type(o.serverEvent) ~= 'string' then
            return false, ('option %d of %s: serverEvent must be a string'):format(i, id)
        end
        if o.onSelect ~= nil and not CisCallable(o.onSelect) then
            return false, ('option %d of %s: onSelect must be a function'):format(i, id)
        end
    end
    return {
        id = id,
        title = I.str(ctx.title, 256) or '',
        menu = type(ctx.menu) == 'string' and ctx.menu or nil,
        canClose = ctx.canClose ~= false,
        onExit = CisCallable(ctx.onExit) and ctx.onExit or nil,
        onBack = CisCallable(ctx.onBack) and ctx.onBack or nil,
        options = options,
        owner = owner,
    }
end

local function commit(entry)
    contexts[entry.id] = entry
    CisOwned.track(owned, entry.owner, 'context', entry.id)
    -- THE MENU ON SCREEN IS DRAWN AGAIN, UNDER A NEW TOKEN. The page still showed
    -- the old options, and a click on index n would have run the NEW list's
    -- option n -- a different serverEvent than the one the player saw.
    if open and open.id == entry.id then
        redraw()
    end
end

--- @param context table  one context, or a list of them
local function registerContext(context)
    local owner = I.caller()
    if type(context) == 'table' and context.id == nil and #context > 0 then
        -- ALL OR NOTHING: every context is checked before any is stored.
        local ready = {}
        for i, ctx in ipairs(context) do
            local entry, err = prepare(ctx, owner)
            if not entry then
                return false, ('context %d: %s'):format(i, err)
            end
            ready[i] = entry
        end
        for i = 1, #ready do
            commit(ready[i])
        end
        return true
    end
    local entry, err = prepare(context, owner)
    if not entry then
        return false, err
    end
    commit(entry)
    return true
end

--- @param onExit boolean|nil  true runs the menu's onExit
local function hideContext(onExit)
    return close(onExit == true)
end

local function getOpenContextMenu()
    return open and open.id or nil
end

local function choose(option, owner)
    if type(option.menu) == 'string' and contexts[option.menu] then
        showContext(option.menu)
        return
    end
    close(false)
    if option.onSelect then
        I.invoke(option.onSelect, option.args)
    end
    if type(option.event) == 'string' and option.event ~= '' then
        -- Checked again here: an in-VM caller's option table is held by reference.
        local refused = localEventRefused(option.event, owner)
        if refused then
            I.log('error', ('context option refused: %s'):format(refused))
        else
            TriggerEvent(option.event, option.args)
        end
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
        choose(option, ctx.owner)
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
