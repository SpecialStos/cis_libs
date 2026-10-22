-- cis_libs' key bindings: ONE instance of the engine in client/core/keybind.lua,
-- behind the KeybindAdd / KeybindDisable / KeybindEnable / KeybindRemove /
-- KeybindIsPressed / Keybinds exports.
--
-- Owner tracking, the owner check on the id-based controls, the snapshot list
-- and the stop sweep live here. The commands, the mapping and the handle are
-- the engine's -- the same text a consumer's `Cis.keybind.add` runs in its own
-- VM, where the binding belongs to the consumer and its handlers are local.

local owned = CisOwned.new()

local engine = CisCore.keybind.new({
    callable = CisCallable,
    log = function(level, message)
        if CisLog then CisLog(level, message) end
    end,
    onRegister = function(handle)
        CisOwned.track(owned, handle.owner, 'keybind', handle.id)
    end,
    onRetire = function(handle)
        CisOwned.forget(owned, 'keybind', handle.id)
    end,
})
local binds = engine.binds

function CisKeybindAdd(options)
    return engine:add(options, GetInvokingResource() or 'cis_libs')
end

-- The id-based surface, for a consumer whose handle arrived without methods.
-- Changing a binding is the owner's (or cis_libs's) business; asking whether
-- it is pressed is anyone's.
local function controlled(id)
    local b = engine:get(id)
    if not b then
        return nil, ('no keybind with id %s'):format(tostring(id))
    end
    local caller = GetInvokingResource() or 'cis_libs'
    if caller ~= 'cis_libs' and caller ~= b.owner then
        return nil, ('keybind %s belongs to %s, not %s'):format(tostring(id), tostring(b.owner), caller)
    end
    return b
end

function CisKeybindDisable(id, state)
    local b, why = controlled(id)
    if not b then return false, why end
    b:disable(state)
    return true
end

function CisKeybindEnable(id)
    return CisKeybindDisable(id, false)
end

function CisKeybindRemove(id)
    local b, why = controlled(id)
    if not b then return false, why end
    return b:destroy()
end

function CisKeybindIsPressed(id)
    local b = engine:get(id)
    return b ~= nil and b.pressed == true
end

exports('KeybindAdd', CisKeybindAdd)
exports('KeybindDisable', CisKeybindDisable)
exports('KeybindEnable', CisKeybindEnable)
exports('KeybindRemove', CisKeybindRemove)
exports('KeybindIsPressed', CisKeybindIsPressed)
-- SNAPSHOTS, never the live records and never the callbacks.
exports('Keybinds', function()
    local out = {}
    for _, b in pairs(binds) do
        out[#out + 1] = {
            id = b.id,
            name = b.name,
            owner = b.owner,
            command = b.command,
            enabled = b.enabled,
            pressed = b.pressed,
        }
    end
    table.sort(out, function(x, y) return x.id < y.id end)
    return out
end)

CisDiagnostics.Register('client', 'keybinds', function()
    local byOwner = {}
    local total = 0
    for _, b in pairs(binds) do
        total = total + 1
        byOwner[b.owner] = (byOwner[b.owner] or 0) + 1
    end
    return { total = total, byOwner = byOwner }
end)

-- A stopped resource's bindings go inert: its funcrefs are dead, and a command
-- still holding one raised on every key press for the rest of the session.
AddEventHandler('onResourceStop', function(resource)
    -- A forged stop from another client script is ignored (shared/owned.lua).
    if not CisRealStop(resource) then
        return
    end
    local freed = CisOwned.release(owned, resource)
    for i = 1, #freed do
        local b = freed[i].kind == 'keybind' and binds[freed[i].id] or nil
        if b then
            engine:retire(b)
        else
            CisOwned.forget(owned, freed[i].kind, freed[i].id)
        end
    end
end)
