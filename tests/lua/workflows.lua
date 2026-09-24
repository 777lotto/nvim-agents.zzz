return function()
  local Workflows = require("agent_manager.workflows")
  vim.cmd("tabnew")
  local view = {
    tab = vim.api.nvim_get_current_tabpage(),
    namespace = vim.api.nvim_create_namespace("WorkflowTest"),
  }
  local session_switches = 0
  local workflows = Workflows.new(view, { python = "/fake/python", refresh_ms = 60000 }, function()
    session_switches = session_switches + 1
  end)
  local reads = {}
  -- Exercise the real JSON decode boundary, including Python's explicit nulls.
  local snapshot = { version = 1, programs = {
    { repository = "demo", program = "refactor", control = { paused = vim.NIL }, tasks = {
      { id = "done", milestone = "R0", goal = "Completed work\nDetailed instructions", status = "merged",
        evidence = { "tests passed" }, pr_number = 42, summary = vim.NIL,
        attempts = { { id = "session-001-implement", session_id = vim.NIL, provider = vim.NIL,
          summary = vim.NIL, outcome = vim.NIL } } },
      { id = "active", milestone = "R1", goal = "Running work", status = "running", pr_number = vim.NIL,
        summary = vim.NIL, heartbeat = { at = vim.NIL, phase = vim.NIL }, attempts = {
          { id = "session-001-implement", session_id = "live-session", provider = "claude" },
        } },
      { id = "next", milestone = "R0", goal = "Upcoming work", status = "pending", attempts = {} },
      { id = "ungrouped", milestone = vim.NIL, goal = "Ungrouped work", status = "blocked", attempts = {} },
    } },
    { repository = "second", program = "refactor", control = {}, tasks = {} },
  }, errors = {} }
  local system = vim.system
  vim.system = function(argv, _, callback)
    assert(argv[2] == "-B", "workflow reads must preserve the immutable runtime")
    local action = argv[6]
    table.insert(reads, { action = action, args = argv })
    callback({ code = 0, stdout = vim.json.encode(action == "inspect" and snapshot or {
      version = 1, messages = { { role = "assistant", text = "Live session output" } }, notice = vim.NIL,
    }) })
    return {}
  end
  local function settle()
    assert(vim.wait(1000, function() return not workflows.refreshing and not workflows.history_pending end))
  end
  local function text(name)
    return table.concat(vim.api.nvim_buf_get_lines(workflows.buffers[name or "checklist"], 0, -1, false), "\n")
  end
  local function focus(kind, id)
    vim.api.nvim_set_current_win(workflows.windows.checklist)
    for line, row in pairs(workflows.rows) do
      if row.kind == kind and (row.key == id or (row.task and row.task.id == id)) then
        vim.api.nvim_win_set_cursor(0, { line, 0 })
        return row
      end
    end
    error("Missing row " .. kind .. " " .. id)
  end
  local function select(kind, id, expand)
    focus(kind, id)
    workflows:select(expand)
    settle()
  end
  local ok, err = pcall(function()
    workflows:open()
    settle()
    assert(text():find("▸ demo / refactor · 1/4 complete", 1, true))
    assert(text():find("▸ second / refactor · 0/0 complete", 1, true))
    assert(not text():find("paused", 1, true))
    assert(not text():find("Running work", 1, true))
    select("program", "demo/refactor")
    assert(text():find("▸ R0 · 1/2 complete", 1, true))
    assert(text():find("▸ R1 · 0/1 complete", 1, true))
    assert(text():find("Other tasks · 0/1 complete", 1, true))
    assert(not text():find("Completed work", 1, true))
    select("phase", "demo/refactor/phase/R0")
    assert(text():find("[x] Completed work", 1, true))
    assert(text():find("[ ] Upcoming work", 1, true))
    assert(not text():find("Detailed instructions", 1, true))
    assert(not text():find("session-001", 1, true))
    select("task", "done")
    assert(text():find("transcript identity unavailable", 1, true))
    assert(text("detail"):find("PR #42", 1, true))
    assert(text("detail"):find("Completed work", 1, true))
    assert(not text("detail"):find("vim.NIL", 1, true))
    select("task", "next")
    assert(text():find("No sessions yet", 1, true))
    assert(not text("detail"):find("Live session output", 1, true))
    select("phase", "demo/refactor/phase/R1")
    assert(not text():find("live-session", 1, true))
    select("task", "active")
    assert(text("detail"):find("Live session output", 1, true))
    assert(not text("detail"):find("PR #", 1, true))
    assert(not text():find("vim.NIL", 1, true))
    -- Tasks follow the next attempt; explicitly selected sessions remain pinned.
    local task = snapshot.programs[1].tasks[2]
    table.insert(task.attempts, { id = "session-002-review", session_id = "review-session", provider = "codex" })
    workflows:refresh()
    settle()
    assert(workflows.selected.attempt.session_id == "review-session")
    select("session", "demo/refactor/task/active/session/session-001-implement")
    workflows:refresh()
    settle()
    assert(workflows.selected.attempt.session_id == "live-session")
    -- h moves from session to task, then collapses, then moves to its phase.
    workflows:collapse()
    assert(workflows.rows[vim.api.nvim_win_get_cursor(0)[1]].kind == "task")
    workflows:collapse()
    assert(not text():find("live-session", 1, true))
    workflows:collapse()
    assert(workflows.rows[vim.api.nvim_win_get_cursor(0)[1]].kind == "phase")
    workflows:collapse()
    workflows:refresh()
    settle()
    assert(not text():find("Running work", 1, true))
    -- Refreshing counts or inserting rows keeps focus on the same tree identity.
    focus("program", "second/refactor")
    snapshot.programs[1].tasks[3].status = "satisfied"
    workflows:refresh()
    settle()
    assert(text():find("R0 · 2/2 complete", 1, true))
    assert(workflows.rows[vim.api.nvim_win_get_cursor(0)[1]].key == "second/refactor")
    select("program", "second/refactor")
    assert(text():find("No tasks yet", 1, true))
    for _, read in ipairs(reads) do assert(read.action == "inspect" or read.action == "history") end
    for _, mapping in ipairs(vim.api.nvim_buf_get_keymap(workflows.buffers.checklist, "n")) do
      if mapping.lhs == "gs" then mapping.callback() end
      assert(mapping.lhs ~= "sn" and mapping.lhs ~= "tp")
    end
    assert(session_switches == 1)
  end)
  vim.system = system
  workflows:teardown()
  if vim.api.nvim_tabpage_is_valid(view.tab) and #vim.api.nvim_list_tabpages() > 1 then
    vim.api.nvim_set_current_tabpage(view.tab)
    vim.cmd("tabclose")
  end
  assert(ok, err)
end
