-- Minimal stand-ins for the KOReader modules the plugin requires, plus a fake
-- TickTick server behind the https transport. Test-only.

local M = {}

M.shown = {}          -- widgets currently on screen, in order
M.net = { online = true, can_connect = true }
M.server = nil        -- set by tests, see M.newServer
M.requests = {}       -- log of {method, path}
M.settings_dir = nil  -- set by tests

---------------------------------------------------------------- JSON (tiny)
local json = {}
json.null = setmetatable({}, { __tostring = function() return "null" end })
local function esc(s)
    return (s:gsub('[%c"\\]', function(c)
        local map = { ['"'] = '\\"', ["\\"] = "\\\\", ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t" }
        return map[c] or string.format("\\u%04x", c:byte())
    end))
end
function json.encode(v)
    if v == json.null then return "null" end
    local t = type(v)
    if t == "string" then return '"' .. esc(v) .. '"' end
    if t == "number" or t == "boolean" then return tostring(v) end
    if t == "nil" then return "null" end
    if t == "table" then
        if #v > 0 or next(v) == nil then
            local out = {}
            for i, x in ipairs(v) do out[i] = json.encode(x) end
            return "[" .. table.concat(out, ",") .. "]"
        end
        local out = {}
        for k, x in pairs(v) do out[#out + 1] = json.encode(tostring(k)) .. ":" .. json.encode(x) end
        return "{" .. table.concat(out, ",") .. "}"
    end
    error("cannot encode " .. t)
end
function json.decode(s)
    local pos = 1
    local function ws() pos = s:find("%S", pos) or #s + 1 end
    local value
    local function str()
        local out = {}
        pos = pos + 1
        while true do
            local c = s:sub(pos, pos)
            if c == '"' then pos = pos + 1 break end
            if c == "\\" then
                local n = s:sub(pos + 1, pos + 1)
                local map = { n = "\n", r = "\r", t = "\t", ['"'] = '"', ["\\"] = "\\", ["/"] = "/" }
                if n == "u" then
                    out[#out + 1] = string.char(tonumber(s:sub(pos + 2, pos + 5), 16) % 256)
                    pos = pos + 6
                else
                    out[#out + 1] = map[n]
                    pos = pos + 2
                end
            else
                out[#out + 1] = c
                pos = pos + 1
            end
        end
        return table.concat(out)
    end
    function value()
        ws()
        local c = s:sub(pos, pos)
        if c == "{" then
            local o = {}
            pos = pos + 1
            ws()
            if s:sub(pos, pos) == "}" then pos = pos + 1 return o end
            while true do
                ws()
                local k = str()
                ws(); assert(s:sub(pos, pos) == ":", "expected :"); pos = pos + 1
                o[k] = value()
                ws()
                local d = s:sub(pos, pos); pos = pos + 1
                if d == "}" then return o end
                assert(d == ",", "expected ,")
            end
        elseif c == "[" then
            local a = {}
            pos = pos + 1
            ws()
            if s:sub(pos, pos) == "]" then pos = pos + 1 return a end
            while true do
                a[#a + 1] = value()
                ws()
                local d = s:sub(pos, pos); pos = pos + 1
                if d == "]" then return a end
                assert(d == ",", "expected ,")
            end
        elseif c == '"' then return str()
        elseif s:sub(pos, pos + 3) == "true" then pos = pos + 4 return true
        elseif s:sub(pos, pos + 4) == "false" then pos = pos + 5 return false
        elseif s:sub(pos, pos + 3) == "null" then pos = pos + 4 return json.null
        else
            local num = s:match("^-?%d+%.?%d*[eE]?[+-]?%d*", pos)
            assert(num and #num > 0, "bad json at " .. pos)
            pos = pos + #num
            return tonumber(num)
        end
    end
    local v = value()
    return v
end
M.json = json

--------------------------------------------------------- file-backed settings
local function serialize(v, indent)
    indent = indent or ""
    local t = type(v)
    if t == "string" then return string.format("%q", v) end
    if t == "number" or t == "boolean" then return tostring(v) end
    local out = {}
    for k, x in pairs(v) do
        local key = type(k) == "string" and string.format("[%q]", k) or "[" .. tostring(k) .. "]"
        out[#out + 1] = indent .. "  " .. key .. " = " .. serialize(x, indent .. "  ") .. ","
    end
    return "{\n" .. table.concat(out, "\n") .. "\n" .. indent .. "}"
end

local LuaSettings = {}
LuaSettings.__index = LuaSettings
function LuaSettings:open(path)
    local o = setmetatable({ file = path, data = {} }, self)
    local chunk = loadfile(path)
    if chunk then o.data = chunk() or {} end
    return o
end
function LuaSettings:readSetting(k) return self.data[k] end
function LuaSettings:saveSetting(k, v) self.data[k] = v return self end
function LuaSettings:delSetting(k) self.data[k] = nil return self end
function LuaSettings:flush()
    local f = assert(io.open(self.file, "w"))
    f:write("return " .. serialize(self.data) .. "\n")
    f:close()
end

------------------------------------------------------------------- widgets
local function widgetClass(kind)
    return { new = function(cls, o) o = o or {} o.kind = kind return o end }
end

local WidgetContainer = {}
WidgetContainer.__index = WidgetContainer
function WidgetContainer:extend(o)
    o = o or {}
    o.__index = o
    return setmetatable(o, { __index = self })
end
function WidgetContainer:new(o)
    o = setmetatable(o or {}, self)
    if o.init then o:init() end
    return o
end

local UIManager = {}
local Menu = {}
Menu.__index = Menu
function Menu:new(o)
    o = setmetatable(o or {}, self)
    o.kind = "menu"
    o.page = 1
    o.perpage = 14
    return o
end
function Menu:switchItemTable(title, items, position)
    if title then self.title = title end
    if items then self.item_table = items end
    self.position = position
    -- Like KOReader: an item number selects its page, no item number goes back to page 1.
    self.page = position and math.ceil(position / self.perpage) or 1
end
-- Simulate tapping/holding the n-th row exactly the way KOReader dispatches it.
function Menu:tap(n, pos) return self.onMenuSelect(self, self.item_table[n], pos) end
function Menu:hold(n) return self.onMenuHold(self, self.item_table[n]) end
function Menu:onLeftButtonTap() end -- KOReader: "to be overridden by the caller"
-- Same order as Menu:onCloseAllMenus in KOReader: remove the widget, then notify.
function Menu:close()
    UIManager:close(self)
    if self.close_callback then self.close_callback() end
end

function UIManager:show(w, refresh, region, x, y)
    w.shown_at = { x = x or 0, y = y or 0 }
    M.shown[#M.shown + 1] = w
end
function UIManager:close(w)
    for i = #M.shown, 1, -1 do
        if M.shown[i] == w then table.remove(M.shown, i) break end
    end
end
function UIManager:forceRePaint() end
M.scheduled = {} -- timers set with scheduleIn: { {seconds, action}, ... }
function UIManager:scheduleIn(seconds, action) M.scheduled[#M.scheduled + 1] = { seconds, action } end
function UIManager:unschedule(action)
    for i = #M.scheduled, 1, -1 do
        if M.scheduled[i][2] == action then table.remove(M.scheduled, i) end
    end
end
-- Let time pass: run every pending timer once.
function M.runTimers()
    local due = M.scheduled
    M.scheduled = {}
    for i, t in ipairs(due) do t[2]() end
end

function M.top() return M.shown[#M.shown] end
function M.find(kind)
    for i = #M.shown, 1, -1 do
        if M.shown[i].kind == kind then return M.shown[i] end
    end
end
-- Index of the first row whose text starts with `prefix`.
function M.rowIndex(menu, prefix)
    for i, it in ipairs(menu.item_table) do
        if it.text and it.text:sub(1, #prefix) == prefix then return i end
    end
end
function M.clearInfos()
    for i = #M.shown, 1, -1 do
        if M.shown[i].kind == "info" then table.remove(M.shown, i) end
    end
end

------------------------------------------------------------- fake server
-- tasks_by_project: id -> array of raw API tasks
function M.newServer(opts)
    local s = {
        token = opts.token or "good-token",
        projects = opts.projects,
        tasks = opts.tasks,
        completed = {},
        mode = "ok", -- "ok" | "down" | "forbidden" | "boom"
        not_found = {}, -- task ids that 404 on complete
    }
    return s
end

local function respond(sink, code, body)
    if body then sink(body) end
    return 1, code, { ["content-type"] = "application/json" }, "HTTP/1.1 " .. code
end

local function handle(req)
    local s = M.server
    local path = req.url:gsub("^https?://[^/]+/open/v1", "")
    M.requests[#M.requests + 1] = { method = req.method, path = path, headers = req.headers }
    if s.mode == "down" then return nil, "connection refused" end
    if req.headers["Authorization"] ~= "Bearer " .. s.token or s.mode == "forbidden" then
        return respond(req.sink, 401, "")
    end
    if s.mode == "boom" then return respond(req.sink, 500, "oops") end
    local function out(code, tbl) return respond(req.sink, code, tbl ~= nil and json.encode(tbl) or "") end
    if req.method == "GET" and path == "/project" then
        return out(200, s.projects)
    end
    local pid = path:match("^/project/([^/]+)/data$")
    if req.method == "GET" and pid then
        if not s.tasks[pid] then return out(404) end
        local tasks = {}
        for i, t in ipairs(s.tasks[pid]) do
            if t.status == 0 and not s.completed[t.id] then tasks[#tasks + 1] = t end
        end
        return out(200, { project = { id = pid }, tasks = tasks, columns = {} })
    end
    local gpid, gtid = path:match("^/project/([^/]+)/task/([^/]+)$")
    if req.method == "GET" and gpid then
        for i, t in ipairs(s.tasks[gpid] or {}) do
            if t.id == gtid then return out(200, t) end
        end
        return out(404)
    end
    if req.method == "POST" and path == "/task" then
        if s.fail_creates then return respond(req.sink, 500, "create failed") end
        local body = req.source and req.source() or ""
        assert(req.headers["Content-Length"] == tostring(#body), "create must send an exact Content-Length")
        local t = json.decode(body)
        assert(t.projectId and t.title, "create needs projectId and title")
        s.next_id = (s.next_id or 0) + 1
        t.id, t.status, t.sortOrder = "new" .. s.next_id, 0, 0
        t.priority = t.priority or 0
        s.tasks[t.projectId] = s.tasks[t.projectId] or {}
        table.insert(s.tasks[t.projectId], t)
        s.created = s.created or {}
        s.created[#s.created + 1] = t
        return out(200, t)
    end
    local dpid, dtid = path:match("^/project/([^/]+)/task/([^/]+)$")
    if req.method == "DELETE" and dpid then
        for i, t in ipairs(s.tasks[dpid] or {}) do
            if t.id == dtid then
                table.remove(s.tasks[dpid], i)
                s.deleted = s.deleted or {}
                s.deleted[dtid] = dpid
                return out(200)
            end
        end
        return out(404)
    end
    if req.method == "POST" and path == "/task/move" then
        if s.fail_moves then return respond(req.sink, 500, "move failed") end
        local body = req.source and req.source() or ""
        assert(req.headers["Content-Length"] == tostring(#body), "move must send an exact Content-Length")
        local moves = json.decode(body)
        assert(type(moves) == "table" and moves[1], "move body must be an array")
        local results = {}
        for i, m in ipairs(moves) do
            assert(m.fromProjectId and m.toProjectId and m.taskId, "move needs fromProjectId, toProjectId, taskId")
            local from = s.tasks[m.fromProjectId] or {}
            local found
            for j, t in ipairs(from) do
                if t.id == m.taskId then found = j break end
            end
            if not found then return out(404) end
            local t = table.remove(from, found)
            t.projectId = m.toProjectId
            s.tasks[m.toProjectId] = s.tasks[m.toProjectId] or {}
            table.insert(s.tasks[m.toProjectId], t)
            s.moves = s.moves or {}
            s.moves[#s.moves + 1] = m
            results[#results + 1] = { id = m.taskId, etag = "e" .. i }
        end
        return out(200, results)
    end
    local utid = path:match("^/task/([^/]+)$")
    if req.method == "POST" and utid then
        if s.fail_updates then return respond(req.sink, 500, "update failed") end
        local body = req.source and req.source() or ""
        assert(req.headers["Content-Length"] == tostring(#body), "update must send an exact Content-Length")
        local fields = json.decode(body)
        assert(fields.id == utid and fields.projectId, "update body needs id and projectId")
        for i, it in ipairs(type(fields.items) == "table" and fields.items or {}) do
            if not it.id then -- like TickTick: new checklist items get ids
                s.next_item = (s.next_item or 0) + 1
                it.id = "item" .. s.next_item
            end
        end
        for i, t in ipairs(s.tasks[fields.projectId] or {}) do
            if t.id == utid then
                for k, v in pairs(fields) do t[k] = v end
                s.updates = s.updates or {}
                s.updates[#s.updates + 1] = fields
                return out(200, t)
            end
        end
        return out(404)
    end
    local cpid, tid = path:match("^/project/([^/]+)/task/([^/]+)/complete$")
    if req.method == "POST" and cpid then
        assert(req.headers["Content-Length"] == "0", "complete must send Content-Length: 0")
        if s.not_found[tid] then return out(404) end
        for i, t in ipairs(s.tasks[cpid] or {}) do
            if t.id == tid and type(t.repeatFlag) == "string" then
                -- like TickTick: a repeating task stays open and moves to its next date
                -- (the fake only knows daily repeats)
                s.rolled = s.rolled or {}
                s.rolled[#s.rolled + 1] = tid
                local y, mo, d, rest = t.dueDate:match("^(%d+)-(%d+)-(%d+)(T.*)$")
                local next_day = os.time({ year = tonumber(y), month = tonumber(mo), day = tonumber(d) + 1, hour = 12 })
                t.dueDate = os.date("%Y-%m-%d", next_day) .. rest
                t.startDate = t.dueDate
                return out(200)
            end
        end
        s.completed[tid] = cpid
        s.completed_order = s.completed_order or {}
        s.completed_order[#s.completed_order + 1] = tid
        return out(200)
    end
    return out(404)
end

---------------------------------------------------------------- preloads
function M.install()
    local P = package.preload
    local gettext = setmetatable({}, { __call = function(_, s) return s end })
    gettext.ngettext = function(a, b, n) return n == 1 and a or b end
    P["gettext"] = function() return gettext end
    P["device"] = function()
        return { screen = { getWidth = function() return 1000 end, getHeight = function() return 1400 end } }
    end
    P["datastorage"] = function() return { getSettingsDir = function() return M.settings_dir end } end
    P["dispatcher"] = function() return { registerAction = function() end } end
    P["ui/widget/confirmbox"] = function() return widgetClass("confirm") end
    P["ui/widget/buttondialog"] = function() return widgetClass("buttons") end
    P["ui/widget/datetimewidget"] = function()
        local C = widgetClass("datetime")
        local base = C.new
        C.new = function(cls, o)
            o = base(cls, o)
            o.onClose = function(self) UIManager:close(self) end
            -- the OK button, as KOReader does it: callback(self, self) with the picked values, then close
            o.pick = function(self, y, m, d)
                self.year, self.month, self.day = y, m, d
                self:callback(self)
                self:onClose()
            end
            return o
        end
        return C
    end
    P["ui/widget/infomessage"] = function() return widgetClass("info") end
    P["ui/widget/inputdialog"] = function()
        local C = widgetClass("input")
        local base = C.new
        C.new = function(cls, o)
            o = base(cls, o)
            o.getInputText = function(self) return self.input end
            o.onShowKeyboard = function() end
            return o
        end
        return C
    end
    P["json"] = function() return json end
    P["luasettings"] = function() return LuaSettings end
    P["ui/widget/menu"] = function() return Menu end
    P["ui/network/manager"] = function()
        return {
            isOnline = function() return M.net.online end,
            runWhenOnline = function(_, cb)
                if M.net.online or M.net.can_connect then
                    M.net.online = true
                    cb()
                end
            end,
        }
    end
    P["ui/uimanager"] = function() return UIManager end
    P["ui/widget/container/widgetcontainer"] = function() return WidgetContainer end
    P["ffi/util"] = function()
        return {
            template = function(str, ...)
                local args = { ... }
                return (str:gsub("%%(%d)", function(n) return tostring(args[tonumber(n)]) end))
            end,
        }
    end
    P["logger"] = function()
        local l = {}
        for _, n in ipairs({ "dbg", "info", "warn", "err" }) do l[n] = function() end end
        return l
    end
    P["socket.http"] = function() return { request = function() error("plain http used unexpectedly") end } end
    P["ssl.https"] = function() return { request = handle } end
    P["ltn12"] = function()
        return {
            sink = { table = function(t) return function(chunk) if chunk then t[#t + 1] = chunk end return 1 end end },
            source = { string = function(s) return function() local x = s s = nil return x end end },
        }
    end
    P["socket"] = function() return { skip = function(n, ...) return select(n + 1, ...) end } end
    P["socketutil"] = function()
        return { LARGE_BLOCK_TIMEOUT = 10, LARGE_TOTAL_TIMEOUT = 30,
                 set_timeout = function() end, reset_timeout = function() end }
    end
end

return M
