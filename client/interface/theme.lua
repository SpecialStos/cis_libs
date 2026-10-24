-- Theme and built-in label strings, plus the page's `ready` handshake (the
-- page is told both as soon as it loads, and again whenever either changes).
--
-- Both are validated here rather than trusted to the page: a theme value ends
-- up in style.setProperty, and a value like url(...) would make the UI fetch
-- from the network. (The page does load an icon or image a consumer names by
-- URL; a theme is never a way in.)

local I = CisInterface

local theme = {}
local locale = {}

local MODES = { dark = true, light = true, auto = true }
local NOTIFY_POSITIONS = {
    top = true, ['top-right'] = true, ['top-left'] = true, bottom = true,
    ['bottom-right'] = true, ['bottom-left'] = true, ['center-right'] = true, ['center-left'] = true,
}
local TEXTUI_POSITIONS = { ['right-center'] = true, ['left-center'] = true, ['top-center'] = true, ['bottom-center'] = true }
local PROGRESS_POSITIONS = { bottom = true, middle = true }
local MENU_POSITIONS = { ['top-left'] = true, ['top-right'] = true, ['bottom-left'] = true, ['bottom-right'] = true }
-- The colour tokens style.css reads. Any other key was accepted and set as a
-- --cis-<key> property, so a theme could overwrite --cis-place or --cis-p (the
-- layout and progress variables) with a colour and break a component.
local COLOR_KEYS = {
    accent = true, ['accent-fg'] = true, bg = true, surface = true, hover = true, border = true,
    fg = true, muted = true, backdrop = true, inform = true, success = true, warning = true, error = true,
}
local LOCALE_KEYS = {
    'confirm', 'cancel', 'close', 'back', 'more', 'notifications', 'progressCancel',
    'required', 'invalid', 'invalidNumber', 'min', 'max', 'minLength', 'maxLength',
    'maxSelected', 'invalidColor', 'invalidDate', 'minDate', 'maxDate', 'invalidRange',
    'from', 'to', 'pressKey', 'lang',
}

-- The defaults components fall back to when a call names no position.
I.defaults = {
    notifyPosition = 'top-right',
    textUIPosition = 'right-center',
    progressPosition = 'bottom',
    menuPosition = 'top-left',
}

--- @param data table  { accent, radius, fontScale, mode, reducedMotion, colors, notifyPosition,
---   textUIPosition, progressPosition, menuPosition, notifyMax }
local function setUiTheme(data)
    if type(data) ~= 'table' then
        return false, ('theme needs a table, got %s'):format(type(data))
    end
    local next_ = {}
    for k, v in pairs(theme) do next_[k] = v end

    if data.accent ~= nil then
        next_.accent = I.color(data.accent)
        if not next_.accent then return false, 'accent must be a CSS colour (#hex, rgb(), hsl() or a name)' end
    end
    if data.radius ~= nil then
        next_.radius = I.num(data.radius, 0, 32)
        if not next_.radius then return false, 'radius must be a number of pixels (0-32)' end
    end
    if data.fontScale ~= nil then
        next_.fontScale = I.num(data.fontScale, 0.75, 1.5)
        if not next_.fontScale then return false, 'fontScale must be a number (0.75-1.5)' end
    end
    if data.mode ~= nil then
        if not MODES[data.mode] then return false, "mode must be 'dark', 'light' or 'auto'" end
        next_.mode = data.mode
    end
    if data.reducedMotion ~= nil then
        next_.reducedMotion = data.reducedMotion == true
    end
    if data.notifyMax ~= nil then
        next_.notifyMax = I.num(data.notifyMax, 1, 10)
        if not next_.notifyMax then return false, 'notifyMax must be a number (1-10)' end
        next_.notifyMax = math.floor(next_.notifyMax)
    end
    for key, allowed in pairs({
        notifyPosition = NOTIFY_POSITIONS, textUIPosition = TEXTUI_POSITIONS,
        progressPosition = PROGRESS_POSITIONS, menuPosition = MENU_POSITIONS,
    }) do
        if data[key] ~= nil then
            if not allowed[data[key]] then
                return false, ('%s %s is not a known position'):format(key, tostring(data[key]))
            end
            next_[key] = data[key]
        end
    end
    if data.colors ~= nil then
        if type(data.colors) ~= 'table' then return false, 'colors must be a table of name = colour' end
        local colors = {}
        for k, v in pairs(next_.colors or {}) do colors[k] = v end
        for k, v in pairs(data.colors) do
            if not COLOR_KEYS[k] then
                return false, ('colors key %s is not a colour token'):format(tostring(k))
            end
            local c = I.color(v)
            if not c then return false, ('colors.%s is not a CSS colour'):format(k) end
            colors[k] = c
        end
        next_.colors = colors
    end

    theme = next_
    for key in pairs(I.defaults) do
        if theme[key] then I.defaults[key] = theme[key] end
    end
    I.send('theme', theme)
    return true
end

--- @param strings table  { confirm = 'Bestätigen', cancel = 'Abbrechen', ... }
local function setUiLocale(strings)
    if type(strings) ~= 'table' then
        return false, ('locale needs a table, got %s'):format(type(strings))
    end
    for _, key in ipairs(LOCALE_KEYS) do
        local v = I.str(strings[key], 200)
        if v then locale[key] = v end
    end
    I.send('locale', locale)
    return true
end

-- A handshake, not a single post: see I.acceptReady (nui.lua).
I.on('ready', { token = '?string' }, function(data)
    if I.acceptReady(data.token) then
        I.markReady({ theme = theme, locale = locale })
    end
end)

exports('SetUiTheme', setUiTheme)
exports('SetUiLocale', setUiLocale)

I.setTheme = setUiTheme
I.setLocale = setUiLocale
