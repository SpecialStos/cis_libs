-- The `ui` slot.
--
-- A provider that does toasts, a textUI overlay, progress, a confirm dialog,
-- an input dialog registers this slot and every call below forwards to it.
-- Without one, each call uses cis_libs' own NUI (client/interface/*, the
-- Toast / ProgressBar / AlertDialog / InputDialog exports). Only if that is
-- missing too do notify and textUI fall back to the GTA feed and the
-- help-text native, while progress, confirm and input, with nothing honest to
-- draw, answer `false, 'no ui provider'`.
--
-- THIS IS NOT Cis.framework.notify. That export is player-targeted, lives
-- on both realms, is rate-limited, and goes through the framework slot
-- before the same GTA feed. A server that wants to tell a player something
-- uses Cis.framework.notify. A client that wants a toast or a prompt uses
-- Cis.ui.*.
--
-- HELP TEXT IS ONE GLOBAL SLOT. EndTextCommandDisplayHelp with loop=true
-- stays until ClearAllHelpMessages, and that native clears EVERY help
-- message on the screen, not just ours. Last show wins. Hide is global.
-- That is a property of the native, not a defect in the fallback, and it
-- is why a NUI provider is the better answer the moment one exists.
--
-- ADD_TEXT_COMPONENT_SUBSTRING_PLAYER_NAME is 99 characters. A longer
-- string is chunked; a single call silently truncates and the player sees
-- a cut sentence with no error.

local nativeOpen = false
local nativeOwner = nil

-- ADD_TEXT_COMPONENT_SUBSTRING_PLAYER_NAME (0x6C188BE134E074AA): "up to
-- 99 characters". Inclusive sub(i, i+98) is 99.
local COMPONENT_MAX = 99

local function addComponents(text)
    local n = #text
    if n == 0 then
        AddTextComponentSubstringPlayerName('')
        return
    end
    -- Each piece ENDS ON A UTF-8 CHARACTER BOUNDARY. A fixed 99-byte cut went
    -- through the middle of any multi-byte character that straddled it, and both
    -- halves rendered as garbage. A continuation byte is 10xxxxxx; the cut steps
    -- back until the next byte is not one.
    local i = 1
    while i <= n do
        local j = math.min(i + COMPONENT_MAX - 1, n)
        while j < n and j > i do
            local b = text:byte(j + 1)
            if b < 0x80 or b >= 0xC0 then break end
            j = j - 1
        end
        AddTextComponentSubstringPlayerName(text:sub(i, j))
        i = j + 1
    end
end

local function nativeNotify(text)
    BeginTextCommandThefeedPost('STRING')
    addComponents(text)
    EndTextCommandThefeedPostTicker(false, false)
end

local function nativeHelpShow(text)
    BeginTextCommandDisplayHelp('STRING')
    addComponents(text)
    -- shape 0, loop true, beep false, duration -1. loop=true stays until
    -- ClearAllHelpMessages -- verified natives_gta.json
    -- END_TEXT_COMMAND_DISPLAY_HELP (0x238FFE5C7B0498A6).
    EndTextCommandDisplayHelp(0, true, false, -1)
end

local function nativeHelpHide()
    ClearAllHelpMessages()
end

local function noProvider()
    return false, 'no ui provider'
end

-- The built-in NUI (client/interface/*). Loaded after this file in the same VM,
-- so it is looked up at call time, never captured at load.
local function builtin(part)
    local ui = CisInterface
    return type(ui) == 'table' and ui[part] or nil
end

-- A provider answered (including a provider false). Dispatch failure and
-- an empty slot are the same from here: the caller falls through to the
-- native, or to noProvider, depending on the method.
local function callProvider(method, ...)
    if not (CisRegistry and CisRegistry.has and CisRegistry.has('ui')) then
        return false
    end
    local results = table.pack(CisRegistry.call('ui', method, ...))
    if not results[1] then
        return false
    end
    return true, table.unpack(results, 2, results.n)
end

local function coerceNotify(message, kind)
    if type(message) == 'table' then
        kind = message.type or message.kind or kind
        local text = message.description or message.message or message.title
        if type(text) ~= 'string' or text == '' then
            return nil, 'notify needs a message string (description, message or title)'
        end
        return text, kind
    end
    if type(message) ~= 'string' or message == '' then
        return nil, ('notify needs a message string, got %s'):format(type(message))
    end
    return message, kind
end

local function closeNative()
    if not nativeOpen then
        nativeOpen = false
        nativeOwner = nil
        return
    end
    nativeHelpHide()
    nativeOpen = false
    nativeOwner = nil
end

function CisUiNotify(message, kind)
    local text, typeName = coerceNotify(message, kind)
    if not text then
        return false, typeName
    end
    local handled, a, b = callProvider('Notify', text, typeName)
    if handled then
        return a, b
    end
    local toast = builtin('notify')
    if toast then
        if type(message) == 'table' then
            local data = {}
            for k, v in pairs(message) do data[k] = v end
            data.description = data.description or data.message or (not data.title and text) or nil
            data.type = typeName
            return toast(data)
        end
        return toast({ description = text, type = typeName })
    end
    nativeNotify(text)
    return true
end

function CisUiTextUIShow(text, opts)
    if type(text) ~= 'string' or text == '' then
        return false, ('textUI.show needs a non-empty string, got %s'):format(type(text))
    end
    local handled, a, b = callProvider('TextUIShow', text, opts)
    if handled then
        closeNative()
        return a, b
    end
    local textUI = builtin('textUI')
    if textUI then
        closeNative()
        return textUI.show(text, opts)
    end
    nativeHelpShow(text)
    nativeOpen = true
    nativeOwner = GetInvokingResource() or GetCurrentResourceName() or 'cis_libs'
    return true
end

function CisUiTextUIHide()
    local handled, a, b = callProvider('TextUIHide')
    closeNative()
    if handled then
        return a, b
    end
    local textUI = builtin('textUI')
    if textUI then
        return textUI.hide()
    end
    return true
end

function CisUiTextUIIsOpen()
    local handled, a = callProvider('TextUIIsOpen')
    if handled then
        return a == true
    end
    local textUI = builtin('textUI')
    if textUI then
        return (textUI.isOpen()) == true
    end
    return nativeOpen == true
end

function CisUiProgress(opts)
    if type(opts) ~= 'table' then
        return false, ('progress needs a table, got %s'):format(type(opts))
    end
    local handled, a, b = callProvider('Progress', opts)
    if handled then
        return a, b
    end
    local progress = builtin('progress')
    if progress then
        if opts.type == 'circle' then
            return progress.circle(opts)
        end
        return progress.bar(opts)
    end
    return noProvider()
end

function CisUiConfirm(opts)
    if type(opts) ~= 'table' then
        return false, ('confirm needs a table, got %s'):format(type(opts))
    end
    local handled, a, b = callProvider('Confirm', opts)
    if handled then
        return a, b
    end
    local alert = builtin('alert')
    if alert then
        local result, why = alert.open({
            header = opts.header or opts.title,
            content = opts.content or opts.message,
            cancel = opts.cancel ~= false,
            labels = opts.labels,
            size = opts.size,
            centered = opts.centered,
        })
        if result == nil then
            return false, why
        end
        return result == 'confirm', result
    end
    return noProvider()
end

function CisUiInput(opts)
    if type(opts) ~= 'table' then
        return false, ('input needs a table, got %s'):format(type(opts))
    end
    local handled, a, b = callProvider('Input', opts)
    if handled then
        return a, b
    end
    local input = builtin('input')
    if input then
        return input.open(opts.heading or opts.title, opts.rows, opts.options)
    end
    return noProvider()
end

exports('UiNotify', CisUiNotify)
exports('UiTextUIShow', CisUiTextUIShow)
exports('UiTextUIHide', CisUiTextUIHide)
exports('UiTextUIIsOpen', CisUiTextUIIsOpen)
exports('UiProgress', CisUiProgress)
exports('UiConfirm', CisUiConfirm)
exports('UiInput', CisUiInput)

CisDiagnostics.Register('client', 'ui', function()
    return {
        nativeOpen = nativeOpen == true,
        hasProvider = CisRegistry and CisRegistry.has and CisRegistry.has('ui') or false,
    }
end)

AddEventHandler('onResourceStop', function(resource)
    -- A forged stop from another client script is ignored (shared/owned.lua).
    if not CisRealStop(resource) then
        return
    end
    if not nativeOpen then
        return
    end
    local selfName = GetCurrentResourceName()
    if resource == selfName or resource == nativeOwner then
        closeNative()
    end
end)
