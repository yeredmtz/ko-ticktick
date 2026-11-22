# TickTick for KOReader

TickTick on a jailbroken Kindle (KOReader): browse your lists, open tasks, add, edit, move, delete, search and complete tasks, set due dates and times, and tick or add checklist items.

- Screens open instantly from a cache on the device, and work with Wi-Fi off. Nothing syncs until you tap **Sync now**.
- Completions and edits made offline are queued and uploaded on the next sync.
- The access token lives on the Kindle, so nothing else (Pi, server) has to be running.

## What's in the box

| Path | What it is |
|---|---|
| `ticktick.koplugin/` | The plugin. Goes on the Kindle. |
| `tools/get_token.py` | Run on a computer once: logs in to TickTick and writes the config file. |
| `test/` | Tests (`python3 test/run_tests.py` and `python3 test/test_get_token.py`, need `pip install lupa`). Not for the Kindle. |

## 1. Get a token (on a computer)

1. Go to <https://developer.ticktick.com>, sign in, **Manage Apps → New App**. Set the OAuth redirect URL to exactly `http://localhost:8765/callback`. Note the client ID and secret.
2. Run:

   ```
   python3 tools/get_token.py --client-id YOUR_ID --client-secret YOUR_SECRET --utc-offset -5
   ```

   Approve access in the browser. The script checks the token, lists your lists, and writes `ticktick.lua`.
   `--utc-offset` is hours from UTC (Ohio is -5 in winter, -4 in summer). It decides which tasks count as "today". Leave it out to follow the Kindle's clock instead.
3. Optional: `--inbox-id inbox123456789` (see "Inbox" below).

## 2. Install on the Kindle

Connect the Kindle over USB and copy:

- `ticktick.koplugin/` → `koreader/plugins/ticktick.koplugin/`
- `ticktick.lua` → `koreader/settings/ticktick.lua`

Restart KOReader. Open it from the top menu: **Tools (wrench) → TickTick** (near the bottom of the list). It opens the list you looked at last (Today the first time).

Tip: for zero menu taps, assign a gesture: **Settings → Taps and gestures → Gesture manager**, choose a gesture, then **General → TickTick: open** (or **TickTick: today's tasks**, or **TickTick: sync now**).

## Using it

**Task lists** are the main screen. Each task has a checkbox on the left: **tap the checkbox** to complete it. For 5 seconds an **Undo** button is offered; nothing is uploaded until it closes (tap OK to upload straight away). Tap anywhere else on the row to open the task. **Hold** a task for a menu: Open, Complete, Move to list, Due date, Priority, Delete (asks first). The first rows are **Sync now** and **Add task**.

**Add task:** type a title. In one of your lists it goes into that list. In Today or Tomorrow it goes into the Inbox, due that day; in the other smart lists, into the Inbox with no date. Works offline: it shows at once and uploads on the next sync, and you can edit, move or complete it before then.

**Sidebar:** tap the menu button (three lines, top left) to slide out your lists, like the phone app, each with an icon: Inbox, Today, Tomorrow, Next 7 days, All tasks, then each of your lists, with task counts on the right. The list you are on is in bold. Tap one to switch to it; tap outside the panel to close it. It also has **Sync now** and **Search** at the top and **Settings** at the bottom.

**List order and folders:** lists appear in TickTick's own order. Lists inside a TickTick folder are shown indented under a folder row, which shows their total count. Tap a folder to fold or unfold it. TickTick does not share folder names with other apps, so a folder is called "Folder" until you **hold** it and give it a name (kept on the Kindle).

**Search** looks through every task's title, notes and checklist (any upper/lower case).

**Emoji** in list names and task titles are left out on screen, because the Kindle's fonts cannot draw them (they showed as "?"). They are kept in TickTick: editing a title starts from the full text. (The icons the plugin itself shows come from a symbol font KOReader ships, so those do draw.)

**Task screen:** shows the title (with its checkbox), notes, due date (calendar icon), priority (flag), list and checklist, each with an icon.
- Tap the **checkbox** to complete the task (with Undo). Tap the rest of the **title** to rename it.
- Tap **List** to move the task to another list (the Inbox or any list you show).
- Tap **Due** for: change the date (a timed task keeps its time), set or change a time, make it all day again, or remove the due date. Tap **Priority** to choose None, Low, Medium or High. Tap **Notes** to edit them in a full-screen editor (Save keeps the editor open, Close leaves it).
- **Mark as complete** completes the task and returns to the list.
- Tap a **checklist item** to tick or untick it. When online, the newest checklist is fetched first, so a change made on your phone is kept. **Add checklist item** adds to a task that already has a checklist (also offline). Checklists downloaded by an older version need one sync first. A single task with more than 200 checklist items cannot have its checklist edited here (the limit is items inside one task, not tasks in a list).

**Notes and checklists:** TickTick keeps the notes of ordinary tasks in one field and the description of checklist tasks in another. The plugin edits whichever applies, so what you see here is what you see in the phone app.

**Offline:** edits and completions are saved on the device, shown straight away, and queued. The Sync row says how many are waiting. Tap Sync once Wi-Fi is on. Several edits to one task are merged into a single upload (the latest wins).

**Newer text wins protection:** when you open the notes editor while online, the plugin first downloads that task's current notes, so a change made on your phone is not overwritten by an old copy. Offline, the editor says "copy from last sync" and your save will replace whatever is on TickTick when it uploads.

**When it syncs:** only when you tap **Sync now** (or use the "TickTick: sync now" gesture). Opening TickTick always shows what is on the device, straight away. Sync turns Wi-Fi on if needed. Edits and completions still upload at once when Wi-Fi is already on. Sync makes one request per list, so hide lists you don't need (Settings → Lists to show).

## Things to know

**Inbox.** TickTick's API does not list the Inbox, so it needs its list ID, which looks like `inbox` followed by digits. TickTick's web address only says `#p/inbox/tasks`, so it does not show the number. One way to find it: any Inbox task fetched through TickTick's API has a `projectId` field holding it. Enter it under **Settings → Inbox list ID** (or tap the "Inbox: not set up" row in the sidebar), or pass `--inbox-id` to the script, then sync.

**Token lifetime.** The script prints how long TickTick says the token lasts. When the plugin says the token was rejected, run `get_token.py` again and replace `ticktick.lua`.

**Security.**
- The token is stored in plain text in `koreader/settings/ticktick.lua`. Anyone with the Kindle's files has it. It can read and change your tasks, nothing else. To revoke it, delete the app at developer.ticktick.com.
- KOReader does not check HTTPS certificates by default. To turn checking on, add `["ca_file"] = "/path/to/ca-bundle.crt",` to `ticktick.lua` (any CA bundle file you put on the Kindle). If the Kindle's clock is badly wrong, requests will fail either way.

**Dida365 (Chinese service).** Run the script with `--dida365`; it writes the right `base_url`.

**Files the plugin creates.** `settings/ticktick_state.lua` holds the cache, the queue of waiting changes, and your list toggles. It is safe to delete (changes that have not uploaded are lost).

**Very long notes** (over about 30,000 characters) are not editable on the Kindle; the plugin tells you to use TickTick instead, so it never saves a shortened copy.

## Not yet tested on a real Kindle

The logic is tested (168 tests), and the full flows are tested against mocked KOReader screens and a fake TickTick server (376 tests): sidebar, lists, task screen, title and notes edits online and offline, merged edits, failed uploads, and the Inbox. The OAuth script is tested against a fake server. What has not been run is the plugin inside real KOReader on a real Kindle, and the real TickTick API. On first run, check:

1. **Tools → TickTick** opens a task list. If not, look at `koreader/crash.log`.
2. Tap **Sync now**; the counts fill in. If it says it could not reach TickTick, check Wi-Fi and the clock.
3. Complete a throwaway task and confirm it disappears in TickTick on your phone.
4. Rename a throwaway task and edit its notes; confirm both changed on your phone. Then clear the notes completely and check they stay empty (I have not confirmed the API accepts an empty value).
5. Change a throwaway task's due date and priority on the Kindle and check both on your phone. Then **Remove due date** and check it really has none (also not confirmed that the API accepts an empty value).
6. Move a throwaway task to another list, and to and from the Inbox; check on your phone.
7. Add a task from Today and from a list, tick a checklist item, and delete a throwaway task; check each on your phone.
8. Sync, then compare the sidebar's list order and folders with the phone app. Set a time on a task's due date and add a checklist item; check both on your phone.
9. "Today" matches what TickTick shows. If it is off by a day around midnight, set the time zone offset (Settings → Time zone).

If something fails, send me the message on screen and the last lines of `crash.log`.

## License

AGPL-3.0, the same license as KOReader. See [LICENSE](LICENSE).
