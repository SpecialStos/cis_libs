-- Text UI: one persistent prompt. Pure NUI, no focus, no thread. Last show
-- wins; the resource that showed it is recorded so its stop hides it.

local I = CisInterface

local POSITIONS = { ['right-center'] = true, ['left-center'] = true, ['top-center'] = true, ['bottom-center'] = true }
local STYLES = { default = true, minimal = true, accent = true, key = true }
local current = nil -- { text, owner, payload }

--- @param text string
--- @param options table|nil  { position, icon, iconColor, style, key }
local function showTextUI(text, options)
    local value = I.str(text, 1024)
    if not value then
        return false, ('text UI needs a non-empty string, got %s'):format(type(text))
    end
    if options ~= nil and type(options) ~= 'table' then
        return false, ('options must be a table, got %s'):format(type(options))
    end
    options = options or {}
    current = {
        text = value,
        owner = I.caller(),
        payload = {
            text = value,
            position = POSITIONS[options.position] and options.position or I.defaults.textUIPosition,
            icon = I.icon(options.icon),
            iconColor = I.color(options.iconColor),
            style = STYLES[options.style] and options.style or nil,
            key = I.str(options.key, 8),
        },
    }
    local sent, why = I.send('textui:show', current.payload)
    if sent == false and I.ready then
        current = nil
        return false, ('text UI not shown: %s'):format(tostring(why or 'the page refused the message'))
    end
    return true
end

local function hideTextUI()
    if current then
        current = nil
        I.send('textui:hide', {})
    end
    return true
end

local function isTextUIOpen()
    return current ~= nil, current and current.text or nil
end

I.onStop(function(resource, all)
    if current and (all or current.owner == resource) then
        hideTextUI()
    end
end)

-- Shown before the page loaded, or the page reloaded: draw it (again).
I.onReady(function()
    if current then
        I.send('textui:show', current.payload)
    end
end)

exports('ShowTextUI', showTextUI)
exports('HideTextUI', hideTextUI)
exports('IsTextUIOpen', isTextUIOpen)

I.textUI = { show = showTextUI, hide = hideTextUI, isOpen = isTextUIOpen }
