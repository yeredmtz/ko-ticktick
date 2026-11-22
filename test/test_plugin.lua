-- Scenario tests for main.lua against mocked KOReader widgets and a fake TickTick server.
local mocks = require("mocks")
mocks.install()
mocks.settings_dir = TEST_TMPDIR

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
local function has(name, haystack, needle)
    check(name, type(haystack) == "string" and haystack:find(needle, 1, true) ~= nil,
        "'" .. tostring(needle) .. "' not in '" .. tostring(haystack) .. "'")
end

-- ---- fake account ---------------------------------------------------------
local now = os.time()
local midnight = math.floor(now / 86400) * 86400
local function iso(t) return os.date("!%Y-%m-%dT%H:%M:%S.000+0000", t) end
local null = mocks.json.null

local function raw(id, pid, title, due, all_day, prio, items)
    return { id = id, projectId = pid, title = title, dueDate = due or null, isAllDay = all_day or false,
             priority = prio or 0, status = 0, sortOrder = 0, content = null, desc = null,
             items = items or null }
end
local server = mocks.newServer{
    projects = { { id = "work", name = "Work" }, { id = "home", name = "Home" },
                 { id = "read", name = "\240\159\147\154 Reading" } }, -- U+1F4DA books emoji
    tasks = {
        work = {
            raw("w1", "work", "Ship report", iso(midnight), true, 5,
                { { title = "Draft", status = 1 }, { title = "Send", status = 0 } }),
            raw("w2", "work", "Overdue invoice", iso(midnight - 2 * 86400), true, 0),
            raw("w3", "work", "Standup notes", iso(midnight + 10 * 3600), false, 0),
            raw("w4", "work", "Plan next quarter", iso(midnight + 5 * 86400), true, 0),
        },
        home = {
            raw("h1", "home", "Buy milk", iso(midnight), true, 0),
            raw("h2", "home", "Someday", nil),
        },
        read = {},
        inbox9 = {
            raw("i1", "inbox9", "Inbox thing", nil),
        },
    },
}
mocks.server = server

-- Config as get_token.py would write it (offset pinned so "today" is deterministic).
local cfg = assert(io.open(TEST_TMPDIR .. "/ticktick.lua", "w"))
cfg:write('return { ["access_token"] = "good-token", ["utc_offset_minutes"] = 0, ["extra_project_ids"] = { "inbox9" } }\n')
cfg:close()

local TickTick = require("main")
local registered
local plugin = TickTick:new{ ui = { menu = { registerToMainMenu = function(_, p) registered = p end } } }
eq("registered with main menu", registered, plugin)

local function menu() return mocks.find("menu") end
local function visible() -- task titles on the top menu, in order
    local out = {}
    for i, it in ipairs(menu().item_table) do
        if it.task then out[#out + 1] = it.task.title end
    end
    return table.concat(out, "|")
end
local function taskRow(title)
    for i, it in ipairs(menu().item_table) do
        if it.task and it.task.title == title then return i end
    end
end
local function drawer() -- the sidebar, if open
    for i = #mocks.shown, 1, -1 do
        if mocks.shown[i].kind == "menu" and mocks.shown[i].covers_fullscreen == false then return mocks.shown[i] end
    end
end
local function drawerIndex(d, name)
    for i, it in ipairs(d.item_table) do -- rows are "<icon>  <name>"; the Lists header has no icon
        if it.text == name or it.text:sub(-(#name + 2)) == "  " .. name then return i end
    end
end
local function count(d, name) -- the task count shown next to a list in the sidebar
    local i = drawerIndex(d, name)
    return i and d.item_table[i].mandatory
end
local function openDrawer() -- tap the menu button at the top left of the task list
    local l = menu()
    eq("list has the menu button", l.title_bar_left_icon, "appbar.menu")
    l:onLeftButtonTap()
    return drawer()
end
-- Icons the plugin puts in front of rows (Font Awesome, from KOReader's symbols font)
local BOX, BOX_DONE = "\239\130\150  ", "\239\129\134  "
local NOTES, CHECK = "\239\131\182  ", "\239\128\140  "
local ON_BOX, OFF_BOX = { x = 0.05, y = 0.5 }, { x = 0.5, y = 0.5 } -- where in a row a tap lands
local function closeWidget(w) -- what KOReader does after a dialog button runs
    for i = #mocks.shown, 1, -1 do if mocks.shown[i] == w then table.remove(mocks.shown, i) end end
end
local function button(dialog, label) -- a ButtonDialog button whose text contains `label`
    for r, row in ipairs(dialog.buttons) do
        for c, b in ipairs(row) do
            if b.text:find(label, 1, true) then return b end
        end
    end
end
-- Hold a task row, choose Complete in the menu, then OK on the Undo box.
local function holdComplete(l, title)
    for i, it in ipairs(l.item_table) do
        if it.task and it.task.title == title then l:hold(i) break end
    end
    button(mocks.top(), "Complete").callback()
    local box = mocks.top()
    box.ok_callback()
    closeWidget(box)
end
local function lastInfo()
    local w = mocks.find("info")
    return w and w.text
end
local function submit(dialog, text) -- the Save button of a plain input dialog
    dialog.input = text
    dialog.buttons[1][2].callback()
end

-- ---- main menu: one entry, straight to the home screen -----------------------------
local items = {}
plugin:addToMainMenu(items)
check("menu entry exists", items.ticktick ~= nil)
eq("menu hint", items.ticktick.sorting_hint, "tools")
eq("no submenu (one tap from Tools)", items.ticktick.sub_item_table, nil)
check("menu entry opens directly", type(items.ticktick.callback) == "function")

-- ---- first open: no sync, shows the cache (empty) and offers Sync ----------------------
items.ticktick.callback(nil)
local list = menu()
check("a list opens without syncing", list ~= nil)
eq("nothing requested on open", #mocks.requests, 0)
eq("starts on Today", list.title, "Today (0)")
has("sync row first", list.item_table[1].text, "Sync now (last: never)")
has("add row second", list.item_table[2].text, "Add task")
has("says nothing downloaded", list.item_table[3].text, "Nothing downloaded yet")
eq("no 'No tasks' row before any sync", mocks.rowIndex(list, "No tasks here"), nil)
eq("no stray info boxes", mocks.find("info"), nil)

-- ---- the sidebar ---------------------------------------------------------------------------
local side = openDrawer()
check("sidebar opens from the menu button", side ~= nil)
eq("sidebar pinned to the left edge", side.shown_at.x, 0)
eq("sidebar covers part of the screen", side.width, 800)
eq("sidebar is full height", side.height, 1400)
eq("sidebar closes on a tap outside", side.is_popout, true)
has("sidebar sync row", side.item_table[1].text, "Sync now (last: never)")
side:tap(1) -- Sync
check("sync made requests", #mocks.requests > 0)
check("sidebar stays open after sync", drawer() == side)
has("sidebar sync row updated", side.item_table[1].text, "Sync now (last:")
check("sidebar no longer says never", not side.item_table[1].text:find("never", 1, true))
eq("list behind refreshed after sync", list.title, "Today (4)")
eq("search row second", side.item_table[2].text, "\239\128\130  Search")
eq("inbox row has the inbox icon", side.item_table[3].text, "\239\128\156  Inbox")
eq("today row has its icon", side.item_table[drawerIndex(side, "Today")].text, "\239\137\180  Today")
eq("lists have the list icon", side.item_table[drawerIndex(side, "Work")].text, "\239\128\186  Work")
has("sync row has the refresh icon", side.item_table[1].text, "\239\128\161  Sync now")
has("settings row has the gear icon", side.item_table[drawerIndex(side, "Settings")].text, "\239\128\147  ")
eq("inbox count", count(side, "Inbox"), "1")
eq("today count", count(side, "Today"), "4")
eq("tomorrow count", count(side, "Tomorrow"), "0")
eq("week count", count(side, "Next 7 days"), "5")
eq("all count", count(side, "All tasks"), "7")
eq("list Work", count(side, "Work"), "4")
eq("list Home", count(side, "Home"), "2")
eq("lists header is dimmed", side.item_table[drawerIndex(side, "Lists")].dim, true)
eq("current list is bold", side.item_table[drawerIndex(side, "Today")].bold, true)
eq("other lists not bold", side.item_table[drawerIndex(side, "Work")].bold, nil)
eq("inbox is not listed twice", drawerIndex(side, "Inbox thing"), nil)
check("settings row", drawerIndex(side, "Settings") ~= nil)
mocks.clearInfos()

eq("emoji removed from list names", count(side, "Reading"), "0")

-- ---- pick a list in the sidebar: it closes and the main screen switches ----------------------
side:tap(drawerIndex(side, "Work"))
eq("sidebar closed after picking", drawer(), nil)
check("same list screen reused", menu() == list)
eq("switched to Work", list.title, "Work (4)")
side = openDrawer()
side:tap(drawerIndex(side, "Reading"))
eq("list title without emoji", list.title, "Reading (0)")
has("empty list says so", list.item_table[3].text, "No tasks here")
side = openDrawer()
side:tap(drawerIndex(side, "Work"))
side = openDrawer()
eq("Work now bold", side.item_table[drawerIndex(side, "Work")].bold, true)
side:tap(drawerIndex(side, "Today"))

-- ---- Today ---------------------------------------------------------------------------------
eq("list title", list.title, "Today (4)")
eq("tasks in order", visible(), "Overdue invoice|Ship report|Buy milk|Standup notes")
local i_ship = taskRow("Ship report")
eq("checkbox and priority mark", list.item_table[i_ship].text, BOX .. "!!! Ship report")
eq("due label", list.item_table[i_ship].mandatory, "Today")
eq("overdue label", list.item_table[taskRow("Overdue invoice")].mandatory, "Overdue 2d")
eq("overdue is bold", list.item_table[taskRow("Overdue invoice")].bold, true)
has("timed label", list.item_table[taskRow("Standup notes")].mandatory, "Today 10:00")

-- ---- tap a task: the detail screen --------------------------------------------------------
list:tap(i_ship)
local detail = menu()
eq("detail title", detail.title, "Task")
eq("detail: title row has a checkbox", detail.item_table[1].text, BOX .. "Ship report")
eq("detail: no notes yet", detail.item_table[2].text, NOTES .. "Notes: (none)")
eq("detail: due", detail.item_table[3].mandatory, "Today")
eq("detail: priority", detail.item_table[4].mandatory, "High")
eq("detail: list", detail.item_table[5].mandatory, "Work")
eq("detail: done subtask", detail.item_table[6].text, BOX_DONE .. "Draft")
eq("detail: open subtask", detail.item_table[7].text, BOX .. "Send")
eq("detail: complete row", detail.item_table[8].text, CHECK .. "Mark as complete")
has("detail: due has the calendar icon", detail.item_table[3].text, "\239\129\179  Due")
local requests_before = #mocks.requests
detail:tap(6) -- a checklist row from a cache without item ids: asks for a sync, sends nothing
eq("old checklist: nothing sent", #mocks.requests, requests_before)
has("old checklist: asks for a sync", lastInfo(), "Sync once")
mocks.clearInfos()
detail:tap(5) -- the List row opens the list picker
local picker5 = menu()
has("list row opens the picker", picker5.title, "Move to: Ship report")
eq("current list marked", picker5.item_table[mocks.rowIndex(picker5, "\239\128\186  Work")].mandatory, "current")
eq("current list not selectable", picker5.item_table[mocks.rowIndex(picker5, "\239\128\186  Work")].select_enabled, false)
eq("inbox offered first", picker5.item_table[1].text, "\239\128\156  Inbox")
closeWidget(picker5)
eq("nothing sent by looking", #mocks.requests, requests_before)

-- ---- edit the title (online) ---------------------------------------------------------------
detail:tap(1, OFF_BOX)
local dialog = mocks.find("input")
eq("title dialog prefilled", dialog.input, "Ship report")
submit(dialog, "Ship the report")
eq("server got new title", server.updates[1].title, "Ship the report")
eq("only the title was sent", server.updates[1].content, nil)
eq("detail shows new title", detail.item_table[1].text, BOX .. "Ship the report")
eq("queue empty after upload", #plugin:pendingList(), 0)

-- Blank title is refused and nothing is sent.
requests_before = #mocks.requests
detail:tap(1)
submit(mocks.find("input"), "   ")
has("blank title refused", lastInfo(), "needs a title")
eq("blank title sends nothing", #mocks.requests, requests_before)
mocks.clearInfos()

-- ---- edit notes: starts from TickTick's newest text ---------------------------------------------
-- The phone edited the checklist note after our last sync.
server.tasks.work[1].desc = "newer text from phone"
detail:tap(2)
dialog = mocks.find("input")
eq("editor opened on fresh text, not the old copy", dialog.input, "newer text from phone")
eq("editor title", dialog.title, "Notes")
eq("editor allows new lines", dialog.allow_newline, true)
local fetch = mocks.requests[#mocks.requests]
eq("fetched the task first", fetch.path, "/project/work/task/w1")
eq("saved ok", dialog.save_callback("newer text from phone\nplus a line from the Kindle", true), true)
eq("checklist task notes go to desc", server.tasks.work[1].desc, "newer text from phone\nplus a line from the Kindle")
eq("content untouched", server.tasks.work[1].content, null)
eq("only desc was sent", server.updates[2].content, nil)
eq("detail shows first notes line", detail.item_table[2].text, NOTES .. "Notes: newer text from phone")
mocks.shown[#mocks.shown] = nil -- close the editor

-- ---- complete from the detail screen -------------------------------------------------------------
detail:tap(#detail.item_table)
local confirm = mocks.find("confirm")
has("confirm names the task", confirm.text, "Ship the report")
confirm.ok_callback()
eq("server got completion", server.completed["w1"], "work")
eq("detail closed", menu().title, "Today (3)")
eq("task gone from list", visible(), "Overdue invoice|Buy milk|Standup notes")
mocks.clearInfos()
side = openDrawer()
eq("sidebar counts follow", count(side, "Today"), "3")
eq("sidebar list counts follow", count(side, "Work"), "3")
side:close()
eq("closing the sidebar keeps the list", menu(), list)

-- ---- hold a row: quick complete -----------------------------------------------------------------
list = menu()
holdComplete(list, "Buy milk")
eq("quick complete reached server", server.completed["h1"], "home")
eq("hidden after quick complete", visible(), "Overdue invoice|Standup notes")
mocks.clearInfos()

-- ---- the checkbox: a tap on it completes at once, a tap beside it opens the task -----------------
local h3 = raw("h3", "home", "Water plants", iso(midnight), true, 0)
local h4 = raw("h4", "home", "Call mom", iso(midnight), true, 0)
server.tasks.home[#server.tasks.home + 1] = h3
server.tasks.home[#server.tasks.home + 1] = h4
list:tap(1) -- sync to pick them up
mocks.clearInfos()
list:tap(taskRow("Water plants"), OFF_BOX)
eq("tap beside the box opens the task", menu().title, "Task")
menu():close()
local function confirms() local n = 0 for i, w in ipairs(mocks.shown) do if w.kind == "confirm" then n = n + 1 end end return n end
local confirms_before = confirms()
local requests_at_tick = #mocks.requests
list:tap(taskRow("Water plants"), ON_BOX)
eq("checkbox hides the task at once", taskRow("Water plants"), nil)
eq("nothing uploaded while Undo is offered", #mocks.requests, requests_at_tick)
local undo = mocks.top()
eq("Undo box shown", undo.kind, "confirm")
eq("Undo button", undo.cancel_text, "Undo")
has("Undo box names the task", undo.text, "Water plants")
eq("a tap outside does not undo", undo.dismissable, false)
eq("Undo closes by itself", #mocks.scheduled, 1)
undo.cancel_callback() -- Undo
mocks.shown[#mocks.shown] = nil -- (KOReader closes the box after the button callback)
eq("Undo: task back in the list", taskRow("Water plants") ~= nil, true)
eq("Undo: nothing was sent", server.completed["h3"], nil)
eq("Undo: queue empty", #plugin:pendingList(), 0)
eq("Undo: timer cancelled", #mocks.scheduled, 0)
mocks.clearInfos()

list:tap(taskRow("Water plants"), ON_BOX)
undo = mocks.top()
undo.ok_callback() -- OK: upload now
mocks.shown[#mocks.shown] = nil
eq("OK uploads at once", server.completed["h3"], "home")
eq("OK cancels the timer", #mocks.scheduled, 0)
eq("no second 'Completed' message", lastInfo(), nil)
mocks.clearInfos()

list:tap(taskRow("Call mom"))
eq("a tap with no position opens the task", menu().title, "Task")
menu():tap(1, ON_BOX)
eq("task screen closes after ticking", menu(), list)
undo = mocks.top()
eq("Undo offered from the task screen too", undo.cancel_text, "Undo")
eq("still not uploaded", server.completed["h4"], nil)
mocks.runTimers() -- 5 seconds pass
eq("timeout closes the box", mocks.find("confirm") == undo, false)
eq("timeout uploads", server.completed["h4"], "home")
eq("list back to before", visible(), "Overdue invoice|Standup notes")
mocks.clearInfos()

-- ---- due date and priority -------------------------------------------------------------------
list:tap(taskRow("Overdue invoice"))
detail = menu()
eq("due row is tappable", detail.item_table[3].action ~= nil, true)
detail:tap(3)
local due_menu = mocks.top()
eq("due options shown", due_menu.kind, "buttons")
has("due options titled with the date", due_menu.title, "Overdue 2d")
check("offers removal", button(due_menu, "Remove due date") ~= nil)
check("offers a time", button(due_menu, "Set a time") ~= nil)
eq("all-day task: no 'All day' choice", button(due_menu, "All day"), nil)
button(due_menu, "Change date").callback()
eq("options close", mocks.find("buttons") == due_menu, false)
local picker = mocks.top()
eq("date picker shown", picker.kind, "datetime")
local overdue_day = os.date("!*t", midnight - 2 * 86400)
eq("picker starts on the current due date", picker.day, overdue_day.day)
eq("all-day task: no time note", picker.info_text, nil)
local in3 = os.date("!*t", midnight + 3 * 86400)
picker:pick(in3.year, in3.month, in3.day)
local upd = server.updates[#server.updates]
eq("due uploaded as local midnight in UTC", upd.dueDate, os.date("!%Y-%m-%dT00:00:00.000+0000", midnight + 3 * 86400))
eq("start moved with it", upd.startDate, upd.dueDate)
eq("stays all-day", upd.isAllDay, true)
check("detail shows the new due date", detail.item_table[3].mandatory ~= "Overdue 2d", detail.item_table[3].mandatory)
mocks.clearInfos()

detail:tap(4)
local pd = mocks.top()
eq("priority choices", pd.kind, "buttons")
eq("four priorities", #pd.buttons[1], 4)
has("current priority ticked", pd.buttons[1][1].text, "None")
check("current one has the check icon", pd.buttons[1][1].text ~= "None")
pd.buttons[1][4].callback() -- High
eq("priority uploaded", server.updates[#server.updates].priority, 5)
eq("detail shows High", detail.item_table[4].mandatory, "High")
eq("priority dialog closed", mocks.top() == pd, false)
mocks.clearInfos()

-- set a time: the task becomes a timed task on the same day
detail:tap(3)
button(mocks.top(), "Set a time").callback()
picker = mocks.top()
eq("time picker", picker.title_text, "Due time")
eq("time picker starts at 9:00", picker.hour, 9)
picker.hour, picker.min = 14, 30
picker:callback(picker)
closeWidget(picker)
upd = server.updates[#server.updates]
eq("timed due uploaded", upd.dueDate, os.date("!%Y-%m-%dT14:30:00.000+0000", midnight + 3 * 86400))
eq("no longer all-day", upd.isAllDay, false)
has("detail shows the time", detail.item_table[3].mandatory, "14:30")
mocks.clearInfos()
-- back to all day
detail:tap(3)
button(mocks.top(), "All day").callback()
upd = server.updates[#server.updates]
eq("all day again", upd.isAllDay, true)
eq("same day, midnight", upd.dueDate, os.date("!%Y-%m-%dT00:00:00.000+0000", midnight + 3 * 86400))
mocks.clearInfos()
detail:tap(3)
button(mocks.top(), "Remove due date").callback()
upd = server.updates[#server.updates]
eq("removal sends an empty due date", upd.dueDate, "")
eq("detail shows no due date", detail.item_table[3].mandatory, "None")
detail:close()
eq("removed from Today", taskRow("Overdue invoice"), nil)
mocks.clearInfos()

-- Offline: a due-date edit is queued and survives a sync that brings the old date back.
mocks.net.online, mocks.net.can_connect = false, false
list:tap(taskRow("Standup notes"))
detail = menu()
local timed_hour = detail.item_table[3].mandatory
detail:tap(3)
check("timed task offers All day", button(mocks.top(), "All day") ~= nil)
button(mocks.top(), "Change date").callback()
picker = mocks.top()
has("timed task keeps its time", picker.info_text, "Keeps its time")
local tm = os.date("!*t", midnight + 86400)
picker:pick(tm.year, tm.month, tm.day)
has("tomorrow, same time", detail.item_table[3].mandatory, "Tomorrow")
eq("queued", #plugin:pendingList(), 1)
detail:close()
mocks.clearInfos()
mocks.net.online, mocks.net.can_connect = true, true
server.fail_updates = true
list:tap(1) -- sync: the edit fails to upload, the server still has today
eq("moved out of Today despite failed upload", taskRow("Standup notes"), nil)
server.fail_updates = false
list:tap(1)
eq("uploaded on the next sync", #plugin:pendingList(), 0)
local w3 = server.tasks.work[3]
eq("server has tomorrow, same time", w3.dueDate, os.date("!%Y-%m-%dT10:00:00.000+0000", midnight + 86400))
eq("server: still a timed task", w3.isAllDay, false)
mocks.clearInfos()
-- put things back the way later tests expect
w3.dueDate, w3.startDate = iso(midnight + 10 * 3600), iso(midnight + 10 * 3600)
server.tasks.work[2].dueDate, server.tasks.work[2].startDate, server.tasks.work[2].isAllDay = iso(midnight - 2 * 86400), null, true
server.tasks.work[2].priority = 0
list:tap(1)
eq("restored for later tests", visible(), "Overdue invoice|Standup notes")
mocks.clearInfos()

-- ---- hold a row: the task menu, and moving a task to another list ------------------------------
local shown_n = #mocks.shown
list:hold(taskRow("Standup notes"))
local tm_dialog = mocks.top()
eq("hold opens a menu, not a completion", tm_dialog.kind, "buttons")
eq("menu titled with the task", tm_dialog.title, "Standup notes")
check("menu: Open", button(tm_dialog, "Open") ~= nil)
check("menu: Complete", button(tm_dialog, "Complete") ~= nil)
check("menu: Move", button(tm_dialog, "Move to list") ~= nil)
check("menu: Due date", button(tm_dialog, "Due date") ~= nil)
check("menu: Priority", button(tm_dialog, "Priority") ~= nil)
eq("nothing completed by holding", server.completed["w3"], nil)
button(tm_dialog, "Open").callback()
eq("Open closes the menu and opens the task", menu().title, "Task")
menu():close()

list:hold(taskRow("Standup notes"))
button(mocks.top(), "Move to list").callback()
local mv = menu()
has("move picker", mv.title, "Move to:")
mv:tap(mocks.rowIndex(mv, "\239\128\186  Home"))
eq("picker closes", menu(), list)
local last_move = server.moves[#server.moves]
eq("move: from", last_move.fromProjectId, "work")
eq("move: to", last_move.toProjectId, "home")
eq("move: task", last_move.taskId, "w3")
eq("server has it in Home", server.tasks.home[#server.tasks.home].id, "w3")
eq("still in Today (dates unchanged)", taskRow("Standup notes") ~= nil, true)
eq("task knows its new list", plugin:findCachedTask("w3").project, "Home")
has("move confirmed", lastInfo(), "Moved to Home")
eq("queue empty after move", #plugin:pendingList(), 0)
mocks.clearInfos()
side = openDrawer()
eq("Work count drops", count(side, "Work"), "2")
side:tap(drawerIndex(side, "Home"))
eq("now listed under Home", taskRow("Standup notes") ~= nil, true)

-- Offline: move, then edit; the move uploads first and the edit follows it to the new list.
mocks.net.online, mocks.net.can_connect = false, false
list:hold(taskRow("Standup notes"))
button(mocks.top(), "Move to list").callback()
mv = menu()
mv:tap(mocks.rowIndex(mv, "\239\128\156  Inbox"))
has("offline move says it will upload", lastInfo(), "next sync")
eq("gone from Home at once", taskRow("Standup notes"), nil)
mocks.clearInfos()
side = openDrawer()
side:tap(drawerIndex(side, "Inbox"))
list:tap(taskRow("Standup notes"))
detail = menu()
eq("task screen shows Inbox", detail.item_table[5].mandatory, "Inbox")
detail:tap(1, OFF_BOX)
submit(mocks.find("input"), "Standup (inbox)")
eq("move and edit queued", #plugin:pendingList(), 2)
detail:close()
mocks.clearInfos()
-- moving it back to Home cancels the queued move, and the edit follows it home
list:hold(taskRow("Standup (inbox)"))
button(mocks.top(), "Move to list").callback()
mv = menu()
mv:tap(mocks.rowIndex(mv, "\239\128\186  Home"))
eq("moving back home cancels the queued move", #plugin:pendingList(), 1)
eq("only the edit is left", plugin:pendingList()[1].op, "update")
eq("the edit now names Home", plugin:pendingList()[1].project_id, "home")
mocks.clearInfos()
side = openDrawer()
side:tap(drawerIndex(side, "Home"))
list:hold(taskRow("Standup (inbox)"))
button(mocks.top(), "Move to list").callback()
mv = menu()
mv:tap(mocks.rowIndex(mv, "\239\128\156  Inbox"))
mocks.clearInfos()
eq("move queued after the edit", plugin:pendingList()[2].op, "move")

mocks.net.online, mocks.net.can_connect = true, true
server.fail_moves = true
list:tap(1) -- sync; the move fails
eq("failed move stays queued", #plugin:pendingList(), 1)
eq("still shown in Inbox after the sync", plugin:findCachedTask("w3").project_id, "inbox9")
server.fail_moves = false
list:tap(1)
eq("move uploaded", #plugin:pendingList(), 0)
eq("server: in the Inbox", server.tasks.inbox9[#server.tasks.inbox9].id, "w3")
eq("server: edit landed", server.tasks.inbox9[#server.tasks.inbox9].title, "Standup (inbox)")
mocks.clearInfos()

-- put it back for later tests
local back = table.remove(server.tasks.inbox9)
back.projectId, back.title = "work", "Standup notes"
table.insert(server.tasks.work, 3, back)
side = openDrawer()
side:tap(drawerIndex(side, "Today"))
list:tap(1)
eq("restored again", visible(), "Overdue invoice|Standup notes")
mocks.clearInfos()

-- ---- checklist items: tick and untick ------------------------------------------------------------------
local cl = raw("c1", "home", "Pack bag", iso(midnight), true, 0,
    { { id = "i1", title = "Charger", status = 0, sortOrder = 1 }, { id = "i2", title = "Book", status = 1, sortOrder = 2 } })
server.tasks.home[#server.tasks.home + 1] = cl
list:tap(1) -- sync
mocks.clearInfos()
list:tap(taskRow("Pack bag"))
detail = menu()
local i_ch = mocks.rowIndex(detail, BOX .. "Charger")
check("open item shown with an empty box", i_ch ~= nil)
check("done item shown ticked", mocks.rowIndex(detail, BOX_DONE .. "Book") ~= nil)
cl.items[2].status = 0 -- meanwhile, the phone unticked Book
detail:tap(i_ch)
local sent = server.updates[#server.updates]
eq("whole checklist sent", #sent.items, 2)
eq("ticked item: done", sent.items[1].status, 1)
eq("item id kept", sent.items[1].id, "i1")
eq("sort order kept", sent.items[1].sortOrder, 1)
eq("the phone's change was not overwritten", sent.items[2].status, 0)
check("detail shows it ticked", mocks.rowIndex(detail, BOX_DONE .. "Charger") ~= nil)
check("detail shows the phone's change", mocks.rowIndex(detail, BOX .. "Book") ~= nil)
eq("checklist tick: no message when it uploads", lastInfo(), nil)
-- offline: untick, queued, survives a sync that fails to upload it
mocks.net.online, mocks.net.can_connect = false, false
detail:tap(mocks.rowIndex(detail, BOX_DONE .. "Charger"))
check("offline untick shown at once", mocks.rowIndex(detail, BOX .. "Charger") ~= nil)
eq("offline untick queued", #plugin:pendingList(), 1)
eq("offline untick: no message per tap", lastInfo(), nil)
detail:close()
mocks.net.online, mocks.net.can_connect = true, true
list:tap(1)
eq("untick uploaded on sync", cl.items[1].status, 0)
eq("queue empty after checklist sync", #plugin:pendingList(), 0)
-- a task whose checklist was cut short must never be sent back
local long = { id = "zz", project_id = "home", title = "Long", checklist = { { id = "a", title = "a" } }, checklist_truncated = true, subtasks = 1 }
local before_updates = #server.updates
plugin:toggleChecklistItem(long, "a")
has("long checklist refused", lastInfo(), "too long")
eq("long checklist: nothing sent", #server.updates, before_updates)
mocks.clearInfos()
holdComplete(list, "Pack bag")
mocks.clearInfos()

-- ---- quick add ------------------------------------------------------------------------------------------
list:tap(2) -- Add task (in Today: goes to the Inbox, due today)
local add = mocks.find("input")
eq("add dialog title", add.title, "New task in Inbox")
eq("add button label", add.buttons[1][2].text, "Add")
submit(add, "  Call the bank  ")
local made = server.created[#server.created]
eq("created in the Inbox", made.projectId, "inbox9")
eq("title trimmed", made.title, "Call the bank")
eq("Today adds a task due today", made.dueDate, os.date("!%Y-%m-%dT00:00:00.000+0000", midnight))
eq("all-day", made.isAllDay, true)
check("shown in Today", taskRow("Call the bank") ~= nil)
eq("has the real id", plugin:findCachedTask(made.id) ~= nil, true)
eq("queue empty after add", #plugin:pendingList(), 0)
mocks.clearInfos()
list:tap(2)
submit(mocks.find("input"), "   ")
eq("blank title adds nothing", #server.created, 1)

-- offline add into a list, then edit, move and complete it before it ever uploads
side = openDrawer()
side:tap(drawerIndex(side, "Home"))
mocks.net.online, mocks.net.can_connect = false, false
list:tap(2)
eq("adds to the open list", mocks.find("input").title, "New task in Home")
submit(mocks.find("input"), "Fix shelf")
has("offline add message", lastInfo(), "Added on this device")
mocks.clearInfos()
local row_fs = taskRow("Fix shelf")
check("offline task shown at once", row_fs ~= nil)
local local_id = list.item_table[row_fs].task.id
eq("temporary id", local_id:sub(1, 6), "local:")
list:tap(row_fs)
detail = menu()
detail:tap(1, OFF_BOX)
submit(mocks.find("input"), "Fix the shelf")
detail:tap(4)
button(mocks.top(), "High").callback()
eq("edits go into the queued create", #plugin:pendingList(), 1)
eq("create carries the edit", plugin:pendingList()[1].fields.title, "Fix the shelf")
eq("create carries the priority", plugin:pendingList()[1].fields.priority, 5)
detail:close()
mocks.clearInfos()
list:hold(taskRow("Fix the shelf"))
button(mocks.top(), "Move to list").callback()
menu():tap(mocks.rowIndex(menu(), "\239\128\186  Work"))
eq("move of an unsent task changes where it is created", plugin:pendingList()[1].project_id, "work")
eq("still one queued change", #plugin:pendingList(), 1)
mocks.clearInfos()
side = openDrawer()
side:tap(drawerIndex(side, "Work"))
holdComplete(list, "Fix the shelf")
eq("complete queued behind the create", #plugin:pendingList(), 2)
mocks.clearInfos()
-- the create fails on the first sync: the task must survive the sync, the completion must wait
mocks.net.online, mocks.net.can_connect = true, true
server.fail_creates = true
local completes_before = server.completed_order and #server.completed_order or 0
list:tap(1)
eq("failed create stays queued (with its completion)", #plugin:pendingList(), 2)
eq("completion not sent before the create", (server.completed_order and #server.completed_order or 0), completes_before)
eq("unsent task survives the sync", plugin:findCachedTask(local_id) ~= nil, true)
mocks.clearInfos()
server.fail_creates = false
list:tap(1)
made = server.created[#server.created]
eq("created in Work", made.projectId, "work")
eq("with the edited title", made.title, "Fix the shelf")
eq("with the priority", made.priority, 5)
eq("then completed under its real id", server.completed[made.id], "work")
eq("everything uploaded", #plugin:pendingList(), 0)
mocks.clearInfos()

-- ---- delete -------------------------------------------------------------------------------------------------
side = openDrawer()
side:tap(drawerIndex(side, "Today"))
list:hold(taskRow("Call the bank"))
button(mocks.top(), "Delete").callback()
local del = mocks.top()
eq("delete asks first", del.kind, "confirm")
has("delete names the task", del.text, "Call the bank")
eq("delete button", del.ok_text, "Delete")
eq("nothing deleted before confirming", server.deleted, nil)
del.ok_callback()
closeWidget(del)
eq("deleted on the server", server.deleted[server.created[1].id], "inbox9")
eq("gone from the list", taskRow("Call the bank"), nil)
mocks.clearInfos()
-- deleting a task that never uploaded just forgets it
mocks.net.online, mocks.net.can_connect = false, false
list:tap(2)
submit(mocks.find("input"), "Oops")
mocks.clearInfos()
list:hold(taskRow("Oops"))
button(mocks.top(), "Delete").callback()
mocks.top().ok_callback()
eq("unsent task: queue emptied", #plugin:pendingList(), 0)
eq("unsent task: gone", taskRow("Oops"), nil)
mocks.clearInfos()
mocks.net.online, mocks.net.can_connect = true, true
-- offline delete is queued and hidden, then uploads
mocks.net.online, mocks.net.can_connect = false, false
list:hold(taskRow("Standup notes"))
button(mocks.top(), "Delete").callback()
mocks.top().ok_callback()
has("offline delete message", lastInfo(), "Deleted on this device")
eq("hidden at once", taskRow("Standup notes"), nil)
mocks.clearInfos()
mocks.net.online, mocks.net.can_connect = true, true
list:tap(1)
eq("delete uploaded", server.deleted["w3"], "work")
eq("queue empty after delete", #plugin:pendingList(), 0)
-- put w3 back for the tests below
local w3_back = raw("w3", "work", "Standup notes", iso(midnight + 10 * 3600), false, 0)
table.insert(server.tasks.work, 3, w3_back)
list:tap(1)
eq("restored after delete tests", visible(), "Overdue invoice|Standup notes")
mocks.clearInfos()

-- ---- offline: edits and completions queue ---------------------------------------------------------
mocks.net.online, mocks.net.can_connect = false, false
requests_before = #mocks.requests
list:tap(taskRow("Standup notes"))
detail = menu()
detail:tap(1)
submit(mocks.find("input"), "Standup notes (moved)")
has("offline edit toast", lastInfo(), "Saved on this device")
eq("offline edit queued", #plugin:pendingList(), 1)
eq("detail shows offline edit", detail.item_table[1].text, BOX .. "Standup notes (moved)")
mocks.clearInfos()

detail:tap(2) -- notes while offline: editor opens on the cached copy
dialog = mocks.find("input")
eq("offline editor is labelled", dialog.title, "Notes (copy from last sync)")
dialog.save_callback("Agenda:\n- demo", true)
eq("edits to one task merge into one queued update", #plugin:pendingList(), 1)
eq("queued title", plugin:pendingList()[1].fields.title, "Standup notes (moved)")
eq("queued notes (plain task -> content)", plugin:pendingList()[1].fields.content, "Agenda:\n- demo")
mocks.shown[#mocks.shown] = nil
mocks.clearInfos()

detail:close()
list = menu()
holdComplete(list, "Overdue invoice")
eq("offline completion queued too", #plugin:pendingList(), 2)
eq("nothing sent while offline", #mocks.requests, requests_before)
has("sync row counts waiting changes", list.item_table[1].text, "2 waiting to upload")
eq("list shows the edit, hides the completion", visible(), "Standup notes (moved)")
mocks.clearInfos()

-- Everything survives a restart.
local reborn = TickTick:new{ ui = { menu = { registerToMainMenu = function() end } } }
eq("queue persisted", #reborn:pendingList(), 2)
eq("remembers the last list", reborn:startMode().kind, "today")
eq("edit persisted in cache", reborn:findCachedTask("w3").title, "Standup notes (moved)")

-- ---- back online, but uploading edits fails: the edit must stay visible ----------------------------
mocks.net.online, mocks.net.can_connect = true, true
server.fail_updates = true
list:tap(1) -- Sync row
eq("completion uploaded", server.completed["w2"], "work")
eq("failed edit stays queued", #plugin:pendingList(), 1)
eq("edit still on screen after the sync replaced the cache", visible(), "Standup notes (moved)")
eq("server still has the old title", server.tasks.work[3].title, "Standup notes")
server.fail_updates = false
list:tap(1)
eq("edit uploaded on next sync", server.tasks.work[3].title, "Standup notes (moved)")
eq("notes uploaded with it", server.tasks.work[3].content, "Agenda:\n- demo")
eq("queue empty", #plugin:pendingList(), 0)
mocks.clearInfos()

-- ---- notes too long to edit safely --------------------------------------------------------------------
local before_dialogs = 0
for i, w in ipairs(mocks.shown) do if w.kind == "input" then before_dialogs = before_dialogs + 1 end end
plugin:editNotes({ id = "zz", project_id = "work", title = "Huge", content = "x", content_truncated = true, subtasks = 0 })
has("refuses huge notes", lastInfo(), "too long to edit")
local after_dialogs = 0
for i, w in ipairs(mocks.shown) do if w.kind == "input" then after_dialogs = after_dialogs + 1 end end
eq("no editor opened for huge notes", after_dialogs, before_dialogs)
mocks.clearInfos()

-- ---- failure paths on the list screen ------------------------------------------------------------------------
side = openDrawer()
side:tap(drawerIndex(side, "All tasks"))
eq("all view: today, later, then undated A-Z", visible(), "Standup notes (moved)|Plan next quarter|Inbox thing|Someday")

server.mode = "down"
holdComplete(list, "Someday")
eq("hidden despite failed upload", visible(), "Standup notes (moved)|Plan next quarter|Inbox thing")
eq("kept in queue", #plugin:pendingList(), 1)
has("failure explains", lastInfo(), "Saved, but not uploaded yet")
has("failure detail", lastInfo(), "Could not reach TickTick")
mocks.clearInfos()
server.mode = "ok"
list:tap(1)
eq("retried on sync", server.completed["h2"], "home")
eq("queue empty again", #plugin:pendingList(), 0)

server.mode = "forbidden"
list:tap(1)
has("auth error text", lastInfo(), "rejected the access token")
check("old list still usable", menu() == list)
mocks.clearInfos()
server.mode = "ok"

server.not_found["w4"] = true
holdComplete(list, "Plan next quarter")
eq("404 dropped from queue", #plugin:pendingList(), 0)
eq("deleted-elsewhere task gone", visible(), "Standup notes (moved)|Inbox thing")
mocks.clearInfos()

-- ---- the Inbox -----------------------------------------------------------------------------------------------
side = openDrawer()
side:tap(drawerIndex(side, "Inbox"))
eq("inbox list title", list.title, "Inbox (1)")
eq("inbox list", visible(), "Inbox thing")
list:tap(taskRow("Inbox thing"))
eq("inbox task knows its list name", menu().item_table[5].mandatory, "Inbox")
menu():close()

-- ---- settings: lists to show ------------------------------------------------------------------------------------
side = openDrawer()
side:tap(drawerIndex(side, "Settings"))
local settings = menu()
eq("settings title", settings.title, "Settings")
eq("settings: lists", settings.item_table[1].text, "Lists to show")
eq("settings: time zone", settings.item_table[2].text, "Time zone: UTC+0:00 (manual)")
eq("settings: inbox", settings.item_table[3].text, "Inbox list ID (1 set)")
eq("settings: token", settings.item_table[4].text, "Change access token")
settings:tap(1)
local lists = menu()
eq("lists title", lists.title, "Lists to show")
eq("lists: Work shown", lists.item_table[2].text, BOX_DONE .. "Work")
lists:tap(2)
eq("lists: Work hidden", lists.item_table[2].text, BOX .. "Work")
eq("hidden list is not fetched next sync", server.tasks.work ~= nil, true)
lists:close()
settings:close()
check("back on the sidebar after settings", drawer() == side)
eq("sidebar hides the unchecked list", drawerIndex(side, "Work"), nil)
check("sidebar still has Home list", drawerIndex(side, "Home") ~= nil)
-- show it again
side:tap(drawerIndex(side, "Settings"))
menu():tap(1)
menu():tap(2)
menu():close()
menu():close()
check("Work is back", drawerIndex(side, "Work") ~= nil)
side:close()
list:close()
eq("closing the list leaves TickTick", menu(), nil)

-- ---- folders, list order, search, adding checklist items ------------------------------------------------
server.projects = {
    { id = "work", name = "Work", groupId = "g1", sortOrder = 30 },
    { id = "home", name = "Home", sortOrder = 10 },
    { id = "read", name = "\240\159\147\154 Reading", groupId = "g1", sortOrder = 20 },
}
server.tasks.home[#server.tasks.home + 1] = raw("h9", "home", "Plain thing", nil)
plugin:showHome()
list = menu()
list:tap(1) -- sync picks up folders and order
mocks.clearInfos()
side = openDrawer()
local i_home, i_folder = drawerIndex(side, "Home"), drawerIndex(side, "Folder")
local i_read, i_work = drawerIndex(side, "Reading"), drawerIndex(side, "Work")
check("ordered: Home, then the folder", i_home < i_folder)
check("folder lists follow in their order", i_folder < i_read and i_read < i_work)
has("folder row has the open-folder icon", side.item_table[i_folder].text, "\239\129\188  Folder")
has("nested list is indented", side.item_table[i_work].text, "      \239\128\186  Work")
eq("top-level list is not indented", side.item_table[i_home].text:sub(1, 1) ~= " ", true)
eq("folder shows the total of its lists", side.item_table[i_folder].mandatory,
    tostring(tonumber(count(side, "Work")) + tonumber(count(side, "Reading"))))
side:tap(i_folder) -- fold
eq("folded: its lists are hidden", drawerIndex(side, "Work"), nil)
has("folded icon", side.item_table[drawerIndex(side, "Folder")].text, "\239\129\187  Folder")
side:hold(drawerIndex(side, "Folder")) -- name it
submit(mocks.find("input"), "Job")
check("folder renamed", drawerIndex(side, "Job") ~= nil)
side:tap(drawerIndex(side, "Job")) -- unfold
check("unfolded again", drawerIndex(side, "Work") ~= nil)
local reborn2 = TickTick:new{ ui = { menu = { registerToMainMenu = function() end } } }
eq("folder name remembered", reborn2:folderName("g1"), "Job")
-- the move picker uses the same order and nesting
side:tap(drawerIndex(side, "Home"))
list:hold(taskRow("Plain thing"))
do
    button(mocks.top(), "Move to list").callback()
    local mp = menu()
    local m_home, m_job, m_work = mocks.rowIndex(mp, "\239\128\186  Home"), mocks.rowIndex(mp, "\239\129\188  Job"), mocks.rowIndex(mp, "      \239\128\186  Work")
    check("picker: folder header and nested list", m_job and m_work and m_job < m_work)
    eq("picker: folder header is not a target", mp.item_table[m_job].select_enabled, false)
    check("picker: Home marked current", m_home and mp.item_table[m_home].mandatory == "current")
    closeWidget(mp)
end
mocks.clearInfos()

-- search
side = openDrawer()
side:tap(drawerIndex(side, "Search"))
local sd = mocks.find("input")
eq("search dialog", sd.title, "Search tasks")
eq("search button", sd.buttons[1][2].text, "Search")
submit(sd, "inbox th")
eq("search closes the sidebar", drawer(), nil)
eq("search results title", list.title, "Search: inbox th (1)")
eq("search finds by title", visible(), "Inbox thing")
eq("a search is not reopened next time", plugin.state:readSetting("last_mode").kind ~= "search", true)
side = openDrawer()
side:tap(drawerIndex(side, "Search"))
eq("search remembers the last words", mocks.find("input").input, "inbox th")
submit(mocks.find("input"), "zzz-nothing")
has("no results says so", list.item_table[3].text, "No tasks here")

-- add checklist items
local ck = raw("c2", "home", "Groceries", iso(midnight), true, 0, { { id = "g1i", title = "Eggs", status = 0, sortOrder = 1 } })
server.tasks.home[#server.tasks.home + 1] = ck
list:tap(1)
mocks.clearInfos()
side = openDrawer()
side:tap(drawerIndex(side, "Home"))
list:tap(taskRow("Groceries"))
detail = menu()
local i_addck = mocks.rowIndex(detail, "\239\129\167  Add checklist item")
check("checklist task offers Add checklist item", i_addck ~= nil)
detail:tap(i_addck)
eq("add item dialog", mocks.find("input").title, "New checklist item")
submit(mocks.find("input"), "Milk")
eq("server got both items", #ck.items, 2)
eq("new item sent without a temporary id... and got one from TickTick", ck.items[2].id, "item1")
check("new item shown", mocks.rowIndex(detail, BOX .. "Milk") ~= nil)
eq("new item has TickTick's id locally", plugin:findCachedTask("c2").checklist[2].id, "item1")
detail:tap(mocks.rowIndex(detail, BOX .. "Milk"))
eq("new item can be ticked right away", ck.items[2].status, 1)
-- offline: add then tick before it uploads
mocks.net.online, mocks.net.can_connect = false, false
detail:tap(mocks.rowIndex(detail, "\239\129\167  Add checklist item"))
submit(mocks.find("input"), "Bread")
local i_bread = mocks.rowIndex(detail, BOX .. "Bread")
check("offline item shown", i_bread ~= nil)
detail:tap(i_bread)
check("offline item ticked", mocks.rowIndex(detail, BOX_DONE .. "Bread") ~= nil)
eq("still one queued update", #plugin:pendingList(), 1)
detail:close()
mocks.net.online, mocks.net.can_connect = true, true
list:tap(1)
eq("offline item uploaded", ck.items[3].title, "Bread")
eq("offline item uploaded ticked", ck.items[3].status, 1)
check("temporary id never sent", not tostring(ck.items[3].id):find("local:", 1, true))
mocks.clearInfos()
-- a plain task (no checklist) does not offer it
list:tap(taskRow("Plain thing"))
eq("plain task: no Add checklist item", mocks.rowIndex(menu(), "\239\129\167  Add checklist item"), nil)
menu():close()
list:close()

-- ---- Inbox not set up: the home screen says so and offers to fix it ----------------------------------------------
local plain_dir = TEST_TMPDIR .. "/plain"
os.execute("mkdir -p " .. plain_dir)
local pc = assert(io.open(plain_dir .. "/ticktick.lua", "w"))
pc:write('return { ["access_token"] = "good-token", ["utc_offset_minutes"] = 0 }\n')
pc:close()
mocks.settings_dir = plain_dir
local plain = TickTick:new{ ui = { menu = { registerToMainMenu = function() end } } }
plain:showHome()
side = openDrawer()
has("inbox hint", side.item_table[4].text, "Inbox: not set up")
side:tap(4)
dialog = mocks.find("input")
eq("inbox dialog title", dialog.title, "Inbox list ID")
submit(dialog, "inbox9")
eq("inbox id saved", plain:inboxId(), "inbox9")
eq("sidebar updates at once", drawerIndex(side, "Inbox"), 4)
side:tap(1) -- sync picks the inbox up
eq("inbox filled after sync", count(side, "Inbox"), "1")
side:close()
menu():close()

-- ---- token prompts ---------------------------------------------------------------------------------------------------
local fresh_dir = TEST_TMPDIR .. "/fresh"
os.execute("mkdir -p " .. fresh_dir)
mocks.settings_dir = fresh_dir
local fresh = TickTick:new{ ui = { menu = { registerToMainMenu = function() end } } }
fresh:showHome()
dialog = mocks.find("input")
check("asks for token when none", dialog ~= nil)
submit(dialog, "  abc 123\n")
eq("token saved without whitespace", fresh.settings:readSetting("access_token"), "abc123")
check("token persisted to disk", io.open(fresh_dir .. "/ticktick.lua") ~= nil)
-- opening never syncs, so the screen shows the empty cache; the wrong token shows up on Sync
check("list opens after paste", menu() ~= nil)
has("empty cache explained", menu().item_table[3].text, "Nothing downloaded yet")
menu():tap(1)
has("auth message on sync", lastInfo(), "rejected the access token")
mocks.clearInfos()
menu():close()

fresh:promptForOffset()
submit(mocks.find("input"), "-5")
eq("offset stored in minutes", fresh.settings:readSetting("utc_offset_minutes"), -300)
fresh:promptForOffset()
submit(mocks.find("input"), "")
eq("blank offset = auto", fresh.settings:readSetting("utc_offset_minutes"), nil)
fresh:promptForOffset()
submit(mocks.find("input"), "99")
has("bad offset rejected", lastInfo(), "between -14 and 14")

fresh:promptForExtraIds()
submit(mocks.find("input"), "inbox111, inbox222")
eq("extra ids parsed", #fresh:extraProjectIds(), 2)
eq("first extra id is the inbox", fresh:inboxId(), "inbox111")

print(string.format("plugin tests: %d passed, %d failed", passed, failures))
return failures
