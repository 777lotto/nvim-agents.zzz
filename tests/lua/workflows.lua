return function()
  local Workflows = require("agent_manager.workflows")
  vim.cmd("tabnew")
  local view = {
    tab = vim.api.nvim_get_current_tabpage(),
    namespace = vim.api.nvim_create_namespace("WorkflowTest"),
  }
  local session_switches = 0
  local workflows = Workflows.new(view, { refresh_ms = 2000 }, function()
    session_switches = session_switches + 1
  end)
  local reads = {}
  local snapshot = { version = 1, programs = {
    { repository = "demo", program = "refactor", control = {}, tasks = {
      { id = "done", goal = "Completed work", status = "merged", evidence = { "tests passed" },
        attempts = { { id = "session-001-implement", session_id = "done-session", provider = "codex" } } },
      { id = "active", goal = "Running work", status = "running", attempts = {
        { id = "session-001-implement", session_id = "live-session", provider = "claude" },
      } },
      { id = "next", goal = "Upcoming work", status = "pending", attempts = {} },
    } },
  }, errors = {} }
  workflows.request = function(_, action, args, callback)
    table.insert(reads, { action = action, args = args })
    callback(action == "inspect" and snapshot or {
      version = 1, messages = { { role = "assistant", text = "Live session output" } },
    })
  end
  workflows:open()
  local lines = table.concat(vim.api.nvim_buf_get_lines(workflows.buffers.checklist, 0, -1, false), "\n")
  assert(lines:find("[x] Completed work", 1, true))
  assert(lines:find("[>] Running work", 1, true))
  assert(lines:find("[ ] Upcoming work", 1, true))
  assert(lines:find("done-session", 1, true))
  local row
  for line, item in pairs(workflows.rows) do
    if item.task.id == "active" and item.attempt then row = line end
  end
  vim.api.nvim_set_current_win(workflows.windows.checklist)
  vim.api.nvim_win_set_cursor(0, { assert(row), 0 })
  workflows:select()
  local detail = table.concat(vim.api.nvim_buf_get_lines(workflows.buffers.detail, 0, -1, false), "\n")
  assert(detail:find("Live session output", 1, true))
  assert(reads[#reads].action == "history")
  -- Selecting a task follows its next attempt; selecting an attempt stays pinned.
  for line, item in pairs(workflows.rows) do
    if item.task.id == "active" and not item.attempt then row = line end
  end
  vim.api.nvim_win_set_cursor(0, { assert(row), 0 })
  workflows:select()
  local task = snapshot.programs[1].tasks[2]
  table.insert(task.attempts, { id = "session-002-review", session_id = "review-session", provider = "codex" })
  workflows:refresh()
  assert(workflows.selected.attempt.session_id == "review-session")
  -- Observer actions never attach/resume/start a queue-owned session.
  for _, read in ipairs(reads) do assert(read.action == "inspect" or read.action == "history") end
  local mappings = vim.api.nvim_buf_get_keymap(workflows.buffers.checklist, "n")
  for _, mapping in ipairs(mappings) do
    if mapping.lhs == "gs" then mapping.callback() end
    assert(mapping.lhs ~= "sn" and mapping.lhs ~= "tp")
  end
  assert(session_switches == 1)
  workflows:teardown()
  if vim.api.nvim_tabpage_is_valid(view.tab) and #vim.api.nvim_list_tabpages() > 1 then
    vim.api.nvim_set_current_tabpage(view.tab)
    vim.cmd("tabclose")
  end
end
