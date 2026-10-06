-- The `ui` slot.
--
-- cis_libs ships no NUI. A provider that does toasts, a textUI overlay,
-- progress, a confirm dialog, an input dialog registers this slot and every
-- call below forwards to it. Without one, notify and textUI still work: the
-- GTA feed and the help-text native. progress, confirm and input have
-- nothing honest to draw, so they answer `false, 'no ui provider'`.
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
    local i = 1
    while i <= n do
        AddTextComponentSubstringPlayerName(text:sub(i, i + COMPONENT_MAX - 1))
        i = i + COMPONENT_MAX
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
    return true
end

function CisUiTextUIIsOpen()
    local handled, a = callProvider('TextUIIsOpen')
    if handled then
        return a == true
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
    if not nativeOpen then
        return
    end
    local selfName = GetCurrentResourceName()
    if resource == selfName or resource == nativeOwner then
        closeNative()
    end
end)
