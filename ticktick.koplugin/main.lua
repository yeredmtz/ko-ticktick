--[[--
TickTick for KOReader: browse your tasks, open them, edit titles and notes,
and mark them complete.

* Tasks are cached on the device, so screens open instantly and work offline.
  Nothing syncs on its own: tap "Sync now" (or use the gesture action).
* Completions and edits made offline are queued and uploaded on the next sync.
* The access token lives on the device (koreader/settings/ticktick.lua).

@module koplugin.ticktick
]]

local ButtonDialog = require("ui/widget/buttondialog")
local ConfirmBox = require("ui/widget/confirmbox")
local DataStorage = require("datastorage")
local Device = require("device")
local DateTimeWidget = require("ui/widget/datetimewidget")
local Dispatcher = require("dispatcher")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local JSON = require("json")
local LuaSettings = require("luasettings")
local Menu = require("ui/widget/menu")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local ffiUtil = require("ffi/util")
local logger = require("logger")
local _ = require("gettext")
local T = ffiUtil.template

local Client = require("ticktick_client")
local Model = require("ticktick_model")

local Screen = Device.screen
local DRAWER_WIDTH = 0.8 -- share of the screen width the sidebar covers
local CHECKBOX_ZONE = 0.15 -- a tap in this share of a row, from the left, hits its checkbox
local UNDO_SECONDS = 5 -- how long "Undo" is offered after ticking a checkbox
local INDENT = "      " -- lists inside a folder are drawn indented under it

-- Icons from the Font Awesome set in KOReader's nerdfonts/symbols.ttf (a fallback
-- font, so they draw on any device). Written as UTF-8 bytes to stay Lua 5.1 compatible.
local ICON = {
    box = "\239\130\150",      -- U+F096 square-o
    box_done = "\239\129\134", -- U+F046 check-square-o
    calendar = "\239\129\179", -- U+F073 calendar
    flag = "\239\128\164",     -- U+F024 flag
    list = "\239\128\186",     -- U+F03A list
    notes = "\239\131\182",    -- U+F0F6 file-text-o
    check = "\239\128\140",    -- U+F00C check
    plus = "\239\129\167",     -- U+F067 plus
    trash = "\239\135\184",    -- U+F1F8 trash
    folder = "\239\129\187",   -- U+F07B folder
    folder_open = "\239\129\188", -- U+F07C folder-open
    search = "\239\128\130",   -- U+F002 search
    clock = "\239\128\151",    -- U+F017 clock-o
    subtask = "\239\133\137",  -- U+F149 level-down
    up = "\239\133\136",       -- U+F148 level-up
    inbox = "\239\128\156",    -- U+F01C inbox
    today = "\239\137\180",    -- U+F274 calendar-check-o
    tomorrow = "\239\137\177", -- U+F271 calendar-plus-o
    week = "\239\129\179",     -- U+F073 calendar
    all = "\239\130\174",      -- U+F0AE tasks
    sync = "\239\128\161",     -- U+F021 refresh
    settings = "\239\128\147", -- U+F013 cog
}

--- Build the HTTP transport used by the client (see ticktick_client.lua for the contract).
-- KOReader's HTTPS does not verify server certificates unless given a CA bundle;
-- set `ca_file` in ticktick.lua to turn verification on.
local function makeTransport(ca_file)
    return function(method, url, headers, body)
        local http = require("socket.http")
        local https = require("ssl.https")
        local ltn12 = require("ltn12")
        local socket = require("socket")
        local socketutil = require("socketutil")

        local sink = {}
        local request = {
            url = url,
            method = method,
            headers = headers,
            sink = ltn12.sink.table(sink),
        }
        if body then
            request.source = ltn12.source.string(body)
        end
        local requester = url:match("^https") and https or http
        if ca_file and url:match("^https") then
            request.verify = "peer"
            request.cafile = ca_file
        end
        socketutil:set_timeout(socketutil.LARGE_BLOCK_TIMEOUT, socketutil.LARGE_TOTAL_TIMEOUT)
        local ok, code, resp_headers, status = pcall(function()
            return socket.skip(1, requester.request(request))
        end)
        socketutil:reset_timeout()
        if not ok then
            -- pcall failed: `code` holds the error message
            return nil, tostring(code)
        end
        if resp_headers == nil then
            return nil, tostring(status or code)
        end
        return code, table.concat(sink)
    end
end

local TickTick = WidgetContainer:extend{
    name = "ticktick",
    is_doc_only = false,
}

-- ---------------------------------------------------------------------------
-- Small helpers
-- ---------------------------------------------------------------------------

--- Replace a menu's rows, staying on the page the reader was on.
local function reload(menu, title, items)
    local perpage = menu.perpage or 1
    local position = ((menu.page or 1) - 1) * perpage + 1
    position = math.max(1, math.min(position, #items))
    menu:switchItemTable(title, items, position)
end

local function formatOffset(minutes)
    local sign = minutes < 0 and "-" or "+"
    local m = math.abs(minutes)
    return string.format("UTC%s%d:%02d", sign, math.floor(m / 60), m % 60)
end

local function fullScreenMenu(fields)
    fields.covers_fullscreen = true
    fields.is_borderless = true
    fields.is_popout = false
    fields.title_bar_fm_style = true
    return Menu:new(fields)
end

-- ---------------------------------------------------------------------------
-- Setup & settings
-- ---------------------------------------------------------------------------

function TickTick:init()
    -- Config: written by tools/get_token.py (token, base_url, offset, inbox id).
    self.settings = LuaSettings:open(DataStorage:getSettingsDir() .. "/ticktick.lua")
    -- State: task cache, queued changes, list toggles. Safe to delete.
    self.state = LuaSettings:open(DataStorage:getSettingsDir() .. "/ticktick_state.lua")
    self:repairCachedText()
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
end

--- Caches written before the emoji fix hold broken text (see Model.fixSurrogates).
-- Repaired in memory; the next save writes it back.
function TickTick:repairCachedText()
    for i, key in ipairs({ "tasks", "projects", "pending" }) do
        local v = self.state:readSetting(key)
        if type(v) == "table" then Model.fixTextDeep(v) end
    end
end

function TickTick:onDispatcherRegisterActions()
    Dispatcher:registerAction("ticktick_home", {
        category = "none", event = "ShowTickTickHome",
        title = _("TickTick: open"), general = true,
    })
    Dispatcher:registerAction("ticktick_today", {
        category = "none", event = "ShowTickTickToday",
        title = _("TickTick: today's tasks"), general = true,
    })
    Dispatcher:registerAction("ticktick_sync", {
        category = "none", event = "SyncTickTick",
        title = _("TickTick: sync now"), general = true,
    })
end

function TickTick:onShowTickTickHome()
    self:showHome()
    return true
end

function TickTick:onShowTickTickToday()
    self:showTasks({ kind = "today" })
    return true
end

function TickTick:onSyncTickTick()
    self:sync(function(ok)
        if ok then
            UIManager:show(InfoMessage:new{ text = _("TickTick synced."), timeout = 2 })
        end
    end)
    return true
end

function TickTick:getClient()
    local token = self.settings:readSetting("access_token")
    if type(token) ~= "string" or token == "" then
        return nil
    end
    return Client:new{
        base_url = self.settings:readSetting("base_url"),
        token = token,
        transport = makeTransport(self.settings:readSetting("ca_file")),
        json = JSON,
    }
end

function TickTick:offsetMinutes()
    local o = self.settings:readSetting("utc_offset_minutes")
    if type(o) == "number" then
        return o
    end
    return Model.deviceOffsetMinutes()
end

function TickTick:excludedProjects()
    return self.state:readSetting("excluded_projects") or {}
end

function TickTick:extraProjectIds()
    local ids = self.settings:readSetting("extra_project_ids")
    if type(ids) == "string" then
        local list = {}
        for id in ids:gmatch("[^,%s]+") do list[#list + 1] = id end
        return list
    end
    return type(ids) == "table" and ids or {}
end

--- The first extra list id is treated as the Inbox.
function TickTick:inboxId()
    return self:extraProjectIds()[1]
end

function TickTick:cachedTasks()
    return self.state:readSetting("tasks")
end

function TickTick:findCachedTask(task_id)
    for i, t in ipairs(self:cachedTasks() or {}) do
        if t.id == task_id then return t end
    end
end

-- ---------------------------------------------------------------------------
-- Queue of changes made while offline (completions and edits)
-- Each entry: { op = "complete" | "update" | "move" | "create" | "delete",
--               project_id, task_id, title, fields, to_project_id }
-- (entries without `op` come from an older version and are completions)
-- A task added on the device has a temporary id ("local:...") until its "create" uploads;
-- then the real id replaces it everywhere.
-- ---------------------------------------------------------------------------

function TickTick:pendingList()
    return self.state:readSetting("pending") or {}
end

function TickTick:setPending(list)
    self.state:saveSetting("pending", list)
    self.state:flush()
end

local function isCompletion(p)
    return p.op == nil or p.op == "complete"
end

--- Changes after which the task is gone from every list.
local function removesTask(p)
    return isCompletion(p) or p.op == "delete"
end

local function isLocalId(id)
    return type(id) == "string" and id:sub(1, 6) == "local:"
end

local local_counter = 0
local function newLocalId()
    local_counter = local_counter + 1
    return "local:" .. os.time() .. ":" .. local_counter
end

--- Ids of tasks completed or deleted but not uploaded yet (they are hidden from lists).
function TickTick:pendingCompleteIds()
    local set = {}
    for i, p in ipairs(self:pendingList()) do
        if removesTask(p) then set[p.task_id] = true end
    end
    return set
end

--- The queued "create" of a task added on this device, if it has not uploaded yet.
function TickTick:pendingCreate(task_id)
    if not isLocalId(task_id) then return nil end
    for i, p in ipairs(self:pendingList()) do
        if p.op == "create" and p.task_id == task_id then return p end
    end
end

function TickTick:pendingCount()
    return #self:pendingList()
end

--- Is an edit or move of this task waiting to upload? (Then TickTick's copy is older than ours.)
function TickTick:hasPendingUpdate(task_id)
    for i, p in ipairs(self:pendingList()) do
        if (p.op == "update" or p.op == "move" or p.op == "create") and p.task_id == task_id then return true end
    end
    return false
end

--- Queue a move. Several moves of one task merge into one; moving it back home cancels it.
-- Changes queued after the move upload after it, so they are pointed at the new list.
function TickTick:queueMove(task, to_project_id)
    local pending, kept, existing = self:pendingList(), {}, nil
    local create
    for i, p in ipairs(pending) do
        if p.op == "create" and p.task_id == task.id then create = p end
    end
    if create then -- not uploaded yet: just create it in the other list
        for i, p in ipairs(pending) do
            if p.task_id == task.id then p.project_id = to_project_id end
        end
        self:setPending(pending)
        return
    end
    for i, p in ipairs(pending) do
        if p.op == "move" and p.task_id == task.id then existing = p end
        if existing and p ~= existing and p.task_id == task.id then p.project_id = to_project_id end
    end
    if existing then
        existing.to_project_id = to_project_id
        existing.title = task.title
        if existing.project_id == to_project_id then -- back where it started
            for i, p in ipairs(pending) do
                if p ~= existing then kept[#kept + 1] = p end
            end
            pending = kept
        end
    else
        pending[#pending + 1] = {
            op = "move", project_id = task.project_id, task_id = task.id,
            title = task.title, to_project_id = to_project_id,
        }
    end
    self:setPending(pending)
end

--- Queue an edit. Several edits to one task merge into a single queued update (latest wins).
function TickTick:queueUpdate(task, fields)
    local pending = self:pendingList()
    local existing
    for i, p in ipairs(pending) do
        -- An edit to a task that is not uploaded yet goes into its "create".
        if (p.op == "update" or p.op == "create") and p.task_id == task.id then existing = p break end
    end
    if existing then
        for k, v in pairs(fields) do existing.fields[k] = v end
        existing.title = task.title
    else
        local copy = {}
        for k, v in pairs(fields) do copy[k] = v end
        pending[#pending + 1] = {
            op = "update", project_id = task.project_id, task_id = task.id,
            title = task.title, fields = copy,
        }
    end
    self:setPending(pending)
end

--- Re-apply queued edits to freshly downloaded tasks, so an edit that has not
-- uploaded yet does not vanish from the screen after a sync.
function TickTick:applyPendingUpdates(tasks)
    local by_id = {}
    for i, t in ipairs(tasks) do by_id[t.id] = t end
    for i, p in ipairs(self:pendingList()) do
        local t = by_id[p.task_id]
        if t and p.op == "update" then
            Model.applyFields(t, p.fields or {})
        elseif t and p.op == "move" then
            t.project_id, t.project = p.to_project_id, self:projectName(p.to_project_id)
        end
    end
end

function TickTick:dropCachedTask(task_id)
    local tasks = self:cachedTasks()
    if not tasks then return end
    local kept = {}
    for i, t in ipairs(tasks) do
        if t.id ~= task_id then kept[#kept + 1] = t end
    end
    self.state:saveSetting("tasks", kept)
end

--- A task added on this device was created in TickTick: give it the real id and
-- TickTick's copy of its fields. Changed in place, so open screens keep it.
function TickTick:adoptCreatedTask(local_id, created)
    local t = self:findCachedTask(local_id)
    if not t then return end
    local was_note = t.is_note
    for k in pairs(t) do t[k] = nil end
    for k, v in pairs(created) do t[k] = v end
    t.project = self:projectName(t.project_id) or t.project
    t.is_note = (was_note or self:projectKind(t.project_id) == "NOTE" or t.kind == "NOTE") or nil
    for i, other in ipairs(self:cachedTasks() or {}) do -- its subtasks now name the real id
        if other.parent_id == local_id then other.parent_id = created.id end
    end
end

--- Upload queued changes. Stops at the first network/auth failure; other
-- per-item failures leave that item queued and carry on with the rest.
-- @return boolean all uploaded, string|nil error kind, any detail
function TickTick:flushPending(client)
    local pending = self:pendingList()
    if #pending == 0 then
        return true
    end
    local remaining = {}
    local stop_kind, stop_detail
    local soft_kind, soft_detail
    for idx, p in ipairs(pending) do
        if stop_kind or (isLocalId(p.task_id) and p.op ~= "create")
                or (p.op == "create" and isLocalId(p.fields and p.fields.parentId)) then
            -- (a change to a task whose create has not uploaded waits for it)
            remaining[#remaining + 1] = p
        else
            local ok, kind, detail
            if p.op == "create" then
                local created
                created, kind, detail = client:createTask(p.project_id, p.fields or {})
                if created then
                    ok = true
                    self:adoptCreatedTask(p.task_id, created)
                    for j, q in ipairs(pending) do
                        if q ~= p and q.task_id == p.task_id then q.task_id = created.id end
                        if q.fields and q.fields.parentId == p.task_id then q.fields.parentId = created.id end
                    end
                end
            elseif p.op == "delete" then
                ok, kind, detail = client:deleteTask(p.project_id, p.task_id)
            elseif p.op == "update" then
                ok, kind, detail = client:updateTask(p.project_id, p.task_id, p.fields or {})
            elseif p.op == "move" then
                ok, kind, detail = client:moveTask(p.project_id, p.to_project_id, p.task_id)
            else
                ok, kind, detail = client:completeTask(p.project_id, p.task_id)
            end
            if ok then
                if removesTask(p) then self:dropCachedTask(p.task_id) end
                if p.op == "update" and p.fields and p.fields.items and type(ok) == "table" and type(ok.items) == "table" then
                    -- TickTick's reply carries ids for checklist items added on the device.
                    local t = self:findCachedTask(p.task_id)
                    if t then Model.applyFields(t, { items = ok.items }) end
                end
                if p.op == "move" then
                    -- Other queued changes to this task must now name its new list.
                    for j, q in ipairs(pending) do
                        if q ~= p and q.task_id == p.task_id then q.project_id = p.to_project_id end
                    end
                end
            elseif kind == "http" and detail == 404 then
                -- Deleted or already completed elsewhere: nothing left to do.
                logger.warn("TickTick: dropping queued change, task not found:", p.task_id)
                self:dropCachedTask(p.task_id)
            elseif kind == "network" or kind == "auth" then
                stop_kind, stop_detail = kind, detail
                remaining[#remaining + 1] = p
            else
                logger.warn("TickTick: queued change failed", kind, detail)
                soft_kind, soft_detail = kind, detail
                remaining[#remaining + 1] = p
            end
        end
    end
    self:setPending(remaining)
    if #remaining == 0 then
        return true
    end
    return false, stop_kind or soft_kind, stop_detail or soft_detail
end

-- ---------------------------------------------------------------------------
-- Sync
-- ---------------------------------------------------------------------------

function TickTick:describeError(kind, detail)
    if kind == "auth" then
        return _("TickTick rejected the access token. Create a new one with get_token.py and set it under Settings > Access token.")
    elseif kind == "network" then
        return T(_("Could not reach TickTick. Check Wi-Fi, and that the device clock is correct.\n\n%1"), tostring(detail or ""))
    elseif kind == "http" then
        return T(_("TickTick returned HTTP %1."), tostring(detail))
    end
    return _("Unexpected response from TickTick.")
end

--- Upload the queue, then download all tasks. Calls on_done(true|false) when finished.
function TickTick:sync(on_done)
    local client = self:getClient()
    if not client then
        self:promptForToken()
        return
    end
    NetworkMgr:runWhenOnline(function()
        local info = InfoMessage:new{ text = _("Syncing TickTick…") }
        UIManager:show(info)
        UIManager:forceRePaint()

        local err_kind, err_detail
        local flushed, fk, fd = self:flushPending(client)
        if not flushed then
            err_kind, err_detail = fk, fd
        end

        local tasks, projects, failed
        if not err_kind or err_kind == "http" then
            tasks, projects, failed = client:fetchAll(self:excludedProjects(), self:extraProjectIds())
            if not tasks then
                err_kind, err_detail = projects, failed -- (nil, kind, detail)
            end
        end

        UIManager:close(info)

        if tasks then
            -- Tasks added here whose upload failed are not on TickTick yet: keep them.
            for i, p in ipairs(self:pendingList()) do
                local t = p.op == "create" and self:findCachedTask(p.task_id)
                if t then tasks[#tasks + 1] = t end
            end
            self:applyPendingUpdates(tasks)
            self.state:saveSetting("tasks", tasks)
            self.state:saveSetting("projects", projects)
            self.state:saveSetting("synced_at", os.time())
            self.state:flush()
            self:refreshAll()
            if failed and failed > 0 then
                UIManager:show(InfoMessage:new{
                    text = T(_("%1 project(s) could not be loaded."), failed),
                    timeout = 3,
                })
            end
            if on_done then on_done(true) end
        else
            UIManager:show(InfoMessage:new{ text = self:describeError(err_kind, err_detail) })
            if on_done then on_done(false) end
        end
    end)
end

--- Open a screen from the cache. Never syncs by itself: the Sync row does that.
function TickTick:ensureData(open)
    if not self:getClient() then
        self:promptForToken(function() self:ensureData(open) end)
        return
    end
    open()
end

function TickTick:syncRowText()
    local synced = self.state:readSetting("synced_at")
    local when = synced and os.date("%b %d %H:%M", synced) or _("never")
    local waiting = self:pendingCount()
    if waiting > 0 then
        return T(_("Sync now (last: %1, %2 waiting to upload)"), when, waiting)
    end
    return T(_("Sync now (last: %1)"), when)
end

--- Rows shown before anything has been downloaded.
function TickTick:noDataRow()
    if self:cachedTasks() == nil then
        return { text = _("Nothing downloaded yet. Tap Sync now."), select_enabled = false }
    end
end

--- Redraw every open TickTick screen from the cache.
function TickTick:refreshAll()
    if self.detail_menu and self.detail_task then
        local fresh = self:findCachedTask(self.detail_task.id)
        if fresh then
            self.detail_task = fresh
            self:refreshDetail()
        else
            self:closeDetail()
        end
    end
    self:refreshList()
    self:refreshDrawer()
end

-- ---------------------------------------------------------------------------
-- Which list is showing: mode = {kind = "today"|"tomorrow"|"week"|"all"|"project", project_id?}
-- ---------------------------------------------------------------------------

local SMART_TITLES = {
    today = _("Today"), tomorrow = _("Tomorrow"), week = _("Next 7 days"), all = _("All tasks"),
}

--- "NOTE" for a note list, else nil.
function TickTick:projectKind(project_id)
    for i, p in ipairs(self.state:readSetting("projects") or {}) do
        if p.id == project_id then return p.kind end
    end
end

--- A list's name as TickTick has it ("Inbox" for the Inbox), or nil if unknown.
function TickTick:projectName(project_id)
    if project_id == self:inboxId() then return "Inbox" end
    for i, p in ipairs(self.state:readSetting("projects") or {}) do
        if p.id == project_id then return p.name end
    end
end

--- The name to show for a list, looked up fresh so a rename in TickTick shows after a sync.
function TickTick:modeTitle(mode)
    if mode.kind == "search" then
        return T(_("Search: %1"), mode.query or "")
    end
    if mode.kind ~= "project" then
        return SMART_TITLES[mode.kind] or mode.kind
    end
    if mode.project_id == self:inboxId() then
        return _("Inbox")
    end
    for i, p in ipairs(self.state:readSetting("projects") or {}) do
        if p.id == mode.project_id then return Model.displayName(p.name) end
    end
    return Model.displayName(mode.title or _("List"))
end

local function sameMode(a, b)
    return a and b and a.kind == b.kind and a.project_id == b.project_id
end

--- The list to open with: the last one viewed, else Today.
function TickTick:startMode()
    local m = self.state:readSetting("last_mode")
    if type(m) == "table" and m.kind then
        return { kind = m.kind, project_id = m.project_id }
    end
    return { kind = "today" }
end

-- ---------------------------------------------------------------------------
-- Sidebar (drawer): Inbox, smart lists, your lists. Opened with the menu
-- button at the top left of a task list, like the phone app.
-- ---------------------------------------------------------------------------

--- A folder's name. TickTick's API does not share folder names, so they are set on the device.
function TickTick:folderName(group_id)
    local names = self.state:readSetting("folder_names") or {}
    return names[group_id] or _("Folder")
end

function TickTick:renameFolder(group_id)
    self:showInput{
        title = _("Folder name"),
        input = (self.state:readSetting("folder_names") or {})[group_id] or "",
        hint = _("e.g. Work"),
        description = _("TickTick does not share folder names with other apps, so name it here. Leave blank for \"Folder\"."),
        on_save = function(value)
            value = (value or ""):gsub("^%s+", ""):gsub("%s+$", "")
            local names = self.state:readSetting("folder_names") or {}
            names[group_id] = value ~= "" and value or nil
            self.state:saveSetting("folder_names", names)
            self.state:flush()
            self:refreshAll()
        end,
    }
end

--- Your lists in TickTick's order, folders as headers with their lists indented.
-- `row(project, nested)` builds a list row; folders are skipped when all their lists are.
-- @return array of rows; folder headers are {folder = group_id, folder_lists = {...}}
function TickTick:listRows(row, opts)
    opts = opts or {}
    local collapsed = opts.collapsible and (self.state:readSetting("collapsed_folders") or {}) or {}
    local out = {}
    for i, e in ipairs(Model.orderProjects(self.state:readSetting("projects"))) do
        if e.list then
            local r = row(e.list, false)
            if r then out[#out + 1] = r end
        else
            local rows = {}
            for j, p in ipairs(e.lists) do
                local r = row(p, true)
                if r then rows[#rows + 1] = r end
            end
            if #rows > 0 then
                local closed = collapsed[e.folder]
                out[#out + 1] = {
                    text = (closed and ICON.folder or ICON.folder_open) .. "  " .. self:folderName(e.folder),
                    folder = e.folder, folder_rows = rows,
                    select_enabled = opts.collapsible or false,
                }
                if not closed then
                    for j, r in ipairs(rows) do out[#out + 1] = r end
                end
            end
        end
    end
    return out
end

function TickTick:drawerItems()
    local tasks = self:cachedTasks()
    local now, offset = os.time(), self:offsetMinutes()
    local skip, excluded = self:pendingCompleteIds(), self:excludedProjects()
    local current = self.mode
    local inbox = self:inboxId()
    local function icon(mode)
        if mode.kind ~= "project" then return ICON[mode.kind] end
        if mode.project_id == inbox then return ICON.inbox end
        return self:projectKind(mode.project_id) == "NOTE" and ICON.notes or ICON.list
    end
    local function row(mode, nested)
        local n = #Model.visibleTasks(tasks, mode, now, offset, skip, excluded)
        return {
            text = (nested and INDENT or "") .. icon(mode) .. "  " .. self:modeTitle(mode),
            mandatory = tostring(n), count = n,
            bold = sameMode(mode, current) or nil,
            mode = mode,
        }
    end

    local items = { { text = ICON.sync .. "  " .. self:syncRowText(), sync_row = true } }
    items[#items + 1] = { text = ICON.search .. "  " .. _("Search"), action = function() self:promptSearch() end }
    items[#items + 1] = self:noDataRow()
    if inbox then
        items[#items + 1] = row({ kind = "project", project_id = inbox })
    else
        items[#items + 1] = {
            text = ICON.inbox .. "  " .. _("Inbox: not set up (tap to add its list ID)"),
            action = function() self:promptForExtraIds(function() self:refreshAll() end) end,
        }
    end
    for i, kind in ipairs({ "today", "tomorrow", "week", "all" }) do
        items[#items + 1] = row({ kind = kind })
    end

    local lists = self:listRows(function(p, nested)
        if excluded[p.id] then return nil end
        return row({ kind = "project", project_id = p.id }, nested)
    end, { collapsible = true })
    if #lists > 0 then
        items[#items + 1] = { text = _("Lists"), dim = true, select_enabled = false }
        for i, r in ipairs(lists) do
            if r.folder then -- a folder shows the total of its lists
                local total = 0
                for j, fr in ipairs(r.folder_rows) do total = total + fr.count end
                r.mandatory = tostring(total)
            end
            items[#items + 1] = r
        end
    end
    items[#items + 1] = { text = ICON.settings .. "  " .. _("Settings"), action = function() self:openSettings() end }
    return items
end

--- Tap a folder: fold or unfold it (remembered).
function TickTick:toggleFolder(group_id)
    local collapsed = self.state:readSetting("collapsed_folders") or {}
    collapsed[group_id] = not collapsed[group_id] or nil
    self.state:saveSetting("collapsed_folders", collapsed)
    self.state:flush()
    self:refreshDrawer()
end

function TickTick:openDrawer()
    if self.drawer then
        self:refreshDrawer()
        return
    end
    local plugin = self
    self.drawer = Menu:new{
        title = _("TickTick"),
        item_table = self:drawerItems(),
        width = math.floor(Screen:getWidth() * DRAWER_WIDTH),
        height = Screen:getHeight(),
        is_popout = true, -- a tap outside the panel closes it
        is_borderless = false,
        covers_fullscreen = false,
        onMenuSelect = function(menu_self, item)
            if item.sync_row then
                plugin:sync()
            elseif item.mode then
                plugin:closeDrawer()
                plugin:openList(item.mode)
            elseif item.folder then
                plugin:toggleFolder(item.folder)
            elseif item.action then
                item.action()
            end
            return true
        end,
        onMenuHold = function(menu_self, item)
            if item.folder then plugin:renameFolder(item.folder) end
            return true
        end,
        close_callback = function()
            plugin.drawer = nil
        end,
    }
    UIManager:show(self.drawer, "ui", nil, 0, 0) -- pinned to the left edge
end

function TickTick:refreshDrawer()
    if self.drawer then
        reload(self.drawer, _("TickTick"), self:drawerItems())
    end
end

function TickTick:closeDrawer()
    local drawer = self.drawer
    self.drawer = nil
    if drawer then UIManager:close(drawer) end
end

-- ---------------------------------------------------------------------------
-- Task list screen (the main screen)
-- ---------------------------------------------------------------------------

function TickTick:showHome()
    self:ensureData(function() self:openList(self.mode or self:startMode()) end)
end

function TickTick:buildItems(mode)
    local rows = Model.visibleTasks(
        self:cachedTasks(), mode, os.time(), self:offsetMinutes(),
        self:pendingCompleteIds(), self:excludedProjects())
    local note_list = mode.kind == "project" and self:projectKind(mode.project_id) == "NOTE"
    local items = {
        { text = self:syncRowText(), sync_row = true },
        { text = ICON.plus .. "  " .. (note_list and _("Add note") or _("Add task")), add_row = true },
    }
    items[#items + 1] = self:noDataRow()
    rows = Model.nestSubtasks(rows)
    for i, r in ipairs(rows) do
        if r.task.is_note then -- notes: no checkbox or due label; a first line of text instead
            items[#items + 1] = {
                text = ICON.notes .. "  " .. Model.displayName(r.task.title),
                mandatory = Model.displayName(Model.firstLine(r.task.content, 24)),
                task = r.task,
            }
        else
        items[#items + 1] = {
            text = string.rep(INDENT, r.depth or 0) .. ICON.box .. "  "
                .. Model.priorityMark(r.task.priority) .. Model.displayName(r.task.title),
            mandatory = Model.dueLabel(r.info),
            bold = r.tier == 0 or nil,
            task = r.task,
        }
        end
    end
    if #rows == 0 and self:cachedTasks() ~= nil then
        items[#items + 1] = { text = _("No tasks here."), select_enabled = false }
    end
    return items, #rows
end

function TickTick:listTitle(mode, count)
    return T(_("%1 (%2)"), self:modeTitle(mode), count)
end

--- Open (or switch to) a list of tasks. mode = {kind, project_id?}.
function TickTick:openList(mode)
    self.mode = mode
    if mode.kind ~= "search" then -- a search is not worth reopening next time
        self.state:saveSetting("last_mode", { kind = mode.kind, project_id = mode.project_id })
    end
    local items, count = self:buildItems(mode)
    local title = self:listTitle(mode, count)
    if self.list_menu then
        self.list_menu:switchItemTable(title, items)
        return
    end
    local plugin = self
    self.list_menu = fullScreenMenu{
        title = title,
        item_table = items,
        title_bar_left_icon = "appbar.menu",
        onLeftButtonTap = function()
            plugin:openDrawer()
        end,
        onMenuSelect = function(menu_self, item, pos)
            plugin:onRowTapped(item, pos)
            return true
        end,
        onMenuHold = function(menu_self, item)
            plugin:onRowHeld(item)
            return true
        end,
        close_callback = function()
            plugin.list_menu = nil
            plugin:closeDrawer()
            plugin.state:flush() -- remembers the last list
        end,
    }
    UIManager:show(self.list_menu)
end

--- Open a list straight away (gesture shortcut).
function TickTick:showTasks(mode)
    self:ensureData(function() self:openList(mode) end)
end

--- Rebuild the visible list, keeping the page. Pass `position` to keep a specific row's place.
function TickTick:refreshList(position)
    if not self.list_menu or not self.mode then return end
    local items, count = self:buildItems(self.mode)
    local title = self:listTitle(self.mode, count)
    if position then
        self.list_menu:switchItemTable(title, items, position)
    else
        reload(self.list_menu, title, items)
    end
end

--- Did a tap land on the row's checkbox? `pos` is where in the row, from 0 to 1
-- (KOReader passes it for taps; keys and older versions give none).
local function onCheckbox(pos)
    return type(pos) == "table" and type(pos.x) == "number" and pos.x <= CHECKBOX_ZONE
end

--- Tap a row: the checkbox completes the task, the rest opens it. (Hold to complete with a confirmation.)
function TickTick:onRowTapped(item, pos)
    if item.sync_row then
        self:sync()
        return
    end
    if item.add_row then
        self:addTask()
        return
    end
    if item.task and item.task.is_note then
        self:editNotes(item.task) -- a note opens straight into the editor
        return
    end
    if item.task then
        if onCheckbox(pos) then
            self:completeTask(item.task, { undo = true })
        else
            self:openDetail(item.task)
        end
    end
end

--- Hold a row: a menu of things to do with the task.
function TickTick:onRowHeld(item)
    if item.task and item.task.is_note then
        self:showNoteMenu(item.task)
    elseif item.task then
        self:showTaskMenu(item.task)
    end
end

function TickTick:showNoteMenu(note)
    local dialog
    local function choice(text, fn)
        return {{ text = text, callback = function()
            UIManager:close(dialog)
            fn()
        end }}
    end
    dialog = ButtonDialog:new{
        title = Model.displayName(note.title),
        buttons = {
            choice(ICON.notes .. "  " .. _("Open"), function() self:editNotes(note) end),
            choice(_("Rename…"), function() self:editTitle(note) end),
            choice(ICON.list .. "  " .. _("Move to list…"), function() self:chooseList(note) end),
            choice(ICON.trash .. "  " .. _("Delete…"), function() self:confirmDelete(note) end),
        },
    }
    UIManager:show(dialog)
end

function TickTick:showTaskMenu(task)
    local dialog
    local function choice(text, fn)
        return {{ text = text, callback = function()
            UIManager:close(dialog)
            fn()
        end }}
    end
    dialog = ButtonDialog:new{
        title = Model.displayName(task.title),
        buttons = {
            choice(_("Open"), function() self:openDetail(task) end),
            choice(ICON.check .. "  " .. _("Complete"), function() self:completeTask(task, { undo = true }) end),
            choice(ICON.list .. "  " .. _("Move to list…"), function() self:chooseList(task) end),
            choice(ICON.calendar .. "  " .. _("Due date…"), function() self:editDue(task) end),
            choice(ICON.flag .. "  " .. _("Priority…"), function() self:editPriority(task) end),
            choice(ICON.trash .. "  " .. _("Delete…"), function() self:confirmDelete(task) end),
        },
    }
    UIManager:show(dialog)
end

--- Pick a list to move a task to: the Inbox and every list you show.
function TickTick:chooseList(task)
    local excluded = self:excludedProjects()
    local function target(id, label, nested)
        local here = id == task.project_id
        return {
            text = (nested and INDENT or "") .. label,
            mandatory = here and _("current") or nil,
            bold = here or nil,
            select_enabled = not here,
            target = id,
        }
    end
    local items = {}
    local inbox = self:inboxId()
    if inbox and not task.is_note then items[#items + 1] = target(inbox, ICON.inbox .. "  " .. _("Inbox")) end
    for i, r in ipairs(self:listRows(function(p, nested)
        if excluded[p.id] then return nil end
        -- notes move between note lists, tasks between task lists
        if (p.kind == "NOTE") ~= (task.is_note == true) then return nil end
        return target(p.id, (p.kind == "NOTE" and ICON.notes or ICON.list) .. "  " .. Model.displayName(p.name), nested)
    end)) do
        items[#items + 1] = r
    end
    if #items == 0 then
        UIManager:show(InfoMessage:new{ text = _("Sync once to load your lists.") })
        return
    end
    local plugin = self
    local menu
    menu = fullScreenMenu{
        title = T(_("Move to: %1"), Model.displayName(task.title)),
        item_table = items,
        onMenuSelect = function(menu_self, item)
            if item.target and item.target ~= task.project_id then
                UIManager:close(menu)
                plugin:moveTask(task, item.target)
            end
            return true
        end,
    }
    UIManager:show(menu)
end

--- Move a task: shown in its new list at once, queued, uploaded right away if online.
function TickTick:moveTask(task, to_project_id)
    if not task.project_id or not task.id then
        UIManager:show(InfoMessage:new{ text = _("This task is missing its IDs. Try syncing again.") })
        return
    end
    self:queueMove(task, to_project_id)
    local name = self:projectName(to_project_id)
    local cached = self:findCachedTask(task.id)
    for i, t in ipairs({ task, cached or task }) do
        t.project_id, t.project = to_project_id, name
    end
    self.state:flush()
    self:refreshAll()

    local moved_msg = T(_("Moved to %1."), Model.displayName(name or ""))
    local client = self:getClient()
    if not client or not NetworkMgr:isOnline() then
        UIManager:show(InfoMessage:new{
            text = moved_msg .. " " .. _("It will upload on your next sync."),
            timeout = 2,
        })
        return
    end
    local ok, kind, detail = self:flushPending(client)
    if ok then
        UIManager:show(InfoMessage:new{ text = moved_msg, timeout = 1 })
    else
        UIManager:show(InfoMessage:new{
            text = _("Saved on this device, but not uploaded yet. It will retry on your next sync.\n\n")
                .. self:describeError(kind, detail),
        })
    end
end

function TickTick:confirmComplete(task)
    UIManager:show(ConfirmBox:new{
        text = T(_("Mark as complete?\n\n%1"), Model.displayName(task.title)),
        ok_text = _("Complete"),
        ok_callback = function()
            self:completeTask(task)
        end,
    })
end

--- Complete a task. With opts.undo, "Undo" is offered for a few seconds before it uploads.
function TickTick:completeTask(task, opts)
    if not task.project_id or not task.id then
        UIManager:show(InfoMessage:new{ text = _("This task is missing its IDs. Try syncing again.") })
        return
    end
    -- Remember where the row was so the list does not jump back to page 1.
    local position
    if self.list_menu then
        for idx, it in ipairs(self.list_menu.item_table) do
            if it.task and it.task.id == task.id then position = idx break end
        end
    end

    -- Queue first: the row disappears at once and the completion survives a failed upload.
    local pending = self:pendingList()
    pending[#pending + 1] = { op = "complete", project_id = task.project_id, task_id = task.id, title = task.title }
    self:setPending(pending)
    if self.detail_task and self.detail_task.id == task.id then
        self:closeDetail()
    end
    self:refreshList(position)
    self:refreshDrawer()

    if opts and opts.undo then
        self:offerUndo(task, position)
    else
        self:uploadCompletion(position)
    end
end

--- Show "Completed" with an Undo button. It closes by itself after UNDO_SECONDS;
-- the completion uploads when it closes (OK or timeout), and Undo takes it back
-- before anything is sent.
function TickTick:offerUndo(task, position)
    local settled = false
    local box, timer
    local function keep()
        if settled then return end
        settled = true
        UIManager:unschedule(timer)
        self:uploadCompletion(position, true)
    end
    timer = function()
        UIManager:close(box)
        keep()
    end
    box = ConfirmBox:new{
        text = T(_("Completed:\n%1"), Model.displayName(task.title)),
        icon = "check",
        ok_text = _("OK"),
        cancel_text = _("Undo"),
        dismissable = false, -- a stray tap outside must not count as Undo
        ok_callback = keep,
        cancel_callback = function()
            if settled then return end
            settled = true
            UIManager:unschedule(timer)
            self:undoComplete(task, position)
        end,
    }
    UIManager:show(box)
    UIManager:scheduleIn(UNDO_SECONDS, timer)
end

--- Take back a completion that has not uploaded yet.
function TickTick:undoComplete(task, position)
    local kept = {}
    for i, p in ipairs(self:pendingList()) do
        if not (isCompletion(p) and p.task_id == task.id) then kept[#kept + 1] = p end
    end
    self:setPending(kept)
    self:refreshList(position)
    self:refreshDrawer()
    UIManager:show(InfoMessage:new{ text = _("Not completed."), timeout = 1 })
end

--- Upload queued changes after a completion, or say they will go on the next sync.
-- `quiet` skips the "Completed." message (the Undo box already said so).
function TickTick:uploadCompletion(position, quiet)
    local client = self:getClient()
    if not client or not NetworkMgr:isOnline() then
        UIManager:show(InfoMessage:new{
            text = _("Saved. It will upload on your next sync."),
            timeout = 2,
        })
        return
    end

    local info = InfoMessage:new{ text = _("Uploading…") }
    UIManager:show(info)
    UIManager:forceRePaint()
    local ok, kind, detail = self:flushPending(client)
    UIManager:close(info)
    if ok then
        self:refreshList(position)
        self:refreshDrawer()
        if not quiet then
            UIManager:show(InfoMessage:new{ text = _("Completed."), timeout = 1 })
        end
    else
        UIManager:show(InfoMessage:new{
            text = _("Saved, but not uploaded yet. It will retry on your next sync.\n\n")
                .. self:describeError(kind, detail),
        })
    end
end

--- Search every task's title, notes and checklist.
function TickTick:promptSearch()
    self:showInput{
        title = _("Search tasks"),
        input = self.last_query or "",
        hint = _("Words in a title, notes or checklist"),
        save_text = _("Search"),
        on_save = function(value)
            value = (value or ""):gsub("^%s+", ""):gsub("%s+$", "")
            if value == "" then return end
            self.last_query = value
            self:closeDrawer()
            self:openList({ kind = "search", query = value })
        end,
    }
end

-- ---------------------------------------------------------------------------
-- Adding and deleting tasks
-- ---------------------------------------------------------------------------

--- Where a task added from this list goes, and its due date: a list adds to itself;
-- Today and Tomorrow add to the Inbox, due that day; other smart lists add to the Inbox.
function TickTick:addTarget(mode)
    if mode.kind == "project" then return mode.project_id end
    local inbox = self:inboxId()
    if not inbox then return nil end
    local offset = self:offsetMinutes()
    local today = math.floor((os.time() + offset * 60) / 86400)
    local shift = ({ today = 0, tomorrow = 1 })[mode.kind]
    if shift then
        local t = os.date("!*t", (today + shift) * 86400)
        return inbox, Model.dueFields(t.year, t.month, t.day, nil, nil, offset)
    end
    return inbox
end

function TickTick:addTask()
    local project_id, due = self:addTarget(self.mode or { kind = "today" })
    if not project_id then
        UIManager:show(InfoMessage:new{
            text = _("To add tasks here, set up the Inbox (Settings > Inbox list ID), or add from one of your lists."),
        })
        return
    end
    local where = Model.displayName(self:projectName(project_id) or "")
    if self:projectKind(project_id) == "NOTE" then
        self:showInput{
            title = T(_("New note in %1"), where),
            hint = _("Note title"),
            save_text = _("Add"),
            on_save = function(value)
                value = (value or ""):gsub("^%s+", ""):gsub("%s+$", "")
                if value == "" then return end
                local note = self:createTask(value, project_id, nil, { kind = "NOTE" })
                if note then self:editNotes(note) end -- straight to writing it
            end,
        }
        return
    end
    self:showInput{
        title = T(_("New task in %1"), where),
        hint = _("Task title"),
        description = due and _("Due today or tomorrow, like this list. Change it later on the task screen.") or nil,
        save_text = _("Add"),
        on_save = function(value)
            value = (value or ""):gsub("^%s+", ""):gsub("%s+$", "")
            if value == "" then return end
            self:createTask(value, project_id, due)
        end,
    }
end

function TickTick:addSubtask(parent)
    self:showInput{
        title = T(_("New subtask of: %1"), Model.displayName(parent.title)),
        hint = _("Subtask title"),
        save_text = _("Add"),
        on_save = function(value)
            value = (value or ""):gsub("^%s+", ""):gsub("%s+$", "")
            if value == "" then return end
            self:createTask(value, parent.project_id, nil, { parentId = parent.id })
        end,
    }
end

--- Add a task: shown at once, queued, uploaded right away if online.
-- `extra` holds more API fields, e.g. {parentId = ...} for a subtask.
function TickTick:createTask(title, project_id, due, extra)
    local id = newLocalId()
    local fields = { title = title }
    for k, v in pairs(due or {}) do fields[k] = v end
    for k, v in pairs(extra or {}) do fields[k] = v end
    local task = Model.slimTask({
        id = id, projectId = project_id, title = title, priority = 0, status = 0,
        dueDate = fields.dueDate, startDate = fields.startDate, isAllDay = fields.isAllDay,
        parentId = fields.parentId, kind = fields.kind,
    }, self:projectName(project_id))
    task.is_note = (self:projectKind(project_id) == "NOTE" or fields.kind == "NOTE") or nil
    local tasks = self:cachedTasks() or {}
    tasks[#tasks + 1] = task
    self.state:saveSetting("tasks", tasks)
    local pending = self:pendingList()
    pending[#pending + 1] = { op = "create", project_id = project_id, task_id = id, title = title, fields = fields }
    self:setPending(pending)
    self:refreshAll()

    local client = self:getClient()
    if not client or not NetworkMgr:isOnline() then
        UIManager:show(InfoMessage:new{ text = _("Added on this device. It will upload on your next sync."), timeout = 2 })
        return task
    end
    local ok, kind, detail = self:flushPending(client)
    self:refreshAll()
    if ok then
        UIManager:show(InfoMessage:new{ text = _("Added."), timeout = 1 })
    else
        UIManager:show(InfoMessage:new{
            text = _("Added on this device, but not uploaded yet. It will retry on your next sync.\n\n")
                .. self:describeError(kind, detail),
        })
    end
    return task
end

function TickTick:confirmDelete(task)
    UIManager:show(ConfirmBox:new{
        text = T(_("Delete this task?\n\n%1"), Model.displayName(task.title)),
        ok_text = _("Delete"),
        ok_callback = function() self:deleteTask(task) end,
    })
end

function TickTick:deleteTask(task)
    if self.detail_task and self.detail_task.id == task.id then
        self:closeDetail()
    end
    local pending = self:pendingList()
    if isLocalId(task.id) then
        -- Never uploaded: forget it and everything queued for it.
        local kept = {}
        for i, p in ipairs(pending) do
            if p.task_id ~= task.id then kept[#kept + 1] = p end
        end
        self:dropCachedTask(task.id)
        self:setPending(kept)
        self:refreshAll()
        UIManager:show(InfoMessage:new{ text = _("Deleted."), timeout = 1 })
        return
    end
    pending[#pending + 1] = { op = "delete", project_id = task.project_id, task_id = task.id, title = task.title }
    self:setPending(pending)
    self:refreshAll()

    local client = self:getClient()
    if not client or not NetworkMgr:isOnline() then
        UIManager:show(InfoMessage:new{ text = _("Deleted on this device. It will upload on your next sync."), timeout = 2 })
        return
    end
    local ok, kind, detail = self:flushPending(client)
    if ok then
        UIManager:show(InfoMessage:new{ text = _("Deleted."), timeout = 1 })
    else
        UIManager:show(InfoMessage:new{
            text = _("Deleted on this device, but not uploaded yet. It will retry on your next sync.\n\n")
                .. self:describeError(kind, detail),
        })
    end
end

-- ---------------------------------------------------------------------------
-- Task detail screen
-- ---------------------------------------------------------------------------

function TickTick:detailItems(task)
    local items = {}
    items[#items + 1] = {
        text = ICON.box .. "  " .. Model.displayName(task.title), mandatory = _("Edit"), bold = true,
        action = function(pos)
            if onCheckbox(pos) then self:completeTask(task, { undo = true }) else self:editTitle(task) end
        end,
    }
    local preview = Model.firstLine(Model.notesOf(task), 46)
    items[#items + 1] = {
        text = ICON.notes .. "  " .. (preview ~= "" and T(_("Notes: %1"), Model.displayName(preview)) or _("Notes: (none)")),
        mandatory = _("Edit"),
        action = function() self:editNotes(task) end,
    }
    local info = Model.dueInfo({ dueDate = task.due, startDate = task.start, isAllDay = task.all_day },
        os.time(), self:offsetMinutes())
    items[#items + 1] = {
        text = ICON.calendar .. "  " .. _("Due"), mandatory = info and Model.dueLabel(info) or _("None"),
        action = function() self:editDue(task) end,
    }
    items[#items + 1] = {
        text = ICON.flag .. "  " .. _("Priority"), mandatory = Model.priorityName(task.priority),
        action = function() self:editPriority(task) end,
    }
    items[#items + 1] = {
        text = ICON.list .. "  " .. _("List"), mandatory = Model.displayName(task.project or ""),
        action = function() self:chooseList(task) end,
    }
    for i, it in ipairs(task.checklist or {}) do
        local item_id = it.id
        items[#items + 1] = {
            text = (it.done and ICON.box_done or ICON.box) .. "  " .. Model.displayName(it.title),
            action = function() self:toggleChecklistItem(task, item_id) end,
        }
    end
    if Model.checklistEditable(task) then
        items[#items + 1] = {
            text = ICON.plus .. "  " .. _("Add checklist item"),
            action = function() self:addChecklistItem(task) end,
        }
    end
    -- Real subtasks (separate tasks with this one as parent), and the parent of a subtask.
    local parent = task.parent_id and self:findCachedTask(task.parent_id)
    if parent then
        items[#items + 1] = {
            text = ICON.up .. "  " .. T(_("Subtask of: %1"), Model.displayName(parent.title)),
            action = function() self:openDetail(parent) end,
        }
    end
    local gone = self:pendingCompleteIds()
    for i, child in ipairs(self:cachedTasks() or {}) do
        if child.parent_id == task.id and child.status == 0 and not gone[child.id] then
            items[#items + 1] = {
                text = ICON.subtask .. "  " .. ICON.box .. "  " .. Model.displayName(child.title),
                mandatory = _("Subtask"),
                action = function(pos)
                    if onCheckbox(pos) then self:completeTask(child, { undo = true }) else self:openDetail(child) end
                end,
            }
        end
    end
    items[#items + 1] = {
        text = ICON.plus .. "  " .. _("Add subtask"),
        action = function() self:addSubtask(task) end,
    }
    items[#items + 1] = {
        text = ICON.check .. "  " .. _("Mark as complete"), bold = true,
        action = function() self:confirmComplete(task) end,
    }
    return items
end

function TickTick:openDetail(task)
    self.detail_task = task
    if self.detail_menu then
        self:refreshDetail()
        return
    end
    local plugin = self
    self.detail_menu = fullScreenMenu{
        title = _("Task"),
        item_table = self:detailItems(task),
        onMenuSelect = function(menu_self, item, pos)
            if item.action then item.action(pos) end
            return true
        end,
        close_callback = function()
            plugin.detail_menu = nil
            plugin.detail_task = nil
            plugin:refreshList()
        end,
    }
    UIManager:show(self.detail_menu)
end

function TickTick:refreshDetail()
    if self.detail_menu and self.detail_task then
        reload(self.detail_menu, _("Task"), self:detailItems(self.detail_task))
    end
end

function TickTick:closeDetail()
    local menu = self.detail_menu
    self.detail_menu, self.detail_task = nil, nil
    if menu then UIManager:close(menu) end
end

-- ---------------------------------------------------------------------------
-- Editing title and notes
-- ---------------------------------------------------------------------------

--- Apply an edit locally, queue it, and upload right away if online.
-- @param fields API-named fields, e.g. {title = "..."} or {content = "..."}
function TickTick:saveEdit(task, fields, quiet)
    local cached = self:findCachedTask(task.id)
    Model.applyFields(task, fields)
    if cached and cached ~= task then Model.applyFields(cached, fields) end
    self:queueUpdate(task, fields)
    self:refreshDetail()
    self:refreshList()

    local client = self:getClient()
    if not client or not NetworkMgr:isOnline() then
        if not quiet then
            UIManager:show(InfoMessage:new{
                text = _("Saved on this device. It will upload on your next sync."),
                timeout = 2,
            })
        end
        return
    end
    local ok, kind, detail = self:flushPending(client)
    self:refreshDetail() -- the upload may have brought ids for new checklist items
    if not ok then
        UIManager:show(InfoMessage:new{
            text = _("Saved on this device, but not uploaded yet. It will retry on your next sync.\n\n")
                .. self:describeError(kind, detail),
        })
    end
end

function TickTick:editTitle(task)
    self:showInput{
        title = _("Task title"),
        input = task.title,
        on_save = function(value)
            value = (value or ""):gsub("^%s+", ""):gsub("%s+$", "")
            if value == "" then
                UIManager:show(InfoMessage:new{ text = _("A task needs a title.") })
                return
            end
            if value == task.title then return end
            self:saveEdit(task, { title = value })
        end,
    }
end

--- Tick or untick a checklist item. TickTick's API replaces the whole checklist,
-- so when online the newest list is fetched first and only this item is changed.
function TickTick:toggleChecklistItem(task, item_id)
    if not item_id or not Model.checklistEditable(task) then
        UIManager:show(InfoMessage:new{
            text = task.checklist_truncated
                and _("This checklist is too long to edit on the device. Use TickTick.")
                or _("Sync once, then try again (this checklist was downloaded by an older version)."),
        })
        return
    end
    local client = self:getClient()
    if client and NetworkMgr:isOnline() and not self:hasPendingUpdate(task.id) then
        local fresh = client:getTask(task.project_id, task.id)
        if fresh and fresh.id == task.id then
            local cached = self:findCachedTask(task.id)
            for i, t in ipairs({ task, cached or task }) do
                t.checklist, t.subtasks, t.subtasks_done = fresh.checklist, fresh.subtasks, fresh.subtasks_done
                t.checklist_truncated = fresh.checklist_truncated
                t.kind = fresh.kind or t.kind
            end
            if not Model.checklistEditable(task) then
                self:refreshDetail()
                return self:toggleChecklistItem(task, nil)
            end
        end
    end
    local list, found = {}, false
    for i, it in ipairs(task.checklist or {}) do
        local copy = {}
        for k, v in pairs(it) do copy[k] = v end
        if copy.id == item_id then copy.done, found = not copy.done, true end
        list[i] = copy
    end
    if not found then
        self:refreshDetail()
        UIManager:show(InfoMessage:new{ text = _("That item was removed in TickTick."), timeout = 2 })
        return
    end
    self:saveEdit(task, { items = Model.itemsFromChecklist(list) }, true)
end

--- Due date options: date, time, all day, remove.
function TickTick:editDue(task)
    local offset = self:offsetMinutes()
    local parts = Model.dueParts(task, os.time(), offset)
    local info = Model.dueInfo({ dueDate = task.due, startDate = task.start, isAllDay = task.all_day },
        os.time(), offset)
    local dialog
    local function choice(text, fn)
        return {{ text = text, callback = function()
            UIManager:close(dialog)
            fn()
        end }}
    end
    local buttons = {
        choice(ICON.calendar .. "  " .. (parts.has_due and _("Change date…") or _("Set date…")),
            function() self:pickDueDate(task, parts, offset) end),
        choice(ICON.clock .. "  " .. (parts.hour and _("Change time…") or _("Set a time…")),
            function() self:pickDueTime(task, parts, offset) end),
    }
    if parts.hour then
        buttons[#buttons + 1] = choice(_("All day (remove the time)"), function()
            self:saveEdit(task, Model.dueFields(parts.year, parts.month, parts.day, nil, nil, offset))
        end)
    end
    if parts.has_due then
        buttons[#buttons + 1] = choice(ICON.trash .. "  " .. _("Remove due date"), function()
            self:saveEdit(task, Model.clearDueFields())
        end)
    end
    dialog = ButtonDialog:new{
        title = T(_("Due: %1"), info and Model.dueLabel(info) or _("None")),
        buttons = buttons,
    }
    UIManager:show(dialog)
end

--- Pick the date. A timed task keeps its time of day.
function TickTick:pickDueDate(task, parts, offset)
    UIManager:show(DateTimeWidget:new{
        year = parts.year, month = parts.month, day = parts.day,
        title_text = _("Due date"),
        info_text = parts.hour and T(_("Keeps its time, %1"), string.format("%02d:%02d", parts.hour, parts.min)) or nil,
        ok_text = _("Set date"),
        callback = function(time)
            self:saveEdit(task, Model.dueFields(time.year, time.month, time.day, parts.hour, parts.min, offset))
        end,
    })
end

--- Pick a time of day. An undated task gets today's date.
function TickTick:pickDueTime(task, parts, offset)
    UIManager:show(DateTimeWidget:new{
        hour = parts.hour or 9, min = parts.min or 0,
        title_text = _("Due time"),
        info_text = T(_("On %1"), string.format("%04d-%02d-%02d", parts.year, parts.month, parts.day)),
        ok_text = _("Set time"),
        callback = function(time)
            self:saveEdit(task, Model.dueFields(parts.year, parts.month, parts.day, time.hour, time.min, offset))
        end,
    })
end

--- Add an item to a task's checklist. A plain task becomes a checklist task with its
-- notes kept (see Model.addChecklistFields).
function TickTick:addChecklistItem(task)
    self:showInput{
        title = _("New checklist item"),
        hint = _("Item"),
        save_text = _("Add"),
        on_save = function(value)
            value = (value or ""):gsub("^%s+", ""):gsub("%s+$", "")
            if value == "" then return end
            local list = {}
            for i, it in ipairs(task.checklist or {}) do list[i] = it end
            list[#list + 1] = { id = newLocalId(), title = value, done = false, status = 0 }
            self:saveEdit(task, Model.addChecklistFields(task, list), true)
        end,
    }
end

function TickTick:editPriority(task)
    local dialog
    local row = {}
    for i, p in ipairs(Model.PRIORITIES) do
        local name = Model.priorityName(p)
        row[#row + 1] = {
            text = (p == (task.priority or 0)) and (ICON.check .. " " .. name) or name,
            callback = function()
                UIManager:close(dialog)
                if p ~= (task.priority or 0) then self:saveEdit(task, { priority = p }) end
            end,
        }
    end
    dialog = ButtonDialog:new{ title = _("Priority"), buttons = { row } }
    UIManager:show(dialog)
end

function TickTick:editNotes(task)
    if task.content_truncated then
        UIManager:show(InfoMessage:new{
            text = _("These notes are too long to edit on the device. Edit them in TickTick."),
        })
        return
    end
    local field = Model.notesField(task)

    -- The same full-screen editor KOReader's Text Editor uses: opens for reading (tap
    -- the text to type), with find/replace, undo and go-to-line, landscape, and the
    -- reading position remembered per task.
    local function openEditor(text, label)
        local original = text or ""
        local dialog
        self.view_pos = self.view_pos or {}
        dialog = InputDialog:new{
            title = label,
            input = original,
            allow_newline = true,
            fullscreen = true,
            condensed = true,
            cursor_at_end = false,
            add_nav_bar = true,
            scroll_by_pan = true,
            rotation_enabled = true,
            keyboard_visible = false,
            view_pos_callback = function(top_line_num, charpos)
                if top_line_num and charpos then
                    self.view_pos[task.id] = { top_line_num, charpos }
                elseif self.view_pos[task.id] then
                    return self.view_pos[task.id][1], self.view_pos[task.id][2]
                end
            end,
            reset_callback = function()
                return original, _("Text reset to the last saved version.")
            end,
            close_callback = function()
                if dialog.rotation_mode_backup and Screen.getRotationMode
                        and dialog.rotation_mode_backup ~= Screen:getRotationMode() then
                    Screen:setRotationMode(dialog.rotation_mode_backup)
                end
            end,
            save_callback = function(content, closing)
                if content ~= original then
                    original = content
                    self:saveEdit(task, { [field] = content }, true)
                    return true, NetworkMgr:isOnline() and _("Saved.") or _("Saved on this device. It will upload on your next sync.")
                end
                return true
            end,
        }
        UIManager:show(dialog)
    end
    local label = task.is_note and Model.displayName(task.title) or _("Notes")

    -- Online: start from TickTick's current text, so a newer edit made elsewhere is not overwritten.
    local client = self:getClient()
    if client and NetworkMgr:isOnline() and not self:hasPendingUpdate(task.id) then
        local info = InfoMessage:new{ text = _("Loading notes…") }
        UIManager:show(info)
        UIManager:forceRePaint()
        local fresh = client:getTask(task.project_id, task.id)
        UIManager:close(info)
        if fresh and fresh.id == task.id then
            local cached = self:findCachedTask(task.id)
            for i, t in ipairs({ task, cached or task }) do
                t.content, t.desc, t.content_truncated = fresh.content, fresh.desc, fresh.content_truncated
                t.kind = fresh.kind or t.kind
            end
            self.state:flush()
            if fresh.content_truncated then
                UIManager:show(InfoMessage:new{
                    text = _("These notes are too long to edit on the device. Edit them in TickTick."),
                })
                return
            end
            openEditor(Model.notesOf(task), label)
            return
        end
    end
    openEditor(Model.notesOf(task), T(_("%1 (copy from last sync)"), label))
end

-- ---------------------------------------------------------------------------
-- Settings
-- ---------------------------------------------------------------------------

function TickTick:showInput(opts)
    local dialog
    dialog = InputDialog:new{
        title = opts.title,
        input = opts.input or "",
        input_hint = opts.hint,
        description = opts.description,
        buttons = {{
            {
                text = _("Cancel"),
                id = "close",
                callback = function() UIManager:close(dialog) end,
            },
            {
                text = opts.save_text or _("Save"),
                is_enter_default = true,
                callback = function()
                    local value = dialog:getInputText()
                    UIManager:close(dialog)
                    opts.on_save(value)
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function TickTick:promptForToken(after)
    self:showInput{
        title = _("TickTick access token"),
        input = self.settings:readSetting("access_token") or "",
        hint = _("Paste token"),
        description = _("Easier: run get_token.py on a computer and copy the ticktick.lua it creates into koreader/settings/."),
        on_save = function(value)
            value = (value or ""):gsub("%s+", "")
            if value == "" then return end
            self.settings:saveSetting("access_token", value)
            self.settings:flush()
            UIManager:show(InfoMessage:new{ text = _("Token saved."), timeout = 2 })
            if after then after() end
        end,
    }
end

function TickTick:promptForOffset(after)
    self:showInput{
        title = _("Time zone offset"),
        input = type(self.settings:readSetting("utc_offset_minutes")) == "number"
            and tostring(self.settings:readSetting("utc_offset_minutes") / 60) or "",
        hint = _("Hours from UTC, e.g. -5 (blank = automatic)"),
        description = _("Decides which tasks count as 'today'. Leave blank to follow the device clock."),
        on_save = function(value)
            value = (value or ""):gsub("%s+", "")
            if value == "" then
                self.settings:delSetting("utc_offset_minutes")
            else
                local hours = tonumber(value)
                if not hours or hours < -14 or hours > 14 then
                    UIManager:show(InfoMessage:new{ text = _("Enter a number of hours between -14 and 14.") })
                    return
                end
                self.settings:saveSetting("utc_offset_minutes", math.floor(hours * 60 + 0.5))
            end
            self.settings:flush()
            self:refreshAll()
            if after then after() end
        end,
    }
end

function TickTick:promptForExtraIds(after)
    self:showInput{
        title = _("Inbox list ID"),
        input = table.concat(self:extraProjectIds(), ", "),
        hint = _("e.g. inbox123456789"),
        description = _("TickTick's API does not list your Inbox, so give its ID here. The first ID is shown as Inbox. Separate several IDs with commas, then sync."),
        on_save = function(value)
            local ids = {}
            for id in (value or ""):gmatch("[^,%s]+") do ids[#ids + 1] = id end
            self.settings:saveSetting("extra_project_ids", ids)
            self.settings:flush()
            if after then after() end
        end,
    }
end

--- A simple full-screen menu whose rows run item.action(refresh); `build` returns the rows.
function TickTick:showSettingsMenu(field, title, build, on_close)
    local plugin = self
    local menu
    local function refresh()
        reload(menu, title, build())
    end
    menu = fullScreenMenu{
        title = title,
        item_table = build(),
        onMenuSelect = function(menu_self, item)
            if item.action then item.action(refresh) end
            return true
        end,
        close_callback = function()
            plugin[field] = nil
            if on_close then on_close() end
        end,
    }
    self[field] = menu
    UIManager:show(menu)
end

function TickTick:settingsItems()
    local has_token = self.settings:readSetting("access_token")
    local manual = type(self.settings:readSetting("utc_offset_minutes")) == "number"
    local extras = #self:extraProjectIds()
    return {
        {
            text = _("Lists to show"),
            action = function() self:openListsToggle() end,
        },
        {
            text = T(_("Time zone: %1 (%2)"), formatOffset(self:offsetMinutes()), manual and _("manual") or _("automatic")),
            action = function(refresh) self:promptForOffset(refresh) end,
        },
        {
            text = extras > 0 and T(_("Inbox list ID (%1 set)"), extras) or _("Inbox list ID (not set)"),
            action = function(refresh) self:promptForExtraIds(refresh) end,
        },
        {
            text = (has_token and has_token ~= "") and _("Change access token") or _("Set access token"),
            action = function(refresh) self:promptForToken(refresh) end,
        },
    }
end

function TickTick:openSettings()
    self:showSettingsMenu("settings_menu", _("Settings"), function() return self:settingsItems() end,
        function() self:refreshAll() end)
end

function TickTick:listsToggleItems()
    local items = {}
    for i, r in ipairs(self:listRows(function(p, nested)
        local hidden = self:excludedProjects()[p.id]
        return {
            text = (nested and INDENT or "") .. (hidden and ICON.box or ICON.box_done) .. "  " .. Model.displayName(p.name),
            action = function(refresh)
                local excluded = self:excludedProjects()
                if excluded[p.id] then excluded[p.id] = nil else excluded[p.id] = true end
                self.state:saveSetting("excluded_projects", excluded)
                self.state:flush()
                refresh()
            end,
        }
    end)) do
        items[#items + 1] = r
    end
    if #items == 0 then
        items[1] = { text = _("Sync once to load your lists."), select_enabled = false }
    else
        table.insert(items, 1, {
            text = _("Tap a list to show or hide it. Hidden lists are skipped when syncing."),
            select_enabled = false,
        })
    end
    return items
end

function TickTick:openListsToggle()
    self:showSettingsMenu("lists_menu", _("Lists to show"), function() return self:listsToggleItems() end,
        function() self:refreshAll() end)
end

-- ---------------------------------------------------------------------------
-- Main menu: one entry, straight to the last list viewed
-- ---------------------------------------------------------------------------

function TickTick:addToMainMenu(menu_items)
    menu_items.ticktick = {
        text = _("TickTick"),
        sorting_hint = "tools",
        callback = function(touchmenu_instance)
            if touchmenu_instance and touchmenu_instance.closeMenu then
                touchmenu_instance:closeMenu()
            end
            self:showHome()
        end,
    }
end

return TickTick
