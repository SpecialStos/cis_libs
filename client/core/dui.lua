-- DUI: a browser page rendered to a runtime texture.
--
-- Consumer-side only (`Cis.dui.new`, loaded by init.lua from `files {}`). The
-- texture is drawn by the consumer (DrawSprite, AddReplaceTexture), so the page
-- belongs in the consumer's VM.
--
-- DESTROYED. destroy() frees the browser with DestroyDui, and releaseAll() --
-- run by init.lua when the consumer stops -- frees every page still open. A
-- runtime texture dictionary cannot be freed by any native, so each object names
-- its own from the resource, this load and a counter. The counter alone started
-- at 1 again when the consumer restarted, and the new page drew into the
-- destroyed browser's dictionary; the load tag (game timer and random bits,
-- ox_lib does the same) keeps a name from being reused.
--
-- cfg: resource (the consumer's name, for unique dictionary names)

local M = {}

local Factory = {}
Factory.__index = Factory

local Page = {}
Page.__index = Page

local function positiveInt(v, fallback)
    if type(v) == 'number' and v == v and v >= 1 and v < 16384 then
        return math.floor(v)
    end
    return fallback
end

function M.new(cfg)
    cfg = cfg or {}
    return setmetatable({
        resource = tostring(cfg.resource or 'res'),
        loadTag = ('%x%04x'):format(GetGameTimer(), math.random(0, 0xffff)),
        live = {},
        nextId = 0,
    }, Factory)
end

--- Open a page. opts: url (required), width, height (default 1280 x 720).
--- Answers the object (fields dictName, txtName, width, height), or nil and a reason.
function Factory:create(opts)
    if type(opts) ~= 'table' then
        return nil, ('options arrived as %s, not a table'):format(type(opts))
    end
    if type(opts.url) ~= 'string' or opts.url == '' then
        return nil, 'a DUI needs a url string'
    end
    local width = positiveInt(opts.width, 1280)
    local height = positiveInt(opts.height, 720)
    local object = CreateDui(opts.url, width, height)
    if not object or object == 0 then
        return nil, 'the engine refused to create the DUI'
    end
    self.nextId = self.nextId + 1
    local id = self.nextId
    local dictName = ('cis_dui_%s_%s_%d'):format(self.resource, self.loadTag, id)
    local txtName = 'page'
    local txd = CreateRuntimeTxd(dictName)
    CreateRuntimeTextureFromDuiHandle(txd, txtName, GetDuiHandle(object))
    local page = setmetatable({
        id = id,
        object = object,
        url = opts.url,
        width = width,
        height = height,
        dictName = dictName,
        txtName = txtName,
        factory = self,
    }, Page)
    self.live[id] = page
    return page
end

function Factory:releaseAll()
    local n = 0
    for _, page in pairs(self.live) do
        if page:destroy() then n = n + 1 end
    end
    return n
end

--- Point the page at another url.
function Page:setUrl(url)
    if not self.object then return false, 'this DUI was destroyed' end
    if type(url) ~= 'string' or url == '' then return false, 'a url is a non-empty string' end
    SetDuiUrl(self.object, url)
    self.url = url
    return true
end

--- Post a message to the page (window.addEventListener('message')). A table is
--- JSON-encoded; a string is sent as it is.
function Page:sendMessage(message)
    if not self.object then return false, 'this DUI was destroyed' end
    local payload = message
    if type(message) == 'table' then
        payload = json.encode(message)
    elseif type(message) ~= 'string' then
        return false, ('a message is a table or a string, got %s'):format(type(message))
    end
    SendDuiMessage(self.object, payload)
    return true
end

--- Whether the browser has finished starting.
function Page:isAvailable()
    return self.object ~= nil and IsDuiAvailable(self.object) == true
end

--- Free the browser. Answers whether it was open.
function Page:destroy()
    local object = self.object
    if not object then
        return false
    end
    self.object = nil
    self.factory.live[self.id] = nil
    DestroyDui(object)
    return true
end

return M
