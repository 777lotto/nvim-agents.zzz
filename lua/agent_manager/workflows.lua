local Workflows = {}
Workflows.__index = Workflows

local completed = { merged = true, satisfied = true, completed = true }
local active = { running = true, verifying = true, merging = true, reviewed = true }

local function inline(value)
  return tostring(value or ""):gsub("[%z\r\n]", " ")
end

local function valid(window)
  return window and vim.api.nvim_win_is_valid(window)
end

function Workflows.new(view, opts, sessions)
  return setmetatable({
    view = view, opts = opts, sessions = sessions,
    snapshot = { programs = {}, errors = {} }, expanded = {}, rows = {},
    buffers = {}, windows = {}, generation = 0,
  }, Workflows)
end

function Workflows:_buffer(name)
  if self.buffers[name] and vim.api.nvim_buf_is_valid(self.buffers[name]) then
    return self.buffers[name]
  end
  local buffer = vim.api.nvim_create_buf(false, true)
  self.buffers[name] = buffer
  vim.api.nvim_buf_set_name(buffer, "agent-manager://workflows/" .. name)
  vim.bo[buffer].buftype = "nofile"
  vim.bo[buffer].bufhidden = "hide"
  vim.bo[buffer].swapfile = false
  vim.bo[buffer].filetype = "agent-manager"
  local function map(key, callback, description)
    vim.keymap.set("n", key, callback, { buffer = buffer, silent = true, desc = description })
  end
  map("gs", self.sessions, "Show standalone sessions")
  map("gw", function() self:open() end, "Show workflows")
  map("q", function() self.view:close() end, "Close Agent Manager")
  map("gr", function() self:refresh(true) end, "Refresh workflow and selected session")
  map("<CR>", function() self:select() end, "Inspect task or session")
  map("l", function() self:select(true) end, "Expand task sessions")
  map("h", function()
    if vim.api.nvim_get_current_win() ~= self.windows.checklist then return end
    local row = self.rows[vim.api.nvim_win_get_cursor(0)[1]]
    if row then self.expanded[row.key] = nil; self:render() end
  end, "Collapse task sessions")
  map("<Tab>", function()
    local target = vim.api.nvim_get_current_win() == self.windows.checklist
      and self.windows.detail or self.windows.checklist
    if valid(target) then vim.api.nvim_set_current_win(target) end
  end, "Switch workflow pane")
  return buffer
end

function Workflows:layout()
  local view = self.view
  if not view.tab or not vim.api.nvim_tabpage_is_valid(view.tab)
      or vim.api.nvim_get_current_tabpage() ~= view.tab then return end
  local windows = vim.api.nvim_tabpage_list_wins(view.tab)
  vim.api.nvim_set_current_win(windows[1])
  for index = 2, #windows do pcall(vim.api.nvim_win_close, windows[index], true) end
  self.windows = { checklist = windows[1] }
  vim.api.nvim_win_set_buf(windows[1], self:_buffer("checklist"))
  vim.cmd(vim.o.columns >= 100 and "botright vertical split" or "belowright split")
  self.windows.detail = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(self.windows.detail, self:_buffer("detail"))
  for _, window in pairs(self.windows) do
    vim.wo[window].wrap = true
    vim.wo[window].number = false
    vim.wo[window].relativenumber = false
    vim.wo[window].winfixheight = false
    vim.wo[window].winfixwidth = false
    vim.wo[window].cursorline = true
  end
  view.windows = {}
  vim.api.nvim_set_current_win(self.windows.checklist)
end

function Workflows:open()
  self.view.workspace_mode = "workflows"
  self:layout()
  self:render()
  self:refresh()
  if not self.timer then
    self.timer = vim.uv.new_timer()
    self.timer:start(self.opts.refresh_ms, self.opts.refresh_ms, vim.schedule_wrap(function()
      if self.view.workspace_mode == "workflows" and self.view.tab then self:refresh() end
    end))
  end
end

function Workflows:request(action, arguments, callback)
  if not self.opts.python then
    callback(nil, "Install the Agent Manager workflow runtime or configure workflows.python")
    return
  end
  local argv = { self.opts.python, "-I", "-m", "agent_manager_workflows", action }
  if self.opts.root then vim.list_extend(argv, { "--root", self.opts.root }) end
  vim.list_extend(argv, arguments or {})
  local ok, process = pcall(vim.system, argv, { text = true, timeout = 15000 }, function(result)
    vim.schedule(function()
      if self.closed then return end
      local decoded, value = pcall(vim.json.decode, result.stdout or "")
      if result.code ~= 0 or not decoded or type(value) ~= "table" or value.version ~= 1 then
        callback(nil, "Workflow observer unavailable; the queue process is unaffected")
      else
        callback(value)
      end
    end)
  end)
  if not ok then callback(nil, "Could not start workflow observer") end
  return ok and process or nil
end

function Workflows:refresh(with_history)
  if self.refreshing then return end
  self.refreshing = true
  self:request("inspect", {}, function(snapshot, err)
    self.refreshing = false
    self.error = err
    if snapshot then
      self.snapshot = snapshot
      if self.selected then
        for _, program in ipairs(snapshot.programs) do
          for _, task in ipairs(program.tasks) do
            local key = program.repository .. "/" .. program.program .. "/" .. task.id
            if key == self.selected.key then
              if active[self.selected.task.status] and not active[task.status] then with_history = true end
              self.selected.task = task
              if self.selected.follow_latest then
                local latest = task.attempts[#task.attempts]
                if latest and (not self.selected.attempt or latest.id ~= self.selected.attempt.id) then
                  self.generation = self.generation + 1
                  self.messages, self.notice, self.history_at = nil, nil, nil
                  with_history = true
                end
                self.selected.attempt = latest
              else
                for _, attempt in ipairs(task.attempts or {}) do
                  if self.selected.attempt and attempt.id == self.selected.attempt.id then
                    self.selected.attempt = attempt
                  end
                end
              end
            end
          end
        end
      end
    end
    self:render()
    if self.selected and (with_history or (active[self.selected.task.status]
        and (not self.history_at or vim.uv.now() - self.history_at >= 5000))) then
      self:load_history()
    end
  end)
end

function Workflows:select(expand_only)
  if vim.api.nvim_get_current_win() ~= self.windows.checklist then return end
  local row = self.rows[vim.api.nvim_win_get_cursor(0)[1]]
  if not row then return end
  self.expanded[row.key] = true
  row.follow_latest = row.attempt == nil
  self.selected = row
  self.messages = nil
  self.notice = nil
  self.generation = self.generation + 1
  if not row.attempt then row.attempt = row.task.attempts[#row.task.attempts] end
  self:render()
  if not expand_only then self:load_history() end
end

function Workflows:load_history()
  local row = self.selected
  if not row or not row.attempt or self.history_pending then return end
  self.history_pending = true
  local generation = self.generation
  self:request("history", {
    "--repository", row.program.repository, "--program", row.program.program,
    "--task", row.task.id, "--attempt", row.attempt.id,
  }, function(result, err)
    self.history_pending = false
    if generation ~= self.generation then self:load_history(); return end
    self.history_at = vim.uv.now()
    self.messages = result and result.messages or nil
    self.notice = err or (result and result.notice)
    self:render()
  end)
end

function Workflows:set_lines(name, lines)
  local buffer = self:_buffer(name)
  vim.bo[buffer].modifiable = true
  vim.api.nvim_buf_set_lines(buffer, 0, -1, false, lines)
  vim.bo[buffer].modifiable = false
  return buffer
end

function Workflows:render()
  if self.view.workspace_mode ~= "workflows" or not self.view.tab then return end
  local lines = { " WORKFLOWS   ·   gs Sessions", " Enter inspect · l/h expand/collapse · gr refresh", "" }
  local highlights = {}
  self.rows = {}
  if self.error then table.insert(lines, " " .. self.error) end
  for _, program in ipairs(self.snapshot.programs or {}) do
    local count = 0
    for _, task in ipairs(program.tasks) do if completed[task.status] then count = count + 1 end end
    table.insert(lines, string.format(" %s / %s · %d/%d complete%s", program.repository,
      program.program, count, #program.tasks, program.control.paused and " · paused" or ""))
    for _, task in ipairs(program.tasks) do
      local key = program.repository .. "/" .. program.program .. "/" .. task.id
      local mark = completed[task.status] and "x" or (active[task.status] and ">"
        or (task.status == "pending" or task.status == "ready") and " " or "!")
      table.insert(lines, string.format(" [%s] %s · %s", mark, inline(task.goal:match("[^\n]*")), task.status))
      self.rows[#lines] = { key = key, task = task, program = program }
      if completed[task.status] or active[task.status] then
        table.insert(highlights, { #lines - 1, completed[task.status]
          and "AgentManagerStatusSuccess" or "AgentManagerStatusWaiting" })
      end
      if self.expanded[key] or active[task.status] then
        for _, attempt in ipairs(task.attempts or {}) do
          table.insert(lines, string.format("     %s · %s · %s", attempt.id,
            inline(attempt.provider), inline(attempt.session_id or "identity unavailable")))
          self.rows[#lines] = { key = key, task = task, program = program, attempt = attempt }
          if active[task.status] and attempt == task.attempts[#task.attempts] then
            table.insert(highlights, { #lines - 1, "AgentManagerStatusWaiting" })
          end
        end
      elseif #task.attempts > 0 then
        local attempt = task.attempts[#task.attempts]
        table.insert(lines, "     " .. #task.attempts .. " sessions · " .. inline(attempt.session_id or attempt.id))
        self.rows[#lines] = { key = key, task = task, program = program, attempt = attempt }
      end
    end
    table.insert(lines, "")
  end
  if #(self.snapshot.programs or {}) == 0 then table.insert(lines, " No workflow programs found") end
  for _, err in ipairs(self.snapshot.errors or {}) do table.insert(lines, " " .. inline(err)) end
  local buffer = self:set_lines("checklist", lines)
  vim.api.nvim_buf_clear_namespace(buffer, self.view.namespace, 0, -1)
  for _, highlight in ipairs(highlights) do
    vim.api.nvim_buf_add_highlight(buffer, self.view.namespace, highlight[2], highlight[1], 0, -1)
  end
  local detail = { " TASK / SESSION · read-only", "" }
  local row = self.selected
  if row then
    table.insert(detail, " " .. row.task.id .. " · " .. row.task.status)
    table.insert(detail, " " .. inline(row.task.summary or row.task.goal))
    if row.task.heartbeat and row.task.heartbeat.at then
      table.insert(detail, " " .. inline(row.task.heartbeat.phase) .. " · heartbeat "
        .. inline(row.task.heartbeat.at))
    end
    if #(row.task.depends_on or {}) > 0 then
      table.insert(detail, " Depends on: " .. table.concat(row.task.depends_on, ", "))
    end
    if row.task.pr_number then table.insert(detail, " PR #" .. row.task.pr_number) end
    for _, evidence in ipairs(row.task.evidence or {}) do table.insert(detail, " " .. inline(evidence)) end
    if row.attempt then
      table.insert(detail, "")
      table.insert(detail, " " .. row.attempt.id .. " · " .. inline(row.attempt.session_id))
      table.insert(detail, " " .. inline(row.attempt.summary))
      for _, evidence in ipairs(row.attempt.evidence or {}) do table.insert(detail, " " .. inline(evidence)) end
      for _, finding in ipairs(row.attempt.findings or {}) do table.insert(detail, " Finding: " .. inline(finding)) end
    end
    for _, message in ipairs(self.messages or {}) do
      table.insert(detail, "")
      table.insert(detail, " " .. inline(message.role))
      vim.list_extend(detail, vim.split(message.text:gsub("%z", "�"), "\n", { plain = true }))
    end
    if self.notice then table.insert(detail, " " .. self.notice) end
  else
    table.insert(detail, " Select a task to inspect its work, evidence, and sessions.")
  end
  self:set_lines("detail", detail)
end

function Workflows:teardown()
  self.closed = true
  if self.timer then self.timer:stop(); self.timer:close(); self.timer = nil end
  for _, buffer in pairs(self.buffers) do
    if vim.api.nvim_buf_is_valid(buffer) then vim.api.nvim_buf_delete(buffer, { force = true }) end
  end
end

return Workflows
