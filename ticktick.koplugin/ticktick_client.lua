--[[--
Minimal TickTick Open API client. The HTTP transport and JSON codec are
injected, so this file has no KOReader dependencies and can be tested offline.

transport(method, url, headers, body) -> code, body_string
                                      or nil, error_message   (network failure)

Every call returns  result  or  nil, kind, detail
where kind is "network" | "auth" | "http" | "json" | "nodata".
]]

local Model = require("ticktick_model")

local Client = {}
Client.__index = Client

Client.DEFAULT_BASE_URL = "https://api.ticktick.com/open/v1"

function Client:new(opts)
    local o = {
        base_url = (opts.base_url or Client.DEFAULT_BASE_URL):gsub("/+$", ""),
        token = opts.token,
        transport = opts.transport,
        json = opts.json,
    }
    return setmetatable(o, self)
end

function Client:request(method, path, body)
    if not self.token or self.token == "" then return nil, "auth", "no token" end
    local headers = {
        ["Authorization"] = "Bearer " .. self.token,
        ["Accept"] = "application/json",
    }
    local payload
    if body ~= nil then
        payload = self.json.encode(body)
        headers["Content-Type"] = "application/json"
    end
    if method == "POST" or method == "PUT" then
        headers["Content-Length"] = tostring(payload and #payload or 0)
    end
    local code, resp = self.transport(method, self.base_url .. path, headers, payload)
    if not code then return nil, "network", resp end
    if code == 401 or code == 403 then return nil, "auth", code end
    if code < 200 or code >= 300 then return nil, "http", code end
    if resp == nil or resp == "" then return true end
    local ok, data = pcall(self.json.decode, resp)
    if not ok or data == nil then return nil, "json", resp:sub(1, 80) end
    return Model.fixTextDeep(data) -- emoji: see Model.fixSurrogates
end

--- Open (non-archived, non-note) projects: array of {id, name}.
function Client:listProjects()
    local data, kind, detail = self:request("GET", "/project")
    if not data then return nil, kind, detail end
    if type(data) ~= "table" then return nil, "json", "projects not a list" end
    local out = {}
    for _, p in ipairs(data) do
        if type(p) == "table" and type(p.id) == "string" and p.closed ~= true and p.kind ~= "NOTE" then
            out[#out + 1] = {
                id = p.id, name = type(p.name) == "string" and p.name or p.id,
                group_id = type(p.groupId) == "string" and p.groupId or nil, -- folder, if any
                sort_order = type(p.sortOrder) == "number" and p.sortOrder or nil,
            }
        end
    end
    return out
end

--- Undone tasks in one project, as slim tasks.
function Client:projectTasks(project_id, project_name)
    local data, kind, detail = self:request("GET", "/project/" .. project_id .. "/data")
    if not data then return nil, kind, detail end
    local out = {}
    local tasks = type(data) == "table" and data.tasks
    if type(tasks) == "table" then
        for _, t in ipairs(tasks) do
            if type(t) == "table" then
                local slim = Model.slimTask(t, project_name)
                if slim.id then
                    slim.project_id = slim.project_id or project_id
                    out[#out + 1] = slim
                end
            end
        end
    end
    return out
end

--- One task, fetched fresh (used before editing notes, to avoid overwriting newer text).
function Client:getTask(project_id, task_id)
    local data, kind, detail = self:request("GET", "/project/" .. project_id .. "/task/" .. task_id)
    if not data then return nil, kind, detail end
    if type(data) ~= "table" or type(data.id) ~= "string" then return nil, "json", "not a task" end
    local slim = Model.slimTask(data)
    slim.project_id = slim.project_id or project_id
    return slim
end

--- Change fields of a task. `fields` uses API names, e.g. {title = "...", content = "..."}.
-- Only the named fields are sent.
function Client:updateTask(project_id, task_id, fields)
    local body = { id = task_id, projectId = project_id }
    for k, v in pairs(fields) do body[k] = v end
    if type(fields.items) == "table" then
        -- Checklist items added on the device have a temporary id: send them without one.
        local items = {}
        for i, it in ipairs(fields.items) do
            local copy = {}
            for k, v in pairs(it) do copy[k] = v end
            if type(copy.id) == "string" and copy.id:sub(1, 6) == "local:" then copy.id = nil end
            items[i] = copy
        end
        body.items = items
    end
    return self:request("POST", "/task/" .. task_id, body)
end

--- Create a task. `fields` uses API names (title, dueDate, ...). Returns the new task, slimmed.
function Client:createTask(project_id, fields)
    local body = { projectId = project_id }
    for k, v in pairs(fields) do body[k] = v end
    local data, kind, detail = self:request("POST", "/task", body)
    if not data then return nil, kind, detail end
    if type(data) ~= "table" or type(data.id) ~= "string" then return nil, "json", "not a task" end
    local slim = Model.slimTask(data)
    slim.project_id = slim.project_id or project_id
    return slim
end

function Client:deleteTask(project_id, task_id)
    return self:request("DELETE", "/project/" .. project_id .. "/task/" .. task_id)
end

--- Move a task to another list (project). POST /task/move takes an array of moves.
-- Source: TickTick's own CLI and community API notes; works for the Inbox too.
function Client:moveTask(from_project_id, to_project_id, task_id)
    return self:request("POST", "/task/move", {
        { fromProjectId = from_project_id, toProjectId = to_project_id, taskId = task_id },
    })
end

function Client:completeTask(project_id, task_id)
    return self:request("POST", "/project/" .. project_id .. "/task/" .. task_id .. "/complete")
end

--- Fetch tasks from every project.
-- @param skip_ids  table project_id -> true: projects not worth fetching
-- @param extra_ids array of project ids not returned by /project (e.g. the Inbox)
-- @param progress  optional function(done, total)
-- @return tasks, projects, failed_count     (or nil, kind, detail on auth/network failure)
function Client:fetchAll(skip_ids, extra_ids, progress)
    skip_ids = skip_ids or {}
    local projects, kind, detail = self:listProjects()
    if not projects then return nil, kind, detail end
    local seen = {}
    for _, p in ipairs(projects) do seen[p.id] = true end
    for _, id in ipairs(extra_ids or {}) do
        if type(id) == "string" and id ~= "" and not seen[id] then
            projects[#projects + 1] = { id = id, name = "Inbox", extra = true }
            seen[id] = true
        end
    end
    local tasks, failed = {}, 0
    local todo = {}
    for _, p in ipairs(projects) do
        if not skip_ids[p.id] then todo[#todo + 1] = p end
    end
    for i, p in ipairs(todo) do
        if progress then progress(i, #todo) end
        local pt, k, d = self:projectTasks(p.id, p.name)
        if pt then
            for _, t in ipairs(pt) do tasks[#tasks + 1] = t end
        elseif k == "auth" or k == "network" then
            return nil, k, d
        else
            failed = failed + 1
        end
    end
    return tasks, projects, failed
end

return Client
