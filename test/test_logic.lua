-- Unit tests for ticktick_model.lua and ticktick_client.lua (no KOReader needed).
local Model = require("ticktick_model")
local Client = require("ticktick_client")
local mocks = require("mocks")

local failures, passed = 0, 0
local function check(name, cond, detail)
    if cond then
        passed = passed + 1
    else
        failures = failures + 1
        print("FAIL: " .. name .. (detail and (" -- " .. tostring(detail)) or ""))
    end
end
local function eq(name, got, want) check(name, got == want, "got " .. tostring(got) .. ", want " .. tostring(want)) end

-- ---- dates ---------------------------------------------------------------
eq("epoch day 0", Model.daysFromCivil(1970, 1, 1), 0)
eq("2026-11-04", Model.daysFromCivil(2026, 11, 4), EXPECT_DAYS_2026_11_04)
eq("leap day", Model.daysFromCivil(2024, 3, 1) - Model.daysFromCivil(2024, 2, 28), 2)

local base = Model.daysFromCivil(2026, 11, 4) * 86400
eq("parse +0000", Model.parseTimestamp("2026-11-04T05:00:00.000+0000"), base + 5 * 3600)
eq("parse +05:30", Model.parseTimestamp("2026-11-04T05:00:00+05:30"), base + 5 * 3600 - 330 * 60)
eq("parse -0500", Model.parseTimestamp("2026-11-04T05:00:00.000-0500"), base + 10 * 3600)
eq("parse Z", Model.parseTimestamp("2026-11-04T05:00:00Z"), base + 5 * 3600)
eq("parse date only", Model.parseTimestamp("2026-11-04"), base)
eq("parse garbage", Model.parseTimestamp("tomorrow"), nil)
eq("parse json null", Model.parseTimestamp(mocks.json.null), nil)

-- Device offset follows the process TZ (America/New_York set by the runner).
eq("offset winter", Model.deviceOffsetMinutes(base + 12 * 3600), -300)
eq("offset summer", Model.deviceOffsetMinutes(Model.daysFromCivil(2026, 7, 4) * 86400 + 12 * 3600), -240)

-- ---- due classification ---------------------------------------------------
-- "now" = 2026-11-04 13:25 UTC = 08:25 EST
local now = base + 13 * 3600 + 25 * 60
local EST = -300
local function due(d, all_day, off) return Model.dueInfo({ dueDate = d, isAllDay = all_day }, now, off or EST) end

eq("all-day today (EST midnight)", due("2026-11-04T05:00:00.000+0000", true).days_diff, 0)
eq("all-day yesterday", due("2026-11-03T05:00:00.000+0000", true).days_diff, -1)
eq("all-day tomorrow", due("2026-11-05T05:00:00.000+0000", true).days_diff, 1)
eq("all-day set under EDT, viewed in EST", due("2026-11-03T04:00:00.000+0000", true).days_diff, -1)
eq("all-day Tokyo user, device in Tokyo", due("2026-11-03T15:00:00.000+0000", true, 540).days_diff,
    Model.dueInfo({ dueDate = "2026-11-03T15:00:00.000+0000", isAllDay = true }, now, 540).days_diff)
do
    -- In Tokyo (UTC+9) it is 22:25 on Nov 4 at "now"; an all-day Nov 4 task is stored as Nov 3 15:00 UTC.
    local d = Model.dueInfo({ dueDate = "2026-11-03T15:00:00.000+0000", isAllDay = true }, now, 540)
    eq("all-day Tokyo = today", d.days_diff, 0)
end
do
    local d = Model.dueInfo({ dueDate = "2026-11-04T00:00:00.000+0900", isAllDay = true }, now, EST)
    eq("all-day with explicit offset uses written date", d.days_diff, 0)
end
local timed = due("2026-11-04T19:30:00.000+0000", false)
eq("timed today", timed.days_diff, 0)
eq("timed hour", timed.hour, 14)
eq("timed min", timed.min, 30)
eq("late-evening local stays today", due("2026-11-05T03:30:00.000+0000", false).days_diff, 0)
eq("undated", Model.dueInfo({}, now, EST), nil)
eq("json-null due is undated", Model.dueInfo({ dueDate = mocks.json.null }, now, EST), nil)

-- ---- labels ---------------------------------------------------------------
eq("label today timed", Model.dueLabel(timed), "Today 14:30")
eq("label today all-day", Model.dueLabel(due("2026-11-04T05:00:00.000+0000", true)), "Today")
eq("label tomorrow", Model.dueLabel(due("2026-11-05T05:00:00.000+0000", true)), "Tomorrow")
eq("label yesterday", Model.dueLabel(due("2026-11-03T05:00:00.000+0000", true)), "Yesterday")
eq("label overdue", Model.dueLabel(due("2026-11-01T05:00:00.000+0000", true)), "Overdue 3d")
eq("label weekday", Model.dueLabel(due("2026-11-07T05:00:00.000+0000", true)), "Sat")
eq("label far", Model.dueLabel(due("2026-11-20T05:00:00.000+0000", true)), "Nov 20")
eq("label none", Model.dueLabel(nil), "")
eq("prio high", Model.priorityMark(5), "!!! ")
eq("prio none", Model.priorityMark(0), "")

-- ---- slimTask -------------------------------------------------------------
local slim = Model.slimTask({
    id = "t1", projectId = "p1", title = "Pay rent", content = mocks.json.null, dueDate = "2026-11-04T05:00:00.000+0000",
    isAllDay = true, priority = 5, sortOrder = -100, status = 0,
    items = { { title = "a", status = 1 }, { title = "b", status = 0 }, { title = "c", status = 0 } },
}, "Home")
eq("slim title", slim.title, "Pay rent")
eq("slim null content", slim.content, nil)
eq("slim subtasks", slim.subtasks, 3)
eq("slim subtasks done", slim.subtasks_done, 1)
eq("slim project", slim.project, "Home")
eq("slim untitled", Model.slimTask({ id = "x" }).title, "(untitled)")
-- Notes are stored whole (editing a shortened copy would destroy text); only absurd sizes are flagged.
local long = Model.slimTask({ id = "x", content = string.rep("a", 2000) })
eq("long notes kept whole", #long.content, 2000)
eq("long notes not flagged", long.content_truncated, nil)
local huge = Model.slimTask({ id = "x", content = string.rep("a", 40000) })
eq("huge notes flagged", huge.content_truncated, true)
eq("huge notes capped", #huge.content, 30000)

-- checklist items and which field holds the notes
local cl = Model.slimTask({ id = "c", content = "plain", desc = "checklist note",
    items = { { title = "Draft", status = 1 }, { title = "Send", status = 0 }, mocks.json.null } })
eq("checklist count", cl.subtasks, 2)
eq("checklist first title", cl.checklist[1].title, "Draft")
eq("checklist first done", cl.checklist[1].done, true)
eq("checklist second done", cl.checklist[2].done, false)
eq("checklist task keeps notes in desc", Model.notesField(cl), "desc")
eq("checklist notes text", Model.notesOf(cl), "checklist note")
local plain = Model.slimTask({ id = "p", content = "plain" })
eq("plain task keeps notes in content", Model.notesField(plain), "content")
eq("plain notes text", Model.notesOf(plain), "plain")
eq("no notes -> empty string", Model.notesOf(Model.slimTask({ id = "n" })), "")
eq("firstLine skips blanks", Model.firstLine("\n  \n  hello world \nsecond", 40), "hello world")
eq("firstLine shortens", Model.firstLine("abcdefghij", 5), "abcd…")
eq("firstLine empty", Model.firstLine(nil, 5), "")
eq("priority names", Model.priorityName(5) .. Model.priorityName(3) .. Model.priorityName(1) .. Model.priorityName(0),
    "HighMediumLowNone")

-- ---- visibleTasks ---------------------------------------------------------
local function task(id, title, dueDate, all_day, prio, sort, pid)
    return { id = id, project_id = pid or "p1", title = title, due = dueDate, all_day = all_day or false,
             priority = prio or 0, sort_order = sort or 0, status = 0, subtasks = 0, subtasks_done = 0 }
end
local tasks = {
    task("a", "Overdue low", "2026-11-02T05:00:00.000+0000", true, 1),
    task("b", "Today timed late", "2026-11-04T22:00:00.000+0000", false, 0),
    task("c", "Today all-day high", "2026-11-04T05:00:00.000+0000", true, 5),
    task("d", "Today all-day none", "2026-11-04T05:00:00.000+0000", true, 0, 5),
    task("e", "Today timed early", "2026-11-04T14:00:00.000+0000", false, 0),
    task("f", "Tomorrow", "2026-11-05T05:00:00.000+0000", true),
    task("g", "Next week", "2026-11-12T05:00:00.000+0000", true),
    task("h", "No date", nil),
    task("i", "Overdue older", "2026-10-30T05:00:00.000+0000", true),
    task("j", "Other list today", "2026-11-04T05:00:00.000+0000", true, 0, 0, "p2"),
}
local function ids(rows) local t = {} for i, r in ipairs(rows) do t[i] = r.task.id end return table.concat(t, ",") end
eq("today order", ids(Model.visibleTasks(tasks, "today", now, EST)), "i,a,c,j,d,e,b")
eq("week includes tomorrow", ids(Model.visibleTasks(tasks, "week", now, EST)), "i,a,c,j,d,e,b,f")
eq("all includes undated last", ids(Model.visibleTasks(tasks, "all", now, EST)), "i,a,c,j,d,e,b,f,g,h")
eq("skip pending", ids(Model.visibleTasks(tasks, "today", now, EST, { c = true })), "i,a,j,d,e,b")
eq("exclude project", ids(Model.visibleTasks(tasks, "today", now, EST, nil, { p2 = true })), "i,a,c,d,e,b")
eq("tomorrow view", ids(Model.visibleTasks(tasks, "tomorrow", now, EST)), "f")
eq("table mode works like string", ids(Model.visibleTasks(tasks, { kind = "today", title = "x" }, now, EST)), "i,a,c,j,d,e,b")
eq("project view lists everything in that list", ids(Model.visibleTasks(tasks, { kind = "project", project_id = "p2" }, now, EST)), "j")
eq("project view includes undated", ids(Model.visibleTasks(tasks, { kind = "project", project_id = "p1" }, now, EST)),
    "i,a,c,d,e,b,f,g,h")
eq("nil task list", #Model.visibleTasks(nil, "today", now, EST), 0)
do
    local done = task("z", "done", "2026-11-04T05:00:00.000+0000", true)
    done.status = 2
    eq("completed hidden", #Model.visibleTasks({ done }, "all", now, EST), 0)
end

-- ---- client ---------------------------------------------------------------
local function fakeTransport(routes)
    local log = {}
    local fn = function(method, url, headers, body)
        log[#log + 1] = { method = method, url = url, headers = headers, body = body }
        local r = routes[method .. " " .. url:gsub("^https://api.ticktick.com/open/v1", "")]
        if r == nil then return 404, "" end
        if type(r) == "function" then return r(headers, body) end
        return r[1], r[2]
    end
    return fn, log
end
local json = mocks.json
local transport, log = fakeTransport({
    ["GET /project"] = { 200, json.encode({
        { id = "p1", name = "Work", kind = "TASK" },
        { id = "p2", name = "Archive", closed = true },
        { id = "p3", name = "Notes", kind = "NOTE" },
        { id = "p4", name = "Home" },
    }) },
    ["GET /project/p1/data"] = { 200, json.encode({ tasks = { { id = "t1", projectId = "p1", title = "One", status = 0 } } }) },
    ["GET /project/p4/data"] = { 500, "boom" },
    ["GET /project/inbox9/data"] = { 200, json.encode({ tasks = { { id = "t9", title = "In inbox", status = 0 } } }) },
    ["POST /project/p1/task/t1/complete"] = { 200, "" },
})
local c = Client:new{ base_url = "https://api.ticktick.com/open/v1/", token = "tok", transport = transport, json = json }
local projects = c:listProjects()
eq("closed + notes filtered", #projects, 2)
local all, plist, failed = c:fetchAll({}, { "inbox9" })
eq("fetchAll tasks", all and #all, 2)
eq("fetchAll failed count", failed, 1)
eq("fetchAll inbox project id filled", all and all[2].project_id, "inbox9")
eq("auth header", log[1].headers.Authorization, "Bearer tok")
eq("trailing slash trimmed", log[1].url, "https://api.ticktick.com/open/v1/project")
local skipped = c:fetchAll({ p4 = true }, {})
eq("skip project", skipped and #skipped, 1)
eq("complete ok", c:completeTask("p1", "t1"), true)
local ok, kind, detail = c:completeTask("p1", "nope")
eq("complete 404 kind", kind, "http")
eq("complete 404 code", detail, 404)

-- getTask / updateTask
local seen_body
local c7 = Client:new{ base_url = "https://x/open/v1", token = "tok", json = json, transport = function(method, url, headers, body)
    if method == "GET" and url == "https://x/open/v1/project/p1/task/t1" then
        return 200, json.encode({ id = "t1", projectId = "p1", title = "Fresh", content = "newest notes", status = 0 })
    elseif method == "POST" and url == "https://x/open/v1/task/t1" then
        seen_body = json.decode(body)
        eq("update sends exact length", headers["Content-Length"], tostring(#body))
        eq("update content type", headers["Content-Type"], "application/json")
        return 200, body
    end
    return 404, ""
end }
local fresh = c7:getTask("p1", "t1")
eq("getTask title", fresh and fresh.title, "Fresh")
eq("getTask notes", fresh and fresh.content, "newest notes")
local _, gk, gd = c7:getTask("p1", "gone")
eq("getTask 404", gd, 404)
eq("updateTask ok", c7:updateTask("p1", "t1", { title = "New", content = "Body\nline 2" }) ~= nil, true)
eq("update body id", seen_body.id, "t1")
eq("update body projectId", seen_body.projectId, "p1")
eq("update body title", seen_body.title, "New")
eq("update body notes keep newline", seen_body.content, "Body\nline 2")
eq("update only sends named fields", seen_body.priority, nil)

local c2 = Client:new{ token = "x", json = json, transport = function() return 401, "" end }
local _, k2 = c2:listProjects()
eq("401 -> auth", k2, "auth")
local c3 = Client:new{ token = "x", json = json, transport = function() return nil, "timeout" end }
local _, k3, d3 = c3:listProjects()
eq("transport nil -> network", k3, "network")
eq("network detail", d3, "timeout")
local c4 = Client:new{ token = "x", json = json, transport = function() return 200, "<html>captive portal</html>" end }
local _, k4 = c4:listProjects()
eq("html -> json error", k4, "json")
local c5 = Client:new{ token = "", json = json, transport = function() error("must not be called") end }
local _, k5 = c5:listProjects()
eq("no token -> auth without request", k5, "auth")
local _, k6 = Client:new{ token = "x", json = json, transport = function() return nil, "dns" end }:fetchAll({}, {})
eq("fetchAll aborts on network", k6, "network")

-- ---- names drawn on the Kindle: emoji the fonts cannot draw are removed ----
eq("plain name untouched", Model.displayName("Work"), "Work")
eq("accented letters kept", Model.displayName("Café Señor"), "Café Señor")
eq("CJK kept", Model.displayName("買い物"), "買い物")
eq("leading pictograph", Model.displayName("\240\159\147\154 Reading"), "Reading") -- U+1F4DA books
eq("trailing pictograph", Model.displayName("Gym \240\159\143\139\239\184\143"), "Gym") -- U+1F3CB + FE0F
eq("emoji in the middle", Model.displayName("Buy \240\159\165\155 milk"), "Buy milk") -- U+1F95B
eq("BMP emoji (check mark button)", Model.displayName("\226\156\133 Done"), "Done") -- U+2705
eq("BMP emoji (star)", Model.displayName("\226\173\144 Favourites"), "Favourites") -- U+2B50
eq("symbol marked as emoji", Model.displayName("\226\157\164\239\184\143 Family"), "Family") -- U+2764 + FE0F
eq("plain symbol kept", Model.displayName("\226\152\133 Starred"), "\226\152\133 Starred") -- U+2605, no FE0F
eq("flag", Model.displayName("\240\159\135\186\240\159\135\184 Trip"), "Trip") -- regional indicators U S
eq("joined family emoji", Model.displayName("Kids \240\159\145\168\226\128\141\240\159\145\167"), "Kids") -- man ZWJ girl
eq("keycap", Model.displayName("1\239\184\143\226\131\163 First"), "First")
eq("skin tone", Model.displayName("\240\159\145\141\240\159\143\189 Ok"), "Ok")
eq("emoji only falls back to original", Model.displayName("\240\159\147\154"), "\240\159\147\154")
eq("non-string", Model.displayName(nil), "")
eq("pasted-object placeholder hidden", Model.displayName("Read this \239\191\188"), "Read this") -- U+FFFC
eq("cut keeps whole characters", Model.cutUtf8("ab\195\169cd", 3), "ab") -- é is 2 bytes
eq("cut on a boundary", Model.cutUtf8("ab\195\169cd", 4), "ab\195\169")
eq("first line never splits a character", Model.firstLine("\195\169\195\169\195\169", 4), "\195\169…")

-- ---- KOReader's JSON decoder splits emoji into two broken halves (CESU-8) ----
local BRIEFCASE_CESU, BRIEFCASE = "\237\160\189\237\178\188", "\240\159\146\188" -- U+1F4BC
eq("halves joined into one character", Model.fixSurrogates(BRIEFCASE_CESU .. "My Work"), BRIEFCASE .. "My Work")
eq("text without halves untouched", Model.fixSurrogates("Caf\195\169"), "Caf\195\169")
eq("lone half removed", Model.fixSurrogates("a\237\160\189b"), "ab")
eq("broken emoji hidden on screen", Model.displayName(BRIEFCASE_CESU .. "My Work"), "My Work")
local man_cesu = "\237\160\189\237\177\168\226\128\141\226\153\130\239\184\143" -- man ZWJ male-sign FE0F
eq("joined sequence hidden on screen", Model.displayName(man_cesu .. "Personal"), "Personal")
local decoded = { tasks = { { title = BRIEFCASE_CESU .. " x", items = { { title = BRIEFCASE_CESU } } } }, n = 3 }
Model.fixTextDeep(decoded)
eq("deep fix: nested title", decoded.tasks[1].title, BRIEFCASE .. " x")
eq("deep fix: checklist item", decoded.tasks[1].items[1].title, BRIEFCASE)
eq("deep fix: numbers untouched", decoded.n, 3)
local cesu_client = Client:new{ token = "x", json = json, transport = function()
    return 200, '[{"id":"p1","name":"\\ud83d\\udcbcWork"}]' end }
local cesu_json = { decode = function() return { { id = "p1", name = BRIEFCASE_CESU .. "Work" } } end, encode = json.encode }
cesu_client.json = cesu_json
eq("client repairs what the decoder returns", cesu_client:listProjects()[1].name, BRIEFCASE .. "Work")

-- ---- editing due dates ----
local f1 = Model.dueFields(2026, 11, 25, nil, nil, -300) -- Ohio winter, UTC-5
eq("all-day due = local midnight in UTC", f1.dueDate, "2026-11-25T05:00:00.000+0000")
eq("start equals due", f1.startDate, f1.dueDate)
eq("all-day flag", f1.isAllDay, true)
local f2 = Model.dueFields(2026, 11, 25, 22, 30, -300)
eq("timed due crosses into the next UTC day", f2.dueDate, "2026-11-26T03:30:00.000+0000")
eq("timed flag", f2.isAllDay, false)
local now25 = Model.daysFromCivil(2026, 11, 25) * 86400 + 15 * 3600
local round = Model.dueInfo(f1, now25, -300)
eq("round trip: all-day lands on the picked day", round.days_diff, 0)
local round2 = Model.dueInfo(f2, now25, -300)
eq("round trip: timed keeps the local day", round2.days_diff, 0)
eq("round trip: timed keeps the time", round2.hour .. ":" .. round2.min, "22:30")
local parts = Model.dueParts({ due = f2.dueDate, all_day = false }, now25, -300)
eq("parts: local date", parts.year .. "-" .. parts.month .. "-" .. parts.day, "2026-11-25")
eq("parts: time", parts.hour, 22)
local none = Model.dueParts({}, now25, -300)
eq("parts: undated starts today", none.day, 25)
eq("parts: undated has no due", none.has_due, false)
local slim = { title = "x", due = "old", start = "old", all_day = false, priority = 0 }
Model.applyFields(slim, f1)
eq("applyFields maps dueDate", slim.due, f1.dueDate)
eq("applyFields maps isAllDay", slim.all_day, true)
Model.applyFields(slim, Model.clearDueFields())
eq("cleared due is nil locally", slim.due, nil)
Model.applyFields(slim, { priority = 3, title = "y" })
eq("plain fields keep their names", slim.priority .. slim.title, "3y")

-- ---- checklist round trip ----
local api_items = { { id = "a", title = "One", status = 0, sortOrder = 5, startDate = "2026-11-25T05:00:00.000+0000", isAllDay = true, timeZone = "America/New_York" },
                    { id = "b", title = "Two", status = 1, sortOrder = 6 } }
local cl, cl_done = Model.checklistFromItems(api_items)
eq("items kept", #cl, 2)
eq("done count", cl_done, 1)
eq("done flag", cl[2].done, true)
local back = Model.itemsFromChecklist(cl)
eq("round trip: id", back[1].id, "a")
eq("round trip: status", back[2].status, 1)
eq("round trip: sort order", back[1].sortOrder, 5)
eq("round trip: item date", back[1].startDate, "2026-11-25T05:00:00.000+0000")
eq("round trip: all-day", back[1].isAllDay, true)
eq("round trip: time zone", back[1].timeZone, "America/New_York")
eq("round trip: no invented fields", back[2].startDate, nil)
check("editable with ids", Model.checklistEditable({ checklist = cl }))
check("not editable without ids", not Model.checklistEditable({ checklist = { { title = "x" } } }))
local many = {}
for i = 1, 205 do many[i] = { id = "x" .. i, title = "t" .. i, status = 0 } end
local slim_many = Model.slimTask({ id = "t", title = "Big", items = many })
eq("long checklist capped", #slim_many.checklist, 200)
eq("long checklist flagged", slim_many.checklist_truncated, true)
check("long checklist not editable", not Model.checklistEditable(slim_many))
local tk = { checklist = {}, subtasks = 0 }
Model.applyFields(tk, { items = api_items })
eq("applyFields items -> checklist", #tk.checklist, 2)
eq("applyFields items -> subtasks", tk.subtasks, 2)

-- ---- list order and folders (shaped like a real account) ----
local real = {
    { id = "mywork", name = "My Work", group_id = "g1", sort_order = 320690891434 },
    { id = "personal", name = "Personal", sort_order = -8070451872265207368 },
    { id = "content", name = "Content", sort_order = -8070451717646384712 },
    { id = "misc", name = "Miscellaneous", sort_order = -8070451862601530952 },
    { id = "tcs", name = "TCS", group_id = "g1", sort_order = 366503875924 },
    { id = "planner", name = "Work.Planner", sort_order = 0 },
    { id = "newjob", name = "New Job", group_id = "g1", sort_order = 297784399189 },
    { id = "tech", name = "tech2do", sort_order = 2338609692671 },
    { id = "inbox1", name = "Inbox", extra = true },
}
local order = Model.orderProjects(real)
local flat = {}
for i, e in ipairs(order) do
    if e.list then flat[#flat + 1] = e.list.name
    else
        local names = {}
        for j, p in ipairs(e.lists) do names[#names + 1] = p.name end
        flat[#flat + 1] = "[" .. table.concat(names, ",") .. "]"
    end
end
eq("sidebar order: by sortOrder, folder where its first list is",
    table.concat(flat, "|"), "Personal|Miscellaneous|Content|Work.Planner|[New Job,My Work,TCS]|tech2do")
local old_cache = Model.orderProjects({ { id = "b", name = "B" }, { id = "a", name = "A" }, { id = "c", name = "C" } })
eq("old cache without sortOrder keeps its order", old_cache[1].list.name .. old_cache[2].list.name .. old_cache[3].list.name, "BAC")
eq("Inbox is not listed", #Model.orderProjects({ { id = "i", name = "Inbox", extra = true } }), 0)

-- ---- search ----
local st = { title = "Call the Bank", content = "about the loan", checklist = { { title = "Passport copy" } } }
check("search: title, any case", Model.matches(st, "bank"))
check("search: notes", Model.matches(st, "LOAN"))
check("search: checklist", Model.matches(st, "passport"))
check("search: no match", not Model.matches(st, "dentist"))
check("search: empty query matches nothing", not Model.matches(st, ""))
check("search: special characters are plain text", not Model.matches(st, "b.nk"))
local searched = Model.visibleTasks({ { id = "1", title = "Bank", status = 0, priority = 0, sort_order = 0 },
    { id = "2", title = "Milk", status = 0, priority = 0, sort_order = 0 } }, { kind = "search", query = "bank" }, now25, -300)
eq("search mode filters", #searched, 1)

print(string.format("logic tests: %d passed, %d failed", passed, failures))
return failures
