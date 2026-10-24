-- Radial menu: global items any resource can add, plus registered submenus.
--
-- THE KEYBIND IS REGISTERED LAZILY, the first time an item is added. A key
-- mapping is written into the player's settings and outlives the resource, so
-- a server with no radial items never gets a "Radial menu" entry nobody can
-- use. Pressing the key toggles the menu; it opens with NUI focus (cursor) and
-- keepInput, so the player can keep walking, and a thread that exists only
-- while it is open disables looking, attacking and the pause menu.
--
-- Items and submenus are owner-tracked; a resource stopping takes its items
-- with it and the menu on screen is redrawn (or closed if it was theirs).
--
-- AN ITEM OR SUBMENU BELONGS TO ITS REGISTRANT. Another resource adding the
-- same id, registering the same submenu, removing the item or clearing is
-- refused or scoped to its own entries (the D3 rule); it could strip or swap
-- every resource's entries. cis_libs itself may still remove or clear anything.

local I = CisInterface

local COMMAND = '+cis_libs_radial'
-- 22 (jump, Space): a click on a slot was also a jump while walking.
local DISABLED_WHILE_OPEN = { 1, 2, 14, 15, 16, 17, 22, 24, 25, 37, 140, 141, 142, 199, 200, 257, 263 }
local MAX_ITEMS = 64
local LIB = GetCurrentResourceName() or 'cis_libs'

local items = {}   -- ordered global items
local radials = {} -- id -> { id, items, owner }
local owned = CisOwned.new()
local disabled = false
local keybound = false
local open = nil   -- { token, path = { submenu ids }, list }

local function readItem(item, owner)
    if type(item) ~= 'table' then
        return nil, 'a radial item must be a table'
    end
    if type(item.id) ~= 'string' or item.id == '' or #item.id > 128 then
        return nil, 'a radial item needs a string id'
    end
    if item.onSelect ~= nil and not CisCallable(item.onSelect) then
        return nil, ('radial item %s: onSelect must be a function'):format(item.id)
    end
    return {
        id = item.id,
        label = I.str(item.label, 64) or '',
        icon = I.icon(item.icon),
        iconColor = I.color(item.iconColor),
        menu = type(item.menu) == 'string' and item.menu or nil,
        onSelect = item.onSelect,
        keepOpen = item.keepOpen == true,
        owner = owner,
    }
end

local function view(list)
    local out = {}
    for i, it in ipairs(list) do
        out[i] = { label = it.label, icon = it.icon, iconColor = it.iconColor, hasMenu = it.menu ~= nil }
    end
    return out
end

local function currentList()
    local id = open and open.path[#open.path]
    if id then
        return radials[id] and radials[id].items or {}
    end
    return items
end

local function close()
    if not open then
        return false
    end
    open = nil
    I.focus.pop('radial')
    I.send('radial:close', {})
    return true
end

local function draw()
    if not open then return end
    open.token = I.nextId()
    open.list = currentList()
    if #open.list == 0 and #open.path == 0 then
        close()
        return
    end
    local sent, why = I.send('radial:open', { token = open.token, items = view(open.list), hasBack = #open.path > 0 })
    if sent == false and I.ready then
        -- Not drawn (over the NUI cap): close, so no cursor stays up for nothing.
        I.log('error', ('radial menu not drawn: %s'):format(tostring(why)))
        close()
    end
end

local function show()
    if open or disabled or #items == 0 or not I.ready or IsPauseMenuActive() then
        return false
    end
    local s = { path = {} }
    open = s
    local ok, err = pcall(function()
        I.focus.push('radial', {
            keepInput = true,
            onEscape = function()
                if open == s then close() end
            end,
        })
        draw()
    end)
    if not ok then
        I.log('error', ('radial failed to open: %s'):format(tostring(err)))
        if open == s then close() end
        return false
    end
    if open ~= s then
        return false
    end
    CreateThread(function()
        while open == s do
            for i = 1, #DISABLED_WHILE_OPEN do
                DisableControlAction(0, DISABLED_WHILE_OPEN[i], true)
            end
            Wait(0)
        end
    end)
    return true
end

local function ensureKeybind()
    if keybound then return end
    keybound = true
    RegisterCommand(COMMAND, function()
        if open then close() else show() end
    end, false)
    RegisterCommand('-cis_libs_radial', function() end, false)
    RegisterKeyMapping(COMMAND, 'Radial menu', 'keyboard', 'z')
end

local function itemOwner(id)
    for i = 1, #items do
        if items[i].id == id then
            return items[i].owner
        end
    end
    return nil
end

local function removeItem(id)
    for i = #items, 1, -1 do
        if items[i].id == id then
            table.remove(items, i)
            CisOwned.forget(owned, 'radialItem', id)
            return true
        end
    end
    return false
end

--- @param data table  one item ({ id, label, icon, iconColor, menu, onSelect, keepOpen }) or a list
local function addRadialItem(data)
    local owner = I.caller()
    if type(data) ~= 'table' then
        return false, ('radial items must be a table, got %s'):format(type(data))
    end
    local list = data.id ~= nil and { data } or data
    local clean = {}
    for i, raw in ipairs(list) do
        local it, err = readItem(raw, owner)
        if not it then
            return false, ('item %d: %s'):format(i, err)
        end
        clean[#clean + 1] = it
    end
    -- ALL OR NOTHING. The cap used to be checked item by item, so a list that
    -- overflowed was half added (and a replaced item half removed) before the
    -- error came back.
    local incoming, count = {}, 0
    for _, it in ipairs(clean) do
        if not incoming[it.id] then incoming[it.id] = true; count = count + 1 end
    end
    for _, it in ipairs(items) do
        if not incoming[it.id] then count = count + 1 end
    end
    if count > MAX_ITEMS then
        return false, ('at most %d radial items'):format(MAX_ITEMS)
    end
    for _, it in ipairs(clean) do
        local holder = itemOwner(it.id)
        if holder and holder ~= owner then
            return false, ('radial item %q is registered by %s; pick a different id'):format(it.id, tostring(holder))
        end
    end
    for _, it in ipairs(clean) do
        removeItem(it.id)
        items[#items + 1] = it
        CisOwned.track(owned, owner, 'radialItem', it.id)
    end
    ensureKeybind()
    if open and #open.path == 0 then draw() end
    return true
end

local function removeRadialItem(id)
    local caller = I.caller()
    local holder = itemOwner(id)
    if holder == nil then
        return false, ('no radial item %s'):format(tostring(id))
    end
    if holder ~= caller and caller ~= LIB then
        return false, ('radial item %q is registered by %s'):format(id, tostring(holder))
    end
    removeItem(id)
    if open and #open.path == 0 then draw() end
    return true
end

-- The caller's own items; every item when cis_libs itself clears.
local function clearRadialItems()
    local caller = I.caller()
    local removed = false
    for i = #items, 1, -1 do
        if caller == LIB or items[i].owner == caller then
            CisOwned.forget(owned, 'radialItem', items[i].id)
            table.remove(items, i)
            removed = true
        end
    end
    if removed and open and #open.path == 0 then draw() end
    return true
end

--- @param radial table  { id, items }
local function registerRadial(radial)
    local owner = I.caller()
    if type(radial) ~= 'table' or type(radial.id) ~= 'string' or radial.id == '' then
        return false, 'a radial submenu needs a string id'
    end
    if type(radial.items) ~= 'table' then
        return false, 'a radial submenu needs a list of items'
    end
    local list = {}
    for i, raw in ipairs(radial.items) do
        if type(raw) == 'table' and raw.id == nil then
            raw = setmetatable({ id = ('%s:%d'):format(radial.id, i) }, { __index = raw })
        end
        local it, err = readItem(raw, owner)
        if not it then
            return false, ('item %d: %s'):format(i, err)
        end
        list[#list + 1] = it
    end
    local held = radials[radial.id]
    if held and held.owner ~= owner then
        return false, ('radial submenu %q is registered by %s; pick a different id'):format(radial.id, tostring(held.owner))
    end
    radials[radial.id] = { id = radial.id, items = list, owner = owner }
    CisOwned.track(owned, owner, 'radial', radial.id)
    if open and open.path[#open.path] == radial.id then draw() end
    return true
end

local function hideRadial()
    return close()
end

--- @param state boolean
local function disableRadial(state)
    disabled = state ~= false
    if disabled then close() end
    return true
end

I.on('radial', { token = 'string', action = 'string', index = '?integer' }, function(data)
    if not open or open.token ~= data.token then
        return
    end
    if data.action == 'close' then
        close()
    elseif data.action == 'back' then
        if #open.path > 0 then
            table.remove(open.path)
            draw()
        else
            close()
        end
    elseif data.action == 'select' then
        local it = data.index and open.list[data.index]
        if not it then return end
        if it.menu and radials[it.menu] then
            open.path[#open.path + 1] = it.menu
            draw()
            return
        end
        local menuId = open.path[#open.path]
        if not it.keepOpen then close() end
        I.invoke(it.onSelect, menuId, data.index)
    end
end)

I.onStop(function(resource, all)
    if all then
        close()
        items, radials = {}, {}
        CisOwned.clear(owned)
        return
    end
    local touched = false
    for _, rec in ipairs(CisOwned.release(owned, resource)) do
        touched = true
        if rec.kind == 'radialItem' then
            removeItem(rec.id)
        else
            CisOwned.forget(owned, rec.kind, rec.id)
            radials[rec.id] = nil
        end
    end
    if touched and open then
        for i = #open.path, 1, -1 do
            if not radials[open.path[i]] then
                for j = #open.path, i, -1 do open.path[j] = nil end
            end
        end
        draw()
    end
end)

I.onReset(function()
    close()
end)

exports('AddRadialItem', addRadialItem)
exports('RemoveRadialItem', removeRadialItem)
exports('ClearRadialItems', clearRadialItems)
exports('RegisterRadial', registerRadial)
exports('HideRadial', hideRadial)
exports('DisableRadial', disableRadial)

I.radial = {
    add = addRadialItem, remove = removeRadialItem, clear = clearRadialItems,
    register = registerRadial, hide = hideRadial, disable = disableRadial, show = show,
}
