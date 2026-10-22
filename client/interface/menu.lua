-- List menu: keyboard-driven, no NUI focus (the player keeps moving unless
-- disableInput is set). The arrow keys, Enter and Backspace/Escape are read by
-- a thread that exists only while a menu is open; the page only draws the
-- state it is sent.
--
-- Callbacks (the registerMenu cb, onSelected, onSideScroll, onCheck, onClose)
-- may be local functions or funcrefs from another resource; each is called
-- through I.invoke, so one that raises does not break the menu. Menus are
-- owner-tracked like context menus.

local I = CisInterface

local KEY = { up = 172, down = 173, left = 174, right = 175, enter = 191 }
-- Not 177: it is also the RIGHT MOUSE BUTTON, so aiming closed the menu.
local BACK = { [194] = 'Backspace', [200] = 'Escape', [202] = 'Escape' }
-- Navigation, pause, phone, weapon wheel scroll: ours while a menu is open.
local ALWAYS_DISABLED = { 14, 15, 16, 17, 27, 172, 173, 174, 175, 176, 177, 191, 194, 199, 200, 201, 202 }
local INPUT_DISABLED = { 1, 2, 21, 22, 24, 25, 30, 31, 36, 37, 44 }
local POSITIONS = { ['top-left'] = true, ['top-right'] = true, ['bottom-left'] = true, ['bottom-right'] = true }
local REPEAT_DELAY, REPEAT_RATE = 350, 90
local MAX_OPTIONS = 256

local menus = {}
local owned = CisOwned.new()
local open = nil -- { id, menu, selected, scroll = {}, checked = {}, held = {} }

local function readValues(values)
    if type(values) ~= 'table' or #values == 0 then
        return nil
    end
    local out = {}
    for i = 1, math.min(#values, 128) do
        local v = values[i]
        if type(v) == 'table' then
            out[i] = { label = I.str(v.label, 128) or '', description = I.str(v.description, 512) }
        else
            out[i] = { label = I.str(v, 128) or '' }
        end
    end
    return out
end

local function readOption(o)
    if type(o) ~= 'table' then
        return nil
    end
    -- Not `type(...) == 'boolean' and o.checked or nil`: that turns false into nil.
    local checked = nil
    if type(o.checked) == 'boolean' then
        checked = o.checked
    end
    return {
        label = I.str(o.label, 256) or '',
        description = I.str(o.description, 1024),
        icon = I.icon(o.icon),
        iconColor = I.color(o.iconColor),
        values = readValues(o.values),
        defaultIndex = math.floor(I.num(o.defaultIndex, 1, 128, 1)),
        checked = checked,
        progress = I.num(o.progress, 0, 100),
        colorScheme = I.str(o.colorScheme, 32),
        args = o.args,
        close = o.close ~= false,
    }
end

local function readOptions(list)
    local out = {}
    if type(list) ~= 'table' then
        return out
    end
    for i = 1, math.min(#list, MAX_OPTIONS) do
        local o = readOption(list[i])
        if o then out[#out + 1] = o end
    end
    return out
end

local function view(s)
    local out = {}
    for i, o in ipairs(s.menu.options) do
        out[i] = {
            label = o.label, description = o.description, icon = o.icon, iconColor = o.iconColor,
            values = o.values, progress = o.progress, colorScheme = o.colorScheme,
            checked = s.checked[i], scrollIndex = o.values and s.scroll[i] or nil,
        }
    end
    return out
end

--- @param data table  { id, title, position, options, onSelected, onSideScroll, onCheck, onClose, disableInput, canClose }
--- @param cb function|nil  called (selected, scrollIndex, args) when an option is confirmed
local function registerMenu(data, cb)
    if type(data) ~= 'table' then
        return false, ('a menu must be a table, got %s'):format(type(data))
    end
    if type(data.id) ~= 'string' or data.id == '' or #data.id > 128 then
        return false, 'a menu needs a string id'
    end
    if cb ~= nil and not CisCallable(cb) then
        return false, 'the menu callback must be a function'
    end
    local owner = I.caller()
    local fn = function(v) return CisCallable(v) and v or nil end
    menus[data.id] = {
        id = data.id,
        title = I.str(data.title, 256) or '',
        position = POSITIONS[data.position] and data.position or nil,
        options = readOptions(data.options),
        onSelected = fn(data.onSelected),
        onSideScroll = fn(data.onSideScroll),
        onCheck = fn(data.onCheck),
        onClose = fn(data.onClose),
        disableInput = data.disableInput == true,
        canClose = data.canClose ~= false,
        cb = cb,
        owner = owner,
    }
    CisOwned.track(owned, owner, 'menu', data.id)
    return true
end

local function close(s, keyPressed, callClose)
    if open ~= s then
        return false
    end
    open = nil
    I.send('menu:close', {})
    if callClose and s.menu.onClose then
        I.invoke(s.menu.onClose, keyPressed)
    end
    return true
end

local function pressed(s, control, now)
    if IsDisabledControlJustPressed(0, control) then
        s.held[control] = now + REPEAT_DELAY
        return true
    end
    local at = s.held[control]
    if at then
        if not IsDisabledControlPressed(0, control) then
            s.held[control] = nil
        elseif now >= at then
            s.held[control] = now + REPEAT_RATE
            return true
        end
    end
    return false
end

local function state(s, index)
    I.send('menu:state', {
        selected = s.selected,
        index = index,
        scrollIndex = index and s.scroll[index] or nil,
        checked = index and s.checked[index],
    })
end

local function frame(s)
    local menu = s.menu
    for i = 1, #ALWAYS_DISABLED do
        DisableControlAction(0, ALWAYS_DISABLED[i], true)
    end
    if menu.disableInput then
        for i = 1, #INPUT_DISABLED do
            DisableControlAction(0, INPUT_DISABLED[i], true)
        end
    end
    local count = #menu.options
    local now = GetGameTimer()
    local dir = count > 0 and (pressed(s, KEY.up, now) and -1 or pressed(s, KEY.down, now) and 1) or nil
    if dir then
        s.selected = (s.selected - 1 + dir) % count + 1
        state(s)
        local o = menu.options[s.selected]
        I.invoke(menu.onSelected, s.selected, s.scroll[s.selected], o.args, s.checked[s.selected])
        return
    end
    local o = menu.options[s.selected]
    local side = o and o.values and (pressed(s, KEY.left, now) and -1 or pressed(s, KEY.right, now) and 1) or nil
    if side then
        local n = #o.values
        s.scroll[s.selected] = (s.scroll[s.selected] - 1 + side) % n + 1
        state(s, s.selected)
        I.invoke(menu.onSideScroll, s.selected, s.scroll[s.selected], o.args)
        return
    end
    if o and IsDisabledControlJustPressed(0, KEY.enter) then
        if s.checked[s.selected] ~= nil then
            s.checked[s.selected] = not s.checked[s.selected]
            state(s, s.selected)
            I.invoke(menu.onCheck, s.selected, s.checked[s.selected], o.args)
            return
        end
        local selected, scroll = s.selected, s.scroll[s.selected]
        if o.close then
            close(s, nil, false)
        end
        I.invoke(menu.cb, selected, scroll, o.args)
        return
    end
    for control, name in pairs(BACK) do
        if IsDisabledControlJustPressed(0, control) then
            if menu.canClose then
                close(s, name, true)
            end
            return
        end
    end
end

--- @param id string
--- @param startIndex integer|nil
local function showMenu(id, startIndex)
    local menu = type(id) == 'string' and menus[id] or nil
    if not menu then
        return false, ('no menu named %s'):format(tostring(id))
    end
    local count = #menu.options
    local s = {
        id = id,
        menu = menu,
        selected = math.floor(I.num(startIndex, 1, math.max(1, count), 1)),
        scroll = {},
        checked = {},
        held = {},
    }
    for i, o in ipairs(menu.options) do
        if o.values then s.scroll[i] = math.min(#o.values, o.defaultIndex) end
        s.checked[i] = o.checked
    end
    open = s
    I.send('menu:open', {
        id = id,
        title = menu.title,
        position = menu.position or I.defaults.menuPosition,
        options = view(s),
        selected = s.selected,
    })
    -- A menu replacing another reuses nothing: the previous thread sees
    -- open ~= its state and ends on its next frame.
    CreateThread(function()
        while open == s do
            frame(s)
            Wait(0)
        end
    end)
    return true
end

--- @param onExit boolean|nil  true runs the menu's onClose
local function hideMenu(onExit)
    if not open then
        return false
    end
    return close(open, nil, onExit == true)
end

local function getOpenMenu()
    return open and open.id or nil
end

--- @param id string
--- @param options table  the full list, or one option when index is given
--- @param index integer|nil
local function setMenuOptions(id, options, index)
    local menu = type(id) == 'string' and menus[id] or nil
    if not menu then
        return false, ('no menu named %s'):format(tostring(id))
    end
    if type(options) ~= 'table' then
        return false, 'options must be a table'
    end
    if index ~= nil then
        index = math.floor(I.num(index, 1, MAX_OPTIONS, 0))
        local o = readOption(options)
        if index < 1 or not o or index > #menu.options + 1 then
            return false, 'index must point at an existing option or one past the end'
        end
        menu.options[index] = o
    else
        menu.options = readOptions(options)
    end
    local s = open
    if s and s.menu == menu then
        local count = #menu.options
        if s.selected > count then s.selected = math.max(1, count) end
        for i, o in ipairs(menu.options) do
            if o.values and (not s.scroll[i] or s.scroll[i] > #o.values) then
                s.scroll[i] = math.min(#o.values, o.defaultIndex)
            end
            if index == nil or index == i then s.checked[i] = o.checked end
        end
        I.send('menu:state', { selected = s.selected, options = view(s) })
    end
    return true
end

I.onStop(function(resource, all)
    if all then
        if open then close(open, nil, false) end
        menus = {}
        CisOwned.clear(owned)
        return
    end
    for _, rec in ipairs(CisOwned.release(owned, resource)) do
        CisOwned.forget(owned, rec.kind, rec.id)
        if open and open.id == rec.id then
            close(open, nil, false)
        end
        menus[rec.id] = nil
    end
end)

-- Opened before the page loaded, or the page reloaded: draw it (again).
I.onReady(function()
    if open then
        local s = open
        I.send('menu:open', {
            id = s.id, title = s.menu.title, position = s.menu.position or I.defaults.menuPosition,
            options = view(s), selected = s.selected,
        })
    end
end)

exports('RegisterMenu', registerMenu)
exports('ShowMenu', showMenu)
exports('HideMenu', hideMenu)
exports('GetOpenMenu', getOpenMenu)
exports('SetMenuOptions', setMenuOptions)

I.menu = { register = registerMenu, show = showMenu, hide = hideMenu, getOpen = getOpenMenu, setOptions = setMenuOptions }
