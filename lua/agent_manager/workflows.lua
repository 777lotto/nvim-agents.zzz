local Workflows = {}
Workflows.__index = Workflows

local completed = { merged = true, satisfied = true, completed = true }
local active = { running = true, verifying = true, merging = true, reviewed = true }

local function inline(value)
  return tostring(value ~= vim.NIL and value or ""):gsub("[%z\r\n]", " ")
end

local function valid(window)
  return window and vim.api.nvim_win_is_valid(window)
end

local function session_metadata(attempt, lines)
  local model = inline(attempt.model)
  local provider = inline(attempt.provider)
  table.insert(lines, " Model: " .. (model ~= "" and model or "not recorded")
    .. (provider ~= "" and " · " .. provider or ""))
  local usage = type(attempt.usage) == "table" and attempt.usage or {}
  local function count(key)
    local value = usage[key]
    if type(value) == "number" and value >= 0 and value < math.huge and value % 1 == 0 then
      return string.format("%.0f", value)
    end
    return "not reported"
  end
  table.insert(lines, " Tokens (session): " .. count("input_tokens") .. " input · "
    .. count("output_tokens") .. " output")
  table.insert(lines, " Cached input: " .. count("cached_input_tokens") .. " (included in input)")
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
  vim.bo[buffer].filetype = name == "detail" and "agent-manager-conversation"
    or name == "checklist" and "agent-manager-agents" or "agent-manager-" .. name
  vim.b[buffer].agent_manager = { plugin_id = "agent.manager", pane = "workflow_" .. name }
  if name == "checklist" or name == "detail" then
    local enabled = self.view.opts == nil or self.view.opts.conversation_markdown ~= false
    vim.b[buffer].agent_manager_markdown = enabled
    if enabled then
      pcall(vim.treesitter.language.register, "markdown", vim.bo[buffer].filetype)
      pcall(vim.treesitter.start, buffer, "markdown")
    end
  end
  local function map(key, callback, description)
    vim.keymap.set("n", key, callback, { buffer = buffer, silent = true, desc = description })
  end
  map("gs", self.sessions, "Show standalone sessions")
  map("gw", function() self:open() end, "Show workflows")
  map("1", self.sessions, "Show session directory")
  map("2", function() self.view:focus("agents") end, "Show workflow directory")
  map("q", function() self.view:close() end, "Close Agent Manager")
  map("gp", function() self:toggle_provider() end, "Toggle provider suite after active sessions finish")
  map("gr", function() self:refresh(true) end, "Refresh workflow and selected session")
  map("<CR>", function() self:select() end, "Toggle workflow/phase or inspect task/session")
  map("l", function() self:select(true) end, "Expand workflow, phase, or task")
  map("h", function() self:collapse() end, "Collapse row or go to parent")
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
  if not view._build_layout then
    local windows = vim.api.nvim_tabpage_list_wins(view.tab)
    self.windows = { checklist = windows[1] }
    vim.api.nvim_set_current_win(windows[1])
    vim.cmd("botright vertical split")
    self.windows.detail = vim.api.nvim_get_current_win()
  else
    view:_build_layout("agents")
    if not view.windows.agents then
      vim.api.nvim_set_current_win(view.windows.conversation)
      vim.cmd("topleft vertical split")
      view.windows.agents = vim.api.nvim_get_current_win()
      vim.api.nvim_win_set_width(view.windows.agents, view.opts.agent_width or 28)
    end
    self.windows = { checklist = view.windows.agents, detail = view.windows.conversation }
  end
  vim.api.nvim_win_set_buf(self.windows.checklist, self:_buffer("checklist"))
  vim.api.nvim_win_set_buf(self.windows.detail, self:_buffer("detail"))
  for name, window in pairs(self.windows) do
    if view.style_pane then
      view:style_pane(window, "workflow_" .. name, true)
    else
      vim.wo[window].wrap = true
      vim.wo[window].linebreak = true
      vim.wo[window].number = false
      vim.wo[window].relativenumber = false
      vim.wo[window].cursorline = true
    end
    vim.wo[window].winfixheight = false
    vim.wo[window].winfixwidth = false
  end
  vim.api.nvim_set_current_win(self.windows.checklist)
end

function Workflows:open()
  self.view.workspace_mode = "workflows"
  self.view.expanded = nil
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
  local argv = { self.opts.python, "-B", "-I", "-m", "agent_manager_workflows", action }
  if self.opts.root then vim.list_extend(argv, { "--root", self.opts.root }) end
  vim.list_extend(argv, arguments or {})
  local ok, process = pcall(vim.system, argv, { text = true, timeout = 15000 }, function(result)
    vim.schedule(function()
      if self.closed then return end
      local decoded, value = pcall(vim.json.decode, result.stdout or "", { luanil = { object = true, array = true } })
      if result.code ~= 0 or not decoded or type(value) ~= "table" or value.version ~= 1 then
        callback(nil, action == "toggle-provider"
          and "Provider switch failed; check the installed queue supports manual switching, then refresh"
          or "Workflow observer unavailable; the queue process is unaffected")
      else
        callback(value)
      end
    end)
  end)
  if not ok then callback(nil, "Could not start workflow observer") end
  return ok and process or nil
end

function Workflows:toggle_provider()
  if self.provider_pending then return end
  local row
  if vim.api.nvim_get_current_win() == self.windows.checklist then
    row = self.rows[vim.api.nvim_win_get_cursor(0)[1]]
  else
    row = self.selected
  end
  local program = row and row.program
  if not program then
    vim.notify("Select a workflow, phase, task, or session first", vim.log.levels.INFO)
    return
  end
  if not program.provider_switch_available then
    vim.notify("This workflow has no provider failover policy", vim.log.levels.INFO)
    return
  end
  self.provider_pending = true
  self:request("toggle-provider", { "--repository", program.repository, "--program", program.program }, function(value, err)
    self.provider_pending = false
    if err then
      vim.notify(err, vim.log.levels.ERROR)
    else
      program.provider_control = value.provider_control
      self:render()
      self:refresh()
    end
  end)
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
            local key = program.repository .. "/" .. program.program .. "/task/" .. task.id
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
  if row.kind == "program" or row.kind == "phase" then
    self.expanded[row.key] = expand_only or not self.expanded[row.key] or nil
    self:render()
    return
  end
  self.expanded[row.task_key] = true
  self.selected = vim.tbl_extend("force", {}, row, {
    key = row.task_key, follow_latest = row.kind == "task",
  })
  self.messages, self.notice, self.history_at = nil, nil, nil
  self.generation = self.generation + 1
  if not self.selected.attempt then
    self.selected.attempt = row.task.attempts[#row.task.attempts]
  end
  self:render()
  if not expand_only then self:load_history() end
end

function Workflows:collapse()
  if vim.api.nvim_get_current_win() ~= self.windows.checklist then return end
  local row = self.rows[vim.api.nvim_win_get_cursor(0)[1]]
  if not row then return end
  if self.expanded[row.key] then
    self.expanded[row.key] = nil
    self:render()
  elseif row.parent then
    for line, parent in pairs(self.rows) do
      if parent.key == row.parent then
        vim.api.nvim_win_set_cursor(self.windows.checklist, { line, 0 })
        return
      end
    end
  end
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
  vim.bo[buffer].modified = false
  return buffer
end

function Workflows:render()
  if self.view.workspace_mode ~= "workflows" or not self.view.tab then return end
  local cursor = valid(self.windows.checklist) and vim.api.nvim_win_get_cursor(self.windows.checklist)
  local cursor_row = cursor and self.rows[cursor[1]]
  local lines = { "## 1 SESSIONS  ·  2 WORKFLOWS", " Enter toggle/inspect · l/h expand/parent · gr refresh · gp provider suite", "" }
  local highlights = {}
  local span_highlights = {}
  self.rows = {}
  local function add(text, row, highlight)
    table.insert(lines, text)
    self.rows[#lines] = row
    if highlight then table.insert(highlights, { #lines - 1, highlight }) end
  end
  local function marker(key) return self.expanded[key] and "▾" or "▸" end
  if self.error then table.insert(lines, " " .. self.error) end
  for _, program in ipairs(self.snapshot.programs or {}) do
    local program_key = program.repository .. "/" .. program.program
    local count, phases, by_phase = 0, {}, {}
    for _, task in ipairs(program.tasks) do
      local milestone = inline(task.milestone)
      local phase = by_phase[milestone]
      if not phase then
        phase = { name = milestone ~= "" and milestone or "Other tasks", tasks = {}, count = 0,
          key = program_key .. "/phase/" .. milestone }
        by_phase[milestone] = phase
        table.insert(phases, phase)
      end
      table.insert(phase.tasks, task)
      if completed[task.status] then count = count + 1; phase.count = phase.count + 1 end
    end
    local provider_control = program.provider_control or {}
    local provider_status = ""
    if program.provider_switch_available then
      provider_status = " · suite " .. inline(provider_control.preferred_provider or "automatic")
      if provider_control.pending_provider and provider_control.pending_provider ~= vim.NIL then
        provider_status = provider_status .. " → " .. inline(provider_control.pending_provider) .. " after sessions finish (gp cancel)"
      elseif provider_control.last_event == "canceled-session-limit" then
        provider_status = provider_status .. " · switch canceled: session limit"
      end
    end
    add(string.format(" %s **%s / %s** · %d/%d complete%s", marker(program_key), inline(program.repository),
      inline(program.program), count, #program.tasks, (program.control.paused == true and " · paused" or "") .. provider_status),
      { key = program_key, kind = "program", program = program })
    if self.expanded[program_key] then
      for phase_index, phase in ipairs(phases) do
        local phase_last = phase_index == #phases
        local phase_prefix = phase_last and "   " or " │ "
        add(string.format(" %s %s **%s** · %d/%d complete", phase_last and "└─" or "├─",
          marker(phase.key), phase.name, phase.count, #phase.tasks),
          { key = phase.key, parent = program_key, kind = "phase", program = program })
        if self.expanded[phase.key] then
          for task_index, task in ipairs(phase.tasks) do
            local task_last = task_index == #phase.tasks
            local key = program_key .. "/task/" .. task.id
            local mark = completed[task.status] and "x" or (active[task.status] and ">"
              or (task.status == "pending" or task.status == "ready") and " " or "!")
            local highlight = completed[task.status] and "AgentManagerStatusSuccess"
              or active[task.status] and "AgentManagerStatusWaiting" or nil
            add(string.format(" %s%s %s [%s] *%s* · %s · %d sessions", phase_prefix,
              task_last and "└─" or "├─", marker(key), mark,
              inline(type(task.goal) == "string" and task.goal:match("[^\n]*") or ""),
              inline(task.status), #task.attempts),
              { key = key, task_key = key, parent = phase.key, kind = "task", task = task, program = program }, highlight)
            if self.expanded[key] then
              for index, attempt in ipairs(task.attempts) do
                local state = inline(attempt.outcome)
                if state == "" then
                  state = active[task.status] and index == #task.attempts and "active" or "recorded"
                end
                local identity = inline(attempt.session_id)
                local lead = string.format(" %s%s%s ", phase_prefix,
                  task_last and "   " or "│  ", index == #task.attempts and "└─" or "├─")
                local provider = attempt.provider == "claude" and "◆" or "●"
                local badge = state == "active" and "●" or state == "failed" and "×" or "○"
                add(string.format("%s%s %s · %s · %s", lead, provider, badge,
                  inline(attempt.id), identity ~= "" and identity or "transcript identity unavailable"),
                  { key = key .. "/session/" .. attempt.id, task_key = key, parent = key, kind = "session",
                    task = task, program = program, attempt = attempt },
                  active[task.status] and index == #task.attempts and "AgentManagerStatusWaiting" or nil)
                span_highlights[#span_highlights + 1] = { #lines - 1, #lead,
                  #lead + #provider, attempt.provider == "claude" and "AgentManagerProviderClaude"
                    or "AgentManagerProviderCodex" }
                span_highlights[#span_highlights + 1] = { #lines - 1,
                  #lead + #provider + 1, #lead + #provider + 1 + #badge,
                  state == "active" and "AgentManagerStatusSuccess" or "AgentManagerMuted" }
              end
              if #task.attempts == 0 then table.insert(lines, "       No sessions yet") end
            end
          end
        end
      end
      if #program.tasks == 0 then table.insert(lines, "   No tasks yet") end
    end
    table.insert(lines, "")
  end
  if #(self.snapshot.programs or {}) == 0 then table.insert(lines, " No workflow programs found") end
  for _, err in ipairs(self.snapshot.errors or {}) do table.insert(lines, " " .. inline(err)) end
  local buffer = self:set_lines("checklist", lines)
  if cursor_row then
    for line, row in pairs(self.rows) do
      if row.key == cursor_row.key then
        vim.api.nvim_win_set_cursor(self.windows.checklist, { line, cursor[2] })
        break
      end
    end
  end
  vim.api.nvim_buf_clear_namespace(buffer, self.view.namespace, 0, -1)
  for _, highlight in ipairs(highlights) do
    vim.api.nvim_buf_add_highlight(buffer, self.view.namespace, highlight[2], highlight[1], 0, -1)
  end
  for _, highlight in ipairs(span_highlights) do
    vim.api.nvim_buf_add_highlight(buffer, self.view.namespace, highlight[4],
      highlight[1], highlight[2], highlight[3])
  end
  local detail = { "## TASK / SESSION", "" }
  local detail_highlights = {}
  local row = self.selected
  if row then
    table.insert(detail, "### " .. inline(row.task.id) .. " · " .. inline(row.task.status))
    if row.attempt then session_metadata(row.attempt, detail) end
    table.insert(detail, " " .. inline(row.task.summary ~= vim.NIL and row.task.summary or row.task.goal))
    if type(row.task.heartbeat) == "table" and row.task.heartbeat.at
        and row.task.heartbeat.at ~= vim.NIL then
      table.insert(detail, " " .. inline(row.task.heartbeat.phase) .. " · heartbeat "
        .. inline(row.task.heartbeat.at))
    end
    if #(row.task.depends_on or {}) > 0 then
      table.insert(detail, " Depends on: " .. table.concat(row.task.depends_on, ", "))
    end
    if type(row.task.pr_number) == "number" then table.insert(detail, " PR #" .. row.task.pr_number) end
    for _, evidence in ipairs(row.task.evidence or {}) do table.insert(detail, " " .. inline(evidence)) end
    if row.attempt then
      table.insert(detail, "")
      table.insert(detail, "### " .. inline(row.attempt.id) .. " · " .. inline(row.attempt.session_id))
      table.insert(detail, " " .. inline(row.attempt.summary))
      for _, evidence in ipairs(row.attempt.evidence or {}) do table.insert(detail, " " .. inline(evidence)) end
      for _, finding in ipairs(row.attempt.findings or {}) do table.insert(detail, " Finding: " .. inline(finding)) end
    end
    for _, message in ipairs(self.messages or {}) do
      table.insert(detail, "")
      local role = inline(message.role)
      if role ~= "user" then
        local label = role == "assistant" and inline(message.model ~= vim.NIL and message.model
          or (row.attempt and row.attempt.model)) or role:upper()
        table.insert(detail, "## " .. (label ~= "" and label or "Agent"))
        detail_highlights[#detail_highlights + 1] = { #detail - 1,
          role == "assistant" and "AgentManagerMessageAssistant" or "AgentManagerMessageSystem" }
        table.insert(detail, "")
      end
      local body = tostring(message.text ~= vim.NIL and message.text or ""):gsub("%z", "�")
      for _, line in ipairs(vim.split(body, "\n", { plain = true })) do
        table.insert(detail, " " .. line)
        if role == "user" then detail_highlights[#detail_highlights + 1] = { #detail - 1, "AgentManagerMessageUser" } end
      end
    end
    if self.notice then table.insert(detail, " " .. self.notice) end
  else
    table.insert(detail, " Select a task to inspect its work, evidence, and sessions.")
  end
  local detail_buffer = self:set_lines("detail", detail)
  vim.api.nvim_buf_clear_namespace(detail_buffer, self.view.namespace, 0, -1)
  for _, highlight in ipairs(detail_highlights) do
    vim.api.nvim_buf_add_highlight(detail_buffer, self.view.namespace, highlight[2], highlight[1], 0, -1)
  end
end

function Workflows:teardown()
  self.closed = true
  if self.timer then self.timer:stop(); self.timer:close(); self.timer = nil end
  for _, buffer in pairs(self.buffers) do
    if vim.api.nvim_buf_is_valid(buffer) then vim.api.nvim_buf_delete(buffer, { force = true }) end
  end
end

return Workflows
