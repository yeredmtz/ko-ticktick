--[[--
Pure task logic for the TickTick plugin: date parsing, bucketing, sorting and
filtering. No KOReader dependencies, so it can be unit-tested anywhere.

All code is LuaJIT / Lua 5.1 compatible.
]]

local Model = {}

local DAY = 86400

-- Days since 1970-01-01 for a civil (proleptic Gregorian) date.
function Model.daysFromCivil(y, m, d)
    y, m, d = tonumber(y), tonumber(m), tonumber(d)
    if m <= 2 then y = y - 1 end
    local era = math.floor(y / 400)
    local yoe = y - era * 400
    local mp = (m + 9) % 12 -- March = 0 ... February = 11
    local doy = math.floor((153 * mp + 2) / 5) + d - 1
    local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
    return era * 146097 + doe - 719468
end

--- Parse "2026-11-04T05:00:00.000+0000" (also "+05:30", "Z", or a bare date).
-- @treturn number|nil UTC epoch seconds
-- @treturn number|nil UTC offset written in the string, in minutes
function Model.parseTimestamp(s)
    if type(s) ~= "string" then return nil end
    local y, mo, d, h, mi, sec, rest = s:match("^(%d%d%d%d)-(%d%d)-(%d%d)T(%d%d):(%d%d):(%d%d)(.*)$")
    if not y then
        y, mo, d = s:match("^(%d%d%d%d)-(%d%d)-(%d%d)$")
        if not y then return nil end
        h, mi, sec, rest = 0, 0, 0, ""
    end
    local epoch = Model.daysFromCivil(y, mo, d) * DAY + tonumber(h) * 3600 + tonumber(mi) * 60 + tonumber(sec)
    rest = (rest:gsub("^%.%d+", ""))
    local off_min = 0
    local sign, oh, om = rest:match("^([+-])(%d%d):?(%d%d)$")
    if sign then
        off_min = tonumber(oh) * 60 + tonumber(om)
        if sign == "-" then off_min = -off_min end
        epoch = epoch - off_min * 60
    end
    return epoch, off_min
end

--- Offset of the device's local clock from UTC, in minutes (DST-aware).
-- Pure arithmetic on broken-down times, so it does not depend on os.time()'s
-- handling of isdst.
function Model.deviceOffsetMinutes(now)
    now = now or os.time()
    local lt, ut = os.date("*t", now), os.date("!*t", now)
    local function secs(t)
        return Model.daysFromCivil(t.year, t.month, t.day) * DAY + t.hour * 3600 + t.min * 60 + t.sec
    end
    return math.floor((secs(lt) - secs(ut)) / 60 + 0.5)
end

local function str(v) if type(v) == "string" then return v end end
local function num(v) if type(v) == "number" then return v end end

--- Describe a task's due date relative to "now".
-- @param offset_min UTC offset (minutes) used to decide which calendar day it is
-- @return table {epoch, all_day, day (days since epoch, local), days_diff, hour, min} or nil if undated
function Model.dueInfo(task, now, offset_min)
    local raw = str(task.dueDate) or str(task.startDate)
    if not raw then return nil end
    local epoch, str_off = Model.parseTimestamp(raw)
    if not epoch then return nil end
    local all_day = task.isAllDay == true
    local day
    if all_day then
        if str_off ~= 0 then
            -- The string already carries the user's local offset: its date is the date.
            day = math.floor((epoch + str_off * 60) / DAY)
        else
            -- All-day dates are stored as local midnight expressed in UTC. Shifting by
            -- +12h keeps the right day even when our offset is off by a DST hour.
            day = math.floor((epoch + offset_min * 60 + 12 * 3600) / DAY)
        end
    else
        day = math.floor((epoch + offset_min * 60) / DAY)
    end
    local today = math.floor((now + offset_min * 60) / DAY)
    local info = { epoch = epoch, all_day = all_day, day = day, days_diff = day - today }
    if not all_day then
        local t = os.date("!*t", epoch + offset_min * 60)
        info.hour, info.min = t.hour, t.min
    end
    return info
end

--- Fields that set a task's due date, in TickTick's format (UTC, "+0000").
-- y/m/d is the local calendar date; hour/min nil means an all-day task, stored
-- like TickTick does: local midnight expressed in UTC. startDate is set to the
-- same value so the task does not turn into a date range.
function Model.dueFields(y, m, d, hour, min, offset_min)
    local epoch = Model.daysFromCivil(y, m, d) * DAY + (hour or 0) * 3600 + (min or 0) * 60 - offset_min * 60
    local s = os.date("!%Y-%m-%dT%H:%M:%S.000+0000", epoch)
    return { dueDate = s, startDate = s, isAllDay = hour == nil }
end

--- Fields that remove a task's due date.
-- NOT verified against the live API: that an empty string clears it.
function Model.clearDueFields()
    return { dueDate = "", startDate = "", isAllDay = false }
end

--- A slim task's due date as local parts, to prefill the date picker.
-- Undated tasks get today's date and has_due = false. hour/min are nil for all-day tasks.
function Model.dueParts(task, now, offset_min)
    local info = Model.dueInfo({ dueDate = task.due, startDate = task.start, isAllDay = task.all_day }, now, offset_min)
    local day = info and info.day or math.floor((now + offset_min * 60) / DAY)
    local t = os.date("!*t", day * DAY)
    return {
        year = t.year, month = t.month, day = t.day,
        hour = info and info.hour, min = info and info.min,
        has_due = info ~= nil,
    }
end

-- API field names that are stored under another name in a slim task.
local API_TO_SLIM = { dueDate = "due", startDate = "start", isAllDay = "all_day" }

--- Apply API-named fields (as queued and uploaded) to a slim task.
function Model.applyFields(task, fields)
    for k, v in pairs(fields) do
        if k == "items" then
            task.checklist, task.subtasks_done = Model.checklistFromItems(v)
            task.subtasks = #task.checklist
        else
            if v == "" and API_TO_SLIM[k] then v = nil end -- cleared date
            task[API_TO_SLIM[k] or k] = v
        end
    end
end

-- Priority: TickTick uses 0 none, 1 low, 3 medium, 5 high.
Model.PRIORITIES = { 0, 1, 3, 5 }

--- Lists in TickTick's sidebar order, folders kept together.
-- @param projects array of {id, name, group_id?, sort_order?, extra?} (extra = the Inbox; skipped)
-- @return array of entries: {list = project} or {folder = group_id, lists = {project, ...}}.
--   Lists are ordered by sortOrder (lowest first); a folder sits where its first list
--   would. Lists without a sortOrder (cache from an older version) keep their order.
function Model.orderProjects(projects)
    local entries, folders, index = {}, {}, {}
    for i, p in ipairs(projects or {}) do
        if not p.extra then
            index[p] = i
            local gid = p.group_id
            if gid then
                local f = folders[gid]
                if not f then
                    f = { folder = gid, lists = {} }
                    folders[gid] = f
                    entries[#entries + 1] = f
                end
                f.lists[#f.lists + 1] = p
            else
                entries[#entries + 1] = { list = p }
            end
        end
    end
    local function before(a, b)
        local ka, kb = a.sort_order or 0, b.sort_order or 0
        if ka ~= kb then return ka < kb end
        return index[a] < index[b]
    end
    for i, e in ipairs(entries) do
        if e.folder then table.sort(e.lists, before) end
    end
    local function first(e) return e.list or e.lists[1] end
    table.sort(entries, function(a, b) return before(first(a), first(b)) end)
    return entries
end

--- Put subtasks right under their parent (when the parent is in the same view).
-- Sets r.depth (0 = top level) on each row. Order is otherwise kept.
function Model.nestSubtasks(rows)
    local present, children, top = {}, {}, {}
    for i, r in ipairs(rows) do present[r.task.id] = true end
    for i, r in ipairs(rows) do
        local pid = r.task.parent_id
        if pid and pid ~= r.task.id and present[pid] then
            children[pid] = children[pid] or {}
            table.insert(children[pid], r)
        else
            top[#top + 1] = r
        end
    end
    local out, seen = {}, {}
    local function add(r, depth)
        if seen[r] then return end
        seen[r] = true
        r.depth = depth
        out[#out + 1] = r
        for i, c in ipairs(children[r.task.id] or {}) do add(c, depth + 1) end
    end
    for i, r in ipairs(top) do add(r, 0) end
    for i, r in ipairs(rows) do add(r, 0) end -- anything caught in a parent loop
    return out
end

--- Does a task mention `query` (any case) in its title, notes or checklist?
function Model.matches(task, query)
    query = (query or ""):lower()
    if query == "" then return false end
    local function has(text)
        return type(text) == "string" and text:lower():find(query, 1, true) ~= nil
    end
    if has(task.title) or has(task.content) or has(task.desc) then return true end
    for i, it in ipairs(task.checklist or {}) do
        if has(it.title) then return true end
    end
    return false
end
function Model.priorityMark(p)
    if p == 5 then return "!!! " elseif p == 3 then return "!! " elseif p == 1 then return "! " end
    return ""
end

local WEEKDAYS = { "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" }
local MONTHS = { "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" }

--- Short label for the right-hand column ("Overdue 2d", "Today 14:30", "Tomorrow", "Fri", "Nov 12").
function Model.dueLabel(info)
    if not info then return "" end
    local time = ""
    if not info.all_day then time = string.format(" %02d:%02d", info.hour, info.min) end
    local dd = info.days_diff
    if dd < 0 then
        if dd == -1 then return "Yesterday" .. time end
        return "Overdue " .. (-dd) .. "d"
    elseif dd == 0 then
        return "Today" .. time
    elseif dd == 1 then
        return "Tomorrow" .. time
    end
    local t = os.date("!*t", info.day * DAY)
    if dd < 7 then return WEEKDAYS[t.wday] .. time end
    return MONTHS[t.month] .. " " .. t.day
end

local NOTES_CAP = 30000

--- Reduce an API task to just the fields we store/show. Also scrubs JSON null sentinels.
-- Notes are kept in full: editing them from a shortened copy would destroy text.
-- Over the cap we flag the task instead, and the editor refuses to touch it.
function Model.slimTask(t, project_name)
    local content, desc = str(t.content), str(t.desc)
    local truncated
    if content and #content > NOTES_CAP then content, truncated = content:sub(1, NOTES_CAP), true end
    if desc and #desc > NOTES_CAP then desc, truncated = desc:sub(1, NOTES_CAP), true end
    local list, subtasks_done, list_cut = Model.checklistFromItems(t.items)
    return {
        id = str(t.id),
        project_id = str(t.projectId),
        project = project_name,
        title = str(t.title) or "(untitled)",
        content = content,
        desc = desc,
        content_truncated = truncated,
        due = str(t.dueDate),
        start = str(t.startDate),
        all_day = t.isAllDay == true,
        priority = num(t.priority) or 0,
        sort_order = num(t.sortOrder) or 0,
        status = num(t.status) or 0,
        subtasks = #list,
        subtasks_done = subtasks_done,
        checklist = list,
        checklist_truncated = list_cut,
        kind = str(t.kind), -- "TEXT" or "CHECKLIST": decides where notes live
        parent_id = str(t.parentId), -- set on subtasks
    }
end

local CHECKLIST_CAP = 200

--- API checklist items -> slim items { id, title, done, status, sort_order, start, all_day, time_zone }.
-- Everything needed to send the list back unchanged is kept; only `done` is ever edited.
-- @return list, number done, boolean cut (more items than we keep: never send such a list back)
function Model.checklistFromItems(items)
    local list, done_n, cut = {}, 0, nil
    if type(items) ~= "table" then return list, 0 end
    for _, it in ipairs(items) do
        if type(it) == "table" and type(it.title) == "string" then
            if #list >= CHECKLIST_CAP then cut = true break end
            local status = num(it.status) or 0
            local done = status == 1
            if done then done_n = done_n + 1 end
            list[#list + 1] = {
                id = str(it.id), title = it.title, done = done, status = status,
                sort_order = num(it.sortOrder), start = str(it.startDate),
                all_day = it.isAllDay == true or nil, time_zone = str(it.timeZone),
            }
        end
    end
    return list, done_n, cut
end

--- Slim checklist -> API `items` array (status 1 = done, 0 = not done).
-- Items added on the device carry a temporary "local:" id until TickTick gives them
-- a real one; Client:updateTask leaves those ids out of the request.
function Model.itemsFromChecklist(list)
    local items = {}
    for i, it in ipairs(list or {}) do
        local status = it.done and 1 or 0
        items[i] = {
            id = it.id, title = it.title, status = status, sortOrder = it.sort_order,
            startDate = it.start, isAllDay = it.all_day, timeZone = it.time_zone,
        }
    end
    return items
end

--- Can this task's checklist be edited safely? (Needs item ids from a recent sync, and the full list.)
function Model.checklistEditable(task)
    if task.checklist_truncated then return false end
    for i, it in ipairs(task.checklist or {}) do
        if not it.id then return false end
    end
    return true
end

--- Which API field holds a task's notes: checklist tasks keep them in `desc`,
-- ordinary tasks in `content`.
function Model.notesField(task)
    if task.kind == "CHECKLIST" then return "desc" end
    if task.kind == "TEXT" then return "content" end
    if (task.subtasks or 0) > 0 then return "desc" end -- cache from before `kind` was kept
    return "content"
end

--- Fields that add a checklist item. A plain task becomes a checklist task, and
-- since TickTick then shows `desc` instead of `content`, its notes are copied over
-- (verified on a live account: items alone switch the kind but leave desc empty).
function Model.addChecklistFields(task, list)
    local fields = { items = Model.itemsFromChecklist(list) }
    if Model.notesField(task) == "content" then
        fields.kind = "CHECKLIST"
        if task.content and task.content ~= "" and (task.desc or "") == "" then
            fields.desc = task.content
        end
    end
    return fields
end

function Model.notesOf(task)
    return task[Model.notesField(task)] or ""
end

--- Cut a UTF-8 string to at most `n` bytes without splitting a character
-- (a split character is drawn as "?").
local function cutUtf8(s, n)
    if #s <= n then return s end
    local b = s:byte(n + 1)
    while n > 0 and b and b >= 0x80 and b < 0xC0 do -- byte n+1 continues a character
        n = n - 1
        b = s:byte(n + 1)
    end
    return s:sub(1, n)
end
Model.cutUtf8 = cutUtf8

--- First non-empty line of some text, shortened to `max` bytes.
function Model.firstLine(text, max)
    for line in (text or ""):gmatch("[^\r\n]+") do
        line = line:gsub("^%s+", ""):gsub("%s+$", "")
        if line ~= "" then
            if #line > max then line = cutUtf8(line, max - 1) .. "…" end
            return line
        end
    end
    return ""
end

--- Repair text from KOReader's JSON decoder, which turns an escaped emoji such as
-- "💼" into two 3-byte halves (CESU-8) instead of one 4-byte UTF-8
-- character. The halves draw as "?" and would upload as invalid text.
-- Halves that have no partner are removed.
function Model.fixSurrogates(s)
    if type(s) ~= "string" or not s:find("\237", 1, true) then return s end
    s = s:gsub("\237([\160-\175])([\128-\191])\237([\176-\191])([\128-\191])", function(a, b, c, d)
        local hi = 0xD000 + (a:byte() - 0x80) * 64 + (b:byte() - 0x80)
        local lo = 0xD000 + (c:byte() - 0x80) * 64 + (d:byte() - 0x80)
        local cp = 0x10000 + (hi - 0xD800) * 1024 + (lo - 0xDC00)
        return string.char(
            0xF0 + math.floor(cp / 262144),
            0x80 + math.floor(cp / 4096) % 64,
            0x80 + math.floor(cp / 64) % 64,
            0x80 + cp % 64)
    end)
    return (s:gsub("\237[\160-\191][\128-\191]", ""))
end

--- fixSurrogates applied to every string inside a decoded JSON value (in place for tables).
function Model.fixTextDeep(v)
    if type(v) == "string" then return Model.fixSurrogates(v) end
    if type(v) == "table" then
        for k, x in pairs(v) do
            if type(x) == "string" or type(x) == "table" then
                v[k] = Model.fixTextDeep(x)
            end
        end
    end
    return v
end

-- Emoji that KOReader's fonts cannot draw (they show as "?").
-- BMP characters that default to colour emoji (Unicode's Emoji_Presentation list).
local EMOJI_BMP = {
    { 0x231A, 0x231B }, { 0x23E9, 0x23EC }, { 0x23F0, 0x23F0 }, { 0x23F3, 0x23F3 },
    { 0x25FD, 0x25FE }, { 0x2614, 0x2615 }, { 0x2648, 0x2653 }, { 0x267F, 0x267F },
    { 0x2693, 0x2693 }, { 0x26A1, 0x26A1 }, { 0x26AA, 0x26AB }, { 0x26BD, 0x26BE },
    { 0x26C4, 0x26C5 }, { 0x26CE, 0x26CE }, { 0x26D4, 0x26D4 }, { 0x26EA, 0x26EA },
    { 0x26F2, 0x26F3 }, { 0x26F5, 0x26F5 }, { 0x26FA, 0x26FA }, { 0x26FD, 0x26FD },
    { 0x2705, 0x2705 }, { 0x270A, 0x270B }, { 0x2728, 0x2728 }, { 0x274C, 0x274C },
    { 0x274E, 0x274E }, { 0x2753, 0x2755 }, { 0x2757, 0x2757 }, { 0x2795, 0x2797 },
    { 0x27B0, 0x27B0 }, { 0x27BF, 0x27BF }, { 0x2B1B, 0x2B1C }, { 0x2B50, 0x2B50 },
    { 0x2B55, 0x2B55 },
}

local function isEmoji(cp)
    if cp >= 0x1F000 and cp <= 0x1FAFF then return true end -- pictographs, flags, skin tones
    if cp >= 0xE0000 and cp <= 0xE007F then return true end -- flag tag sequences
    if cp == 0x200D or cp == 0xFE0E or cp == 0xFE0F or cp == 0x20E3 then return true end -- joiners, style marks, keycaps
    if cp == 0xFFFC then return true end -- placeholder left where an image or link was pasted
    for i = 1, #EMOJI_BMP do
        local r = EMOJI_BMP[i]
        if cp >= r[1] and cp <= r[2] then return true end
    end
    return false
end

-- Split a UTF-8 string into { {cp, bytes}, ... }. Invalid bytes keep cp = nil.
local function decodeUtf8(s)
    local out, i, n = {}, 1, #s
    while i <= n do
        local c = s:byte(i)
        local len, cp = 1, nil
        if c < 0x80 then cp = c
        elseif c >= 0xF0 and c < 0xF8 then len, cp = 4, c - 0xF0
        elseif c >= 0xE0 then len, cp = 3, c - 0xE0
        elseif c >= 0xC0 then len, cp = 2, c - 0xC0
        end
        if len > 1 then
            for k = 1, len - 1 do
                local cc = s:byte(i + k)
                if not cc or cc < 0x80 or cc >= 0xC0 then len, cp = 1, nil break end
                cp = cp * 64 + (cc - 0x80)
            end
        end
        out[#out + 1] = { cp, s:sub(i, i + len - 1) }
        i = i + len
    end
    return out
end

--- A name or title as it should be drawn on the Kindle: emoji the fonts cannot
-- draw are removed, as is any character marked to show as emoji (followed by U+FE0F).
-- Falls back to the original text if nothing would be left.
function Model.displayName(s)
    if type(s) ~= "string" then return "" end
    if not s:find("[\128-\255]") then return s end -- plain ASCII: nothing to do
    s = Model.fixSurrogates(s)
    local chars = decodeUtf8(s)
    local kept = {}
    for idx = 1, #chars do
        local cp = chars[idx][1]
        local nxt = chars[idx + 1] and chars[idx + 1][1]
        if not (cp and (isEmoji(cp) or nxt == 0xFE0F)) then
            kept[#kept + 1] = chars[idx][2]
        end
    end
    local out = table.concat(kept):gsub("%s%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
    if out == "" then return s end
    return out
end

function Model.priorityName(p)
    if p == 5 then return "High" elseif p == 3 then return "Medium" elseif p == 1 then return "Low" end
    return "None"
end

-- Map slim fields back to what dueInfo expects.
local function asDueTask(t)
    return { dueDate = t.due, startDate = t.start, isAllDay = t.all_day }
end

--- Choose and order the tasks to display.
-- @param mode  "today" (overdue + today), "tomorrow", "week" (overdue .. +6 days), "all",
--              or a table {kind = "project", project_id = id} for every task in one list.
--              A table may also carry kind = "today" etc.
-- @param skip table of task ids to hide (completions waiting to upload)
-- @param excluded table project_id -> true for projects the user switched off
function Model.visibleTasks(tasks, mode, now, offset_min, skip, excluded)
    skip, excluded = skip or {}, excluded or {}
    local kind, wanted_project = mode, nil
    if type(mode) == "table" then kind, wanted_project = mode.kind, mode.project_id end
    local out = {}
    for _, t in ipairs(tasks or {}) do
        if t.id and t.status == 0 and not skip[t.id] and not excluded[t.project_id or ""] then
            local info = Model.dueInfo(asDueTask(t), now, offset_min)
            local keep
            if kind == "all" then
                keep = true
            elseif kind == "project" then
                keep = t.project_id == wanted_project
            elseif kind == "search" then
                keep = Model.matches(t, mode.query)
            elseif not info then
                keep = false
            elseif kind == "week" then
                keep = info.days_diff <= 6
            elseif kind == "tomorrow" then
                keep = info.days_diff == 1
            else
                keep = info.days_diff <= 0
            end
            if keep then
                local tier = 3
                if info then tier = info.days_diff < 0 and 0 or (info.days_diff == 0 and 1 or 2) end
                out[#out + 1] = { task = t, info = info, tier = tier }
            end
        end
    end
    -- Order: overdue, today, later, undated; within a day all-day items come first,
    -- then timed ones by time; then priority (high first), manual order, title.
    table.sort(out, function(a, b)
        if a.tier ~= b.tier then return a.tier < b.tier end
        if a.tier < 3 then
            if a.info.day ~= b.info.day then return a.info.day < b.info.day end
            if a.info.all_day ~= b.info.all_day then return a.info.all_day end
            if not a.info.all_day and a.info.epoch ~= b.info.epoch then
                return a.info.epoch < b.info.epoch
            end
        end
        if a.task.priority ~= b.task.priority then return a.task.priority > b.task.priority end
        if a.task.sort_order ~= b.task.sort_order then return a.task.sort_order < b.task.sort_order end
        return a.task.title:lower() < b.task.title:lower()
    end)
    return out
end

return Model
