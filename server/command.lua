-- Server commands with argument validation, source injection and a usage line.
--
-- cis_libs NEVER CALLS add_ace ITSELF. A command's `restricted` flag is a
-- DECLARATION, and
-- `RegisterCommand` does the check. When a command is declared restricted and
-- nobody has granted the ACE, it refuses -- and it prints the exact `add_ace`
-- line the operator needs, because a command that silently never runs is the
-- worst outcome available and an operator has no way to guess why.
--
-- THE INJECTED SOURCE IS NOT OPTIONAL and not a parameter. `source` inside a
-- command handler is the platform's, and a command that exposes it as an
-- argument lets a caller name anyone. The handler signature is
-- `(source, args, raw)`, which is the order RegisterCommand already uses, so
-- nothing about the platform is hidden.

local commands = {}
local usageWarned = {}

-- Split a command line the way a shell does not, and the way a player expects:
-- double quotes group, single quotes do not expand anything, and there is no
-- backslash escape because the platform has none and inventing one would make
-- a path with a backslash in it depend on this parser rather than on the OS.
function CisCommandParse(raw)
    if type(raw) ~= 'string' then
        return {}
    end
    local args = {}
    local current = nil
    local quote = nil
    local i = 1
    while i <= #raw do
        local c = raw:sub(i, i)
        if quote then
            if c == quote then
                quote = nil
            else
                current = (current or '') .. c
            end
        elseif c == '"' or c == "'" then
            quote = c
            current = current or ''
        elseif c:match('%s') then
            if current ~= nil then
                args[#args + 1] = current
                current = nil
            end
        else
            current = (current or '') .. c
        end
        i = i + 1
    end
    if current ~= nil then args[#args + 1] = current end
    return args
end

local function paramName(p)
    if type(p) == 'table' then
        return p.name or p.help or '?'
    end
    return tostring(p)
end

function CisCommandNames()
    local out = {}
    for name in pairs(commands) do out[#out + 1] = name end
    table.sort(out)
    return out
end

local function buildUsage(entry)
    local parts = { entry.name }
    for _, p in ipairs(entry.params) do
        parts[#parts + 1] = ('<%s>'):format(paramName(p))
    end
    local line = table.concat(parts, ' ')
    if entry.restricted then
        local group = type(entry.restricted) == 'string' and entry.restricted or 'group.admin'
        line = line .. ('   [restricted -- add_ace %s command.%s allow]'):format(group, entry.name)
    end
    return line
end

local function suggestionParams(params)
    local out = {}
    for _, p in ipairs(params) do
        if type(p) == 'table' then
            out[#out + 1] = { name = tostring(p.name or p.help or 'arg'), help = tostring(p.help or p.name or '') }
        else
            out[#out + 1] = { name = tostring(p), help = '' }
        end
    end
    return out
end

function CisCommandAdd(name, options, handler)
    if type(name) ~= 'string' or not name:match('^[%w_%-]+$') then
        return false, ('command name must be letters, digits, underscore or hyphen; got %s'):format(tostring(name))
    end
    if type(options) ~= 'table' then
        return false, ('options must be a table; got %s'):format(type(options))
    end
    if type(handler) ~= 'function' then
        return false, 'the handler must be a function. A function cannot cross the exports boundary, so a command registered from a CONSUMER resource receives nil -- register it from cis_libs, or use RegisterCommand directly'
    end
    if commands[name] then
        return false, ('a command named %q is already registered; remove it first'):format(name)
    end

    local restricted = options.restricted
    if restricted ~= nil and restricted ~= false and restricted ~= true and type(restricted) ~= 'string' then
        return false, ("restricted must be true, false, or an ACE group string like 'group.admin'; got %s")
            :format(type(restricted))
    end

    local params = options.params
    if params ~= nil and type(params) ~= 'table' then
        return false, 'params must be an array of names'
    end

    local entry = {
        name = name,
        params = params or {},
        help = options.help,
        restricted = restricted,
        handler = handler,
        owner = GetInvokingResource() or 'cis_libs',
    }
    commands[name] = entry

    -- RegisterCommand (CFX, shared): (commandName, handler, restricted).
    -- The handler is (source, args, rawCommand). args is already a table of
    -- strings WITHOUT the command name. rawCommand is the full line, including
    -- it. Parsing raw is what makes quoted arguments work; using args as-is
    -- splits on every space and cannot group.
    RegisterCommand(name, function(src, args, rawCommand)
        if restricted and src ~= 0 then
            -- IS_PRINCIPAL_ACE_ALLOWED (CFX, shared): (principal: char*, object: char*).
            -- BOTH are strings. Passing the numeric source is a type error the
            -- native answers by refusing, which looks like "the ACE is missing"
            -- and prints the add_ace line forever.
            local principal = ('player.%s'):format(src)
            local object = ('command.%s'):format(name)
            if not IsPrincipalAceAllowed(principal, object) then
                local group = type(restricted) == 'string' and restricted or 'group.admin'
                if CisLog then
                    CisLog('warn', ('cis_libs: %q was refused for src %s. Grant it with: add_ace %s command.%s allow')
                        :format(name, tostring(src), group, name))
                end
                return
            end
        end

        local parsed
        if type(rawCommand) == 'string' and rawCommand ~= '' then
            parsed = CisCommandParse(rawCommand)
            if parsed[1] == name then
                table.remove(parsed, 1)
            end
        else
            parsed = type(args) == 'table' and args or {}
        end

        local count = #entry.params
        if #parsed < count then
            local key = name .. ':usage'
            if not usageWarned[key] then
                usageWarned[key] = true
                if CisLog then
                    CisLog('info', ('cis_libs: usage: %s'):format(buildUsage(entry)))
                end
            end
            return
        end

        local ok, err = pcall(entry.handler, src, parsed, rawCommand)
        if not ok and CisLog then
            CisLog('error', ('cis_libs: command %q raised: %s'):format(name, tostring(err)))
        end
    end, restricted and true or false)

    -- chat suggestions while `chat` is started. The seam is
    -- TriggerClientEvent('chat:addSuggestion', ...), allow-listed in the
    -- contract test. cis_libs does not ship chat.
    if GetResourceState and GetResourceState('chat') == 'started' then
        TriggerClientEvent('chat:addSuggestion', -1, '/' .. name, entry.help or '', suggestionParams(entry.params))
    end

    return true
end

function CisCommandList()
    local out = {}
    for _, name in ipairs(CisCommandNames()) do
        out[#out + 1] = { name = name, usage = buildUsage(commands[name]), help = commands[name].help }
    end
    return out
end

exports('CommandAdd', CisCommandAdd)
exports('CommandList', CisCommandList)
exports('CommandRemove', function(name)
    if not commands[name] then return false, ('no command named %q'):format(tostring(name)) end
    commands[name] = nil
    return true
end)
exports('CommandParse', CisCommandParse)

CisDiagnostics.Register('server', 'commands', function()
    local byOwner = {}
    local restricted = 0
    local total = 0
    for _, c in pairs(commands) do
        total = total + 1
        if c.restricted then restricted = restricted + 1 end
        byOwner[c.owner] = (byOwner[c.owner] or 0) + 1
    end
    return { total = total, restricted = restricted, byOwner = byOwner }
end)
