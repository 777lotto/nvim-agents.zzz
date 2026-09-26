local root = assert(vim.env.AGENT_MANAGER_TEST_ROOT, "AGENT_MANAGER_TEST_ROOT is required")
vim.opt.runtimepath:prepend(root)
local test_state = vim.fn.tempname()
vim.env.XDG_STATE_HOME = test_state
vim.cmd("helptags " .. vim.fn.fnameescape(root .. "/doc"))

local function assert_equal(actual, expected, message)
  if not vim.deep_equal(actual, expected) then
    error(
      (message or "values differ")
        .. ": expected "
        .. vim.inspect(expected)
        .. ", got "
        .. vim.inspect(actual)
    )
  end
end

local function await(message, predicate)
  local ok = vim.wait(5000, predicate, 10, false)
  if not ok then
    error("timed out waiting for " .. message)
  end
end

local function buffer_contains(buffer, needle)
  local lines = vim.api.nvim_buf_get_lines(buffer, 0, -1, false)
  return table.concat(lines, "\n"):find(needle, 1, true) ~= nil
end

local function buffer_has_line(buffer, expected)
  for _, line in ipairs(vim.api.nvim_buf_get_lines(buffer, 0, -1, false)) do
    if line == expected then
      return true
    end
  end
  return false
end

local function buffer_line_number(buffer, needle)
  for index, line in ipairs(vim.api.nvim_buf_get_lines(buffer, 0, -1, false)) do
    if line:find(needle, 1, true) then
      return index
    end
  end
  return nil
end

local function pure_client_resync_test()
  local Client = require("agent_manager.client")
  local observed_resync = nil
  local client = Client.new({
    mode = "durable",
    command = { "/fixture/agent-manager-broker", "serve-durable" },
    socket = "/fixture/broker.sock",
    on_resync = function(replay)
      observed_resync = replay
    end,
  })
  client.last_sequence = 3
  client.request = function(_, method, params, callback)
    assert_equal(method, "initialize", "resync handshake method")
    assert_equal(params.last_sequence, 3, "resync request cursor")
    callback({
      protocol_version = 1,
      protocol_revision = 1,
      mode = "durable",
      replay = { resync_required = true, oldest = 40, latest = 41 },
    }, nil)
    return 1
  end
  client.notify = function(_, method)
    assert_equal(method, "initialized", "resync initialized notification")
    return true
  end
  client:_begin_initialize()
  assert_equal(client.last_sequence, 41, "resync advances the reconnect cursor")
  assert_equal(observed_resync.latest, 41, "resync callback receives the baseline")
  assert_equal(client.state, "connected", "resync handshake reaches connected state")
end

local function pure_client_revision_mismatch_test()
  local Client = require("agent_manager.client")
  local client = Client.new({
    mode = "embedded",
    command = { "/fixture/stale-agent-manager-broker", "serve" },
  })
  client.request = function(_, _, _, callback)
    callback({
      protocol_version = 1,
      mode = "embedded",
    }, nil)
    return 1
  end
  client.notify = function()
    error("an incompatible broker must not receive initialized")
  end
  client:_begin_initialize()
  assert_equal(client.state, "failed", "stale broker handshake fails closed")
  assert(
    client.last_error.message:find("rebuild", 1, true),
    "stale broker error explains how to restore a matching artifact"
  )
end

local function pure_model_test()
  local Model = require("agent_manager.model")
  local model = Model.new({ max_events = 8 })
  model:apply_state({
    {
      id = "agent-1",
      provider = "codex",
      provider_session_id = "thread-1",
      cwd = "/tmp",
      workspace_strategy = "shared",
      title = "fixture",
      state = "idle",
      pending_approvals = 0,
      capabilities = { { name = "approvals", available = true } },
    },
  })
  assert(model:apply_external_sessions("codex", {
    {
      provider_session_id = "thread-1",
      cwd = "/tmp",
      title = "managed duplicate",
      active = true,
    },
    {
      provider_session_id = "external-codex",
      cwd = "/workspace/repos/alpha/api",
      title = "external fixture",
      active = true,
    },
    {
      provider_session_id = "saved-codex",
      cwd = "/workspace/repos/alpha/api",
      title = "saved fixture",
      active = false,
    },
  }, true))
  assert_equal(#model:external_session_list(), 2, "managed provider sessions are de-duplicated")
  assert_equal(model:list()[1].external_active, true, "duplicate active writer is retained on broker row")
  assert_equal(model:external_session_list()[1].state, "running", "active external session state")
  assert_equal(model:external_session_list()[2].state, "resumable", "saved external session state")
  assert_equal(#model:session_list(), 3, "combined session projection")
  assert(model:apply_workspace_inventory({
    {
      slug = "agent-manager",
      canonical_path = "/workspace/agent-manager",
      base_branch = "bluff",
    },
  }))
  local repositories = model:workspace_list()
  assert_equal(repositories[1].slug, "agent-manager", "workspace inventory projection")
  repositories[1].slug = "corrupted"
  assert_equal(model:workspace_list()[1].slug, "agent-manager", "workspace inventory is defensive")
  assert(model:record_user_input("agent-1", "question", "prompt"))
  assert(model:apply_event({
    sequence = 1,
    agent_id = "agent-1",
    provider = "codex",
    type = "message.delta",
    payload = { delta = "answer" },
  }))
  assert(model:apply_event({
    sequence = 2,
    agent_id = "agent-1",
    provider = "codex",
    type = "tool.started",
    payload = { item = { command = "fixture" } },
  }))
  assert(model:apply_event({
    sequence = 3,
    agent_id = "agent-1",
    provider = "codex",
    type = "approval.requested",
    payload = {
      id = "approval-1",
      choices = { "allow", "deny" },
      tool_name = "Command",
    },
  }))
  assert_equal(model:focused_action().id, "approval-1", "pending approval projection")
  assert(model:apply_event({
    sequence = 4,
    agent_id = "agent-1",
    provider = "codex",
    type = "approval.resolved",
    payload = { id = "approval-1", decision = "allow" },
  }))
  assert_equal(model:focused_action(), nil, "approval resolution")
  assert(model:apply_event({
    sequence = 5,
    agent_id = "agent-1",
    provider = "codex",
    type = "usage.updated",
    payload = { input_tokens = 4, output_tokens = 2 },
  }))
  assert_equal(model:usage_for().input_tokens, 4, "usage projection")
  for _, activity in ipairs(model:activity()) do
    assert(activity.type ~= "usage.updated", "usage updates do not enter the Activity log")
  end
  assert(model:apply_history("agent-1", {
    { id = "u", role = "user", text = "historic" },
    { id = "a", role = "assistant", text = "reply" },
  }))
  assert_equal(model:conversation()[2].text, "reply", "history projection")
  assert(model:record_file_conflict("agent-1", "/tmp/fixture", { bufnr = 1 }))
  assert_equal(#model:file_conflict_list(), 1, "file conflict projection")
  assert(model:resolve_file_conflict("agent-1", "/tmp/fixture", "kept_buffer"))
  assert_equal(#model:file_conflict_list(), 0, "file conflict resolution")
  assert_equal(model:activity()[1].type, "tool.started", "activity projection")
  local snapshot = model:snapshot()
  snapshot.agents[1].state = "corrupted"
  assert_equal(model:list()[1].state, "idle", "snapshots must be defensive")
  assert(model:begin_resync(41))
  assert_equal(model:snapshot().last_sequence, 41, "history resync cursor")
  assert_equal(model:conversation(), {}, "history resync clears stale projection")
  assert(model:apply_event({
    sequence = 42,
    agent_id = "agent-1",
    provider = "codex",
    type = "message.completed",
    payload = { text = "resynced" },
  }))
  assert_equal(model:snapshot().sequence_gap, nil, "history resync closes sequence gap")
  model:set_client_state("disconnected", { message = "fixture disconnect" })
  assert_equal(model:list()[1].state, "disconnected", "disconnect projection")
  assert_equal(model:external_session_list(), {}, "disconnect clears stale external sessions")
  assert_equal(model:pending(), {}, "disconnect clears unactionable requests")
end

local function layout_test()
  local View = require("agent_manager.view")
  assert_equal(View.layout_for(160).mode, "medium", "two pane layout")
  assert_equal(View.layout_for(100).mode, "medium", "medium layout")
  assert_equal(View.layout_for(80).mode, "narrow", "narrow layout")
end

local function directory_markdown_and_bottom_test()
  local columns = vim.o.columns
  vim.o.columns = 160
  local Model = require("agent_manager.model")
  local View = require("agent_manager.view")
  local home = vim.fn.tempname() .. "-agent-manager-directory"
  assert_equal(vim.fn.mkdir(home, "p"), 1)
  home = assert(vim.uv.fs_realpath(home))
  vim.fn.writefile({ "hidden" }, home .. "/note.txt")
  local sessions = {}
  for index = 1, 7 do
    sessions[#sessions + 1] = { provider_session_id = "session-" .. index,
      cwd = home, title = "session " .. index, active = false,
      updated_at = string.format("2026-09-01T00:00:%02dZ", index) }
  end
  local model = Model.new({ max_events = 8 })
  model:apply_external_sessions("codex", sessions, true)
  model:apply_external_sessions("claude", { { provider_session_id = "past-session",
    cwd = home .. "/renamed", title = "past session", active = false } }, true)
  local view = View.new(model, {}, { home = home })
  assert(view:open())
  local buffer = view.buffers.agents
  assert_equal(vim.treesitter.language.get_lang("agent-manager-agents"), "markdown")
  assert(vim.treesitter.highlighter.active[buffer], "directory Markdown parser")
  assert(buffer_contains(buffer, "*Sessions* (7 · first 5)"), "initial session limit")
  assert(buffer_has_line(buffer, "*Sessions* (7 · first 5)"), "flat session group")
  assert(buffer_has_line(buffer, "● ○ · session 7"), "flat session row")
  assert(buffer_has_line(buffer, "---"), "Markdown directory separator")
  assert(buffer_contains(buffer, "session 3") and not buffer_contains(buffer, "session 2"), "only newest five")
  assert(not buffer_contains(buffer, "note.txt"), "files stay hidden")
  local past_row = assert(buffer_line_number(buffer, "renamed/**  [past cwd]"))
  vim.api.nvim_win_set_cursor(view.windows.agents, { past_row, 0 })
  assert_equal(view:_start_context(), false, "historical path cannot start a new session")
  local group = assert(buffer_line_number(buffer, "*Sessions*"))
  vim.api.nvim_win_set_cursor(view.windows.agents, { group, 0 })
  vim.api.nvim_feedkeys(vim.keycode("<CR>"), "x", false)
  assert(vim.wait(1000, function() return buffer_contains(buffer, "session 1") end), "expand all sessions")
  vim.api.nvim_win_set_cursor(view.windows.agents, { group, 0 })
  vim.api.nvim_feedkeys("h", "x", false)
  assert(vim.wait(1000, function() return not buffer_contains(buffer, "session 7") end), "collapse sessions")
  vim.api.nvim_win_set_cursor(view.windows.agents, { group, 0 })
  vim.api.nvim_feedkeys(vim.keycode("<CR>"), "x", false)
  assert(vim.wait(1000, function() return buffer_contains(buffer, "session 3") end), "restore first five")
  assert(view:bottom(2))
  assert_equal(vim.api.nvim_win_get_buf(view.windows.prompt), view.buffers.bottom_help, "shortcuts in bottom window")
  assert(buffer_contains(view.buffers.bottom_help, "sn      start a new session"), "shortcut list visible")
  vim.api.nvim_feedkeys("1", "x", false)
  assert_equal(vim.api.nvim_win_get_buf(view.windows.prompt), view.buffers.prompt, "prompt shortcut switch")
  view:teardown()
  vim.o.columns = columns
  vim.fn.delete(home, "rf")
end

local function unified_workflow_layout_test()
  local Model = require("agent_manager.model")
  local View = require("agent_manager.view")
  local Workflows = require("agent_manager.workflows")
  local columns = vim.o.columns
  vim.o.columns = 160
  local view = View.new(Model.new({ max_events = 8 }), {}, { home = vim.fn.tempname() })
  local workflows = Workflows.new(view, { python = false, refresh_ms = 60000 }, function()
    view.workspace_mode = "sessions"
    view:_build_layout("agents")
    view:render()
  end)
  view.workflows = workflows
  view.actions.workflows = function() workflows:open() end
  assert(view:open())
  view:directory_view(2)
  assert_equal(view.workspace_mode, "workflows")
  assert_equal(vim.api.nvim_win_get_buf(view.windows.agents), workflows.buffers.checklist,
    "workflow tree reuses directory window")
  assert_equal(vim.api.nvim_win_get_buf(view.windows.conversation), workflows.buffers.detail,
    "workflow transcript reuses conversation window")
  assert(vim.api.nvim_win_is_valid(view.windows.prompt), "workflow keeps bottom window")
  vim.api.nvim_set_current_win(view.windows.agents)
  vim.api.nvim_feedkeys("1", "x", false)
  assert_equal(view.workspace_mode, "sessions", "directory 1 returns to sessions")
  assert_equal(vim.api.nvim_win_get_buf(view.windows.agents), view.buffers.agents)
  view:teardown()
  vim.o.columns = columns
end

local function workspace_view_navigation_test()
  local Model = require("agent_manager.model")
  local View = require("agent_manager.view")
  local home = vim.fn.tempname() .. "-agent-manager-home"
  assert_equal(vim.fn.mkdir(home, "p"), 1, "test home creation")
  home = assert(vim.uv.fs_realpath(home), "canonical test home")
  local repository = home .. "/projects/agent-manager"
  assert_equal(vim.fn.mkdir(repository, "p"), 1, "test home repository creation")
  assert_equal(vim.fn.mkdir(home .. "/notes", "p"), 1, "unrelated home directory creation")
  vim.fn.writefile({ "home fixture" }, home .. "/README.txt")
  vim.fn.writefile({ "project fixture" }, repository .. "/project.txt")

  local model = Model.new({ max_events = 8 })
  model:apply_workspace_inventory({
    {
      slug = "agent-manager",
      canonical_path = repository,
      worktree_root = home .. "/worktrees/agent-manager",
    },
  })
  model:apply_state({
    {
      id = "agent-codex",
      provider = "codex",
      provider_session_id = "codex-view",
      cwd = repository,
      workspace_strategy = "shared",
      title = "codex fixture",
      state = "idle",
      capabilities = {},
      updated_at = "2026-09-01T00:02:00Z",
    },
    {
      id = "agent-claude",
      provider = "claude",
      provider_session_id = "claude-view",
      cwd = repository,
      workspace_strategy = "shared",
      title = "claude fixture",
      state = "idle",
      capabilities = {},
      updated_at = 1788221040000,
    },
  })
  local start_context = nil
  local resumed_session = nil
  local deleted_session = nil
  local diff_target = nil
  local view = View.new(model, {
    start = function(context)
      start_context = context
    end,
    resume = function(session)
      resumed_session = session
    end,
    delete_session = function(session)
      deleted_session = session
    end,
    diff = function(target)
      diff_target = target
    end,
  }, { home = home })
  model:apply_external_sessions("codex", {
    {
      provider_session_id = "codex-saved-view",
      cwd = repository,
      title = "saved codex fixture",
      active = false,
      updated_at = "2026-09-01T00:03:00Z",
    },
    {
      provider_session_id = "codex-home-view",
      cwd = "",
      title = "home codex fixture",
      active = false,
      updated_at = "2026-09-01T00:01:00Z",
    },
  }, true)
  assert(view:open())
  view:render()
  local status = view:status()
  assert(buffer_contains(status.buffers.agents, "**" .. home .. "/**"), "Markdown home root label")
  assert(buffer_contains(status.buffers.agents, "notes/"), "unrelated home directory")
  assert(not buffer_contains(status.buffers.agents, "README.txt"), "directory omits files")
  assert(not buffer_contains(status.buffers.agents, "(unknown)"), "blank session cwd uses home")
  assert(buffer_contains(status.buffers.agents, "key · ● Codex · ◆ Claude"), "provider legend")
  assert(buffer_contains(status.buffers.agents, "● active · ○ resume"), "live-state legend")
  assert(buffer_contains(status.buffers.agents, "? check · × ended"), "inactive-state legend")
  assert(buffer_contains(status.buffers.agents, "● ○ · home codex fixture"), "compact Codex row")
  assert(
    not buffer_contains(status.buffers.agents, "· claude fixture"),
    "nested sessions start collapsed"
  )
  assert(not buffer_contains(status.buffers.agents, "project.txt"), "directory files start collapsed")
  assert_equal(view:status().active_pane, "agents", "directory pane receives initial focus")
  assert_equal(vim.api.nvim_get_current_buf(), status.buffers.agents, "directory buffer focus")
  assert(vim.api.nvim_win_is_valid(status.windows.prompt), "persistent prompt window")
  assert_equal(vim.bo[status.buffers.prompt].modifiable, true, "prompt buffer is editable")
  local projects_row = assert(buffer_line_number(status.buffers.agents, "projects/"))
  local notes_row = assert(buffer_line_number(status.buffers.agents, "notes/"))
  assert(projects_row < notes_row, "directories containing sessions sort first")
  local separator_row
  for row = projects_row + 1, notes_row - 1 do
    if vim.api.nvim_buf_get_lines(status.buffers.agents, row - 1, row, false)[1] == "---" then
      separator_row = row
      break
    end
  end
  assert(projects_row < separator_row and separator_row < notes_row,
    "separator divides top-level directory blocks")
  for _, pane in ipairs({ "agents", "conversation" }) do
    assert(view:focus(pane))
    assert_equal(view:status().active_pane, pane, "numbered pane navigation")
  end

  assert(view:focus("agents"))
  vim.api.nvim_win_set_cursor(0, { projects_row, 0 })
  vim.api.nvim_feedkeys("l", "x", false)
  assert(vim.wait(1000, function()
    return buffer_contains(status.buffers.agents, "agent-manager/**  [repo]")
  end), "projects directory expansion")
  assert(
    buffer_contains(status.buffers.agents, "◆ ● · claude fixture"),
    "directory sessions ignore file collapse"
  )
  assert(buffer_contains(status.buffers.agents, "*Sessions* (3)"), "dedicated session group")
  assert(not buffer_contains(status.buffers.agents, "project.txt"), "collapsed directory hides files only")
  local repository_row = assert(
    buffer_line_number(status.buffers.agents, "agent-manager/**  [repo]"),
    "registered repository row"
  )
  vim.api.nvim_win_set_cursor(0, { repository_row, 0 })
  vim.api.nvim_feedkeys("l", "x", false)
  assert(not buffer_contains(status.buffers.agents, "project.txt"), "expanded directory still omits files")
  vim.api.nvim_win_set_cursor(0, { repository_row, 0 })
  vim.api.nvim_feedkeys("h", "x", false)
  assert(vim.wait(1000, function()
    return not buffer_contains(status.buffers.agents, "project.txt")
  end), "directory file collapse")
  assert(buffer_contains(status.buffers.agents, "*Sessions* (3)"), "session group survives file collapse")
  assert(buffer_contains(status.buffers.agents, "◆ ● · claude fixture"), "session rows survive file collapse")
  local session_group_row = assert(buffer_line_number(status.buffers.agents, "*Sessions* (3)"))
  vim.api.nvim_win_set_cursor(0, { session_group_row, 0 })
  vim.api.nvim_feedkeys(vim.keycode("<CR>"), "x", false)
  assert(vim.wait(1000, function()
    return not buffer_contains(status.buffers.agents, "saved codex fixture")
  end), "session group collapse")
  vim.api.nvim_win_set_cursor(0, { session_group_row, 0 })
  vim.api.nvim_feedkeys("l", "x", false)
  assert(vim.wait(1000, function()
    return buffer_contains(status.buffers.agents, "saved codex fixture")
  end), "session group expansion")
  local claude_row = assert(buffer_line_number(status.buffers.agents, "· claude fixture"))
  local saved_row = assert(buffer_line_number(status.buffers.agents, "saved codex fixture"))
  local codex_row = assert(buffer_line_number(status.buffers.agents, "· codex fixture"))
  assert(claude_row < saved_row and saved_row < codex_row, "sessions sort by latest activity")
  vim.api.nvim_win_set_cursor(0, { repository_row, 0 })
  vim.api.nvim_feedkeys("sn", "x", false)
  assert_equal(start_context.repository, "agent-manager", "directory start repository")
  assert_equal(start_context.cwd, repository, "directory start cwd")
  vim.api.nvim_win_set_cursor(0, { repository_row, 0 })
  vim.api.nvim_feedkeys("df", "x", false)
  assert_equal(diff_target.cwd, repository, "directory diff target")
  vim.api.nvim_win_set_cursor(0, { saved_row, 0 })
  vim.api.nvim_feedkeys("ds", "x", false)
  assert_equal(
    deleted_session.provider_session_id,
    "codex-saved-view",
    "saved row delete action"
  )
  vim.api.nvim_win_set_cursor(0, { saved_row, 0 })
  vim.api.nvim_feedkeys(vim.keycode("<CR>"), "x", false)
  assert_equal(resumed_session.provider_session_id, "codex-saved-view", "saved row resume action")
  view:teardown()
  vim.fn.delete(home, "rf")
end

local function conversation_prompt_test()
  local Model = require("agent_manager.model")
  local View = require("agent_manager.view")
  local home = vim.fn.tempname() .. "-agent-manager-prompt"
  assert_equal(vim.fn.mkdir(home, "p"), 1, "prompt test home creation")
  local submitted = nil
  local completed = nil
  local view = View.new(Model.new({ max_events = 8 }), {
    prompt = function(text, callback)
      submitted = text
      completed = callback
      return true
    end,
  }, {
    home = home,
    prompt_min_height = 3,
    prompt_max_height = 12,
  })
  assert(view:open())
  local status = view:status()
  assert_equal(status.active_pane, "agents", "prompt test initial directory focus")
  assert_equal(vim.wo[status.windows.prompt].wrap, true, "prompt wraps")
  assert_equal(vim.wo[status.windows.prompt].linebreak, true, "prompt wraps at words")

  view:set_draft({ provider = "codex", provider_options = {} })
  view:render()
  assert(view:focus_prompt())
  assert_equal(vim.api.nvim_get_current_win(), status.windows.prompt, "prompt window focus")
  assert_equal(vim.api.nvim_get_current_buf(), status.buffers.prompt, "prompt buffer focus")
  vim.cmd("stopinsert")
  local long_prompt = string.rep("wrapped prompt words ", 40)
  vim.api.nvim_buf_set_lines(status.buffers.prompt, 0, -1, false, { long_prompt })
  view:_resize_prompt()
  assert(vim.api.nvim_win_get_height(status.windows.prompt) > 3, "long prompt expands input")
  assert(vim.api.nvim_win_get_height(status.windows.prompt) <= 12, "prompt expansion is capped")
  vim.api.nvim_win_set_cursor(status.windows.prompt, { 1, 0 })
  vim.cmd("redraw")
  local first_row = vim.fn.winline()
  vim.api.nvim_feedkeys(vim.keycode("<Down>"), "xt", false)
  assert_equal(vim.fn.winline(), first_row + 1, "down moves one wrapped screen line")
  vim.api.nvim_feedkeys(vim.keycode("<Up>"), "xt", false)
  assert_equal(vim.fn.winline(), first_row, "up moves one wrapped screen line")
  vim.api.nvim_win_set_cursor(status.windows.prompt, { 1, 8 })
  vim.api.nvim_feedkeys(vim.keycode("i<Down><Esc>"), "xt", false)
  assert_equal(vim.fn.winline(), first_row + 1, "insert down moves one wrapped screen line")
  vim.api.nvim_feedkeys(vim.keycode("i<Up><Esc>"), "xt", false)
  assert_equal(vim.fn.winline(), first_row, "insert up moves one wrapped screen line")
  assert(view:_submit_prompt())
  assert_equal(submitted, long_prompt, "prompt box submits its text")
  assert_equal(
    vim.api.nvim_buf_get_lines(status.buffers.prompt, 0, -1, false),
    { long_prompt },
    "pending prompt remains editable until accepted"
  )
  completed({ accepted = true }, nil)
  assert_equal(
    vim.api.nvim_buf_get_lines(status.buffers.prompt, 0, -1, false),
    { "" },
    "sent prompt clears input"
  )
  assert_equal(vim.api.nvim_win_get_height(status.windows.prompt), 3, "sent prompt resets height")

  local retry_prompt = "keep this prompt after failure"
  vim.api.nvim_buf_set_lines(status.buffers.prompt, 0, -1, false, { retry_prompt })
  assert(view:_submit_prompt())
  completed(nil, { message = "fixture rejection" })
  assert_equal(
    vim.api.nvim_buf_get_lines(status.buffers.prompt, 0, -1, false),
    { retry_prompt },
    "rejected prompt remains available for retry"
  )
  view:teardown()
  vim.fn.delete(home, "rf")
end

local function expanded_panes_test()
  local Model = require("agent_manager.model")
  local View = require("agent_manager.view")
  local columns = vim.o.columns
  vim.o.columns = 180
  local model = Model.new({ max_events = 8 })
  local view = View.new(model, {}, { home = vim.fn.tempname() })
  assert(view:open())
  vim.api.nvim_win_set_width(view.windows.agents, 33)
  local original = {}
  for name, window in pairs(view.windows) do
    original[name] = { vim.api.nvim_win_get_width(window), vim.api.nvim_win_get_height(window) }
  end
  local function keys(value)
    vim.cmd("stopinsert")
    vim.api.nvim_feedkeys(vim.keycode(value), "xt", false)
    vim.cmd("stopinsert")
  end
  -- Mouse/window navigation must expand the actual current window too.
  vim.api.nvim_set_current_win(view.windows.conversation)
  keys("we")
  assert(view:status().expanded)
  assert_equal(view:status().active_pane, "conversation", "expand actual active pane")
  assert_equal(#vim.api.nvim_tabpage_list_wins(view.tab), 2, "conversation keeps prompt")
  keys("w2")
  assert_equal(view:status().active_pane, "conversation", "expanded conversation switch")
  assert_equal(#vim.api.nvim_tabpage_list_wins(view.tab), 2, "expanded conversation retains input")
  vim.api.nvim_buf_set_lines(view.buffers.prompt, 0, -1, false, { "draft survives switches" })
  keys("w1")
  assert_equal(view:status().active_pane, "agents", "expanded agents switch")
  assert_equal(#vim.api.nvim_tabpage_list_wins(view.tab), 1, "agents occupies workspace")
  keys("w2")
  keys("we")
  assert(not view:status().expanded)
  assert_equal(#vim.api.nvim_tabpage_list_wins(view.tab), 3, "two panes and input restored")
  for name, size in pairs(original) do
    local window = view.windows[name]
    assert_equal(
      { vim.api.nvim_win_get_width(window), vim.api.nvim_win_get_height(window) },
      size,
      "restored " .. name .. " dimensions"
    )
  end
  assert(buffer_contains(view.buffers.prompt, "draft survives switches"))
  model.selected_agent_id = "fixture"
  for sequence, payload in ipairs({
    { diff = "@@ -1 +1 @@\n-old\n+new" },
    { changes = { { path = "first.lua", diff = "+first change" } } },
    { item = { changes = { { path = "second.lua", diff = "-second change" } } } },
  }) do
    model:apply_event({
      agent_id = "fixture",
      sequence = sequence,
      type = sequence == 1 and "diff.changed" or "file.changed",
      payload = payload,
    })
  end
  view:render()
  assert_equal(#model:activity(), 3, "file and diff events remain in the model")
  view:show_diff("+workspace change", "WORKSPACE DIFF")
  view:render()
  assert_equal(view:status().active_pane, "conversation", "manual diff focuses transcript pane")
  assert(buffer_contains(view.buffers.conversation, "+workspace change"), "manual diff survives render")
  keys("we")
  keys("w2")
  keys("w2")
  assert(
    buffer_contains(view.buffers.conversation, "+workspace change"),
    "diff survives expanded navigation"
  )
  keys("w1")
  keys("gc")
  assert(not buffer_contains(view.buffers.conversation, "+workspace change"),
    "gc returns from diff to transcript")
  model.focused_action = function()
    return {
      id = "approval-fixture",
      kind = "approval",
      agent_id = "fixture",
      payload = { tool_name = "edit" },
    }
  end
  view:render()
  assert_equal(view:status().active_pane, "decision", "new approval interrupts expanded transcript")
  assert_equal(vim.api.nvim_get_current_buf(), view.buffers.decision, "approval remains accessible")
  keys("we")
  assert_equal(vim.api.nvim_get_current_buf(), view.buffers.decision, "approval survives layout restoration")
  model.focused_action = function()
    return nil
  end
  view:render()
  -- A terminal resize must retain expanded mode and permit a usable restore.
  keys("w2")
  keys("we")
  vim.o.columns = 100
  vim.api.nvim_exec_autocmds("VimResized", {})
  vim.wait(20, function() return false end)
  assert(view:status().expanded, "terminal resize preserves expanded mode")
  keys("we")
  assert_equal(view:status().mode, "medium", "restore adapts to smaller terminal")
  view:close()
  assert(view:open())
  assert(not view:status().expanded, "reopening clears expansion")
  vim.o.columns = 80
  view:_build_layout("agents")
  keys("we")
  assert_equal(view:status().active_pane, "agents", "narrow shared window expands displayed pane")
  keys("we")
  view:teardown()
  vim.o.columns = columns
end

local function which_key_prefix_test()
  local Model = require("agent_manager.model")
  local View = require("agent_manager.view")
  local home = vim.fn.tempname() .. "-agent-manager-which-key"
  assert_equal(vim.fn.mkdir(home, "p"), 1, "which-key test home creation")
  local specs = {}
  local previous_which_key = package.loaded["which-key"]
  package.loaded["which-key"] = {
    add = function(spec)
      vim.list_extend(specs, vim.deepcopy(spec))
    end,
    show = function(opts)
      error("Agent Manager must not call which-key.show() from a keymap: " .. vim.inspect(opts))
    end,
  }
  local view = View.new(Model.new({ max_events = 8 }), {}, { home = home })
  assert(view:open())
  assert(view:focus("agents"))

  local groups = {}
  local buffer = view:status().buffers.agents
  for _, spec in ipairs(specs) do
    if spec.buffer == buffer then
      groups[spec[1]] = spec.group
    end
  end
  assert_equal(groups, {
    a = "agent settings",
    d = "diff / delete",
    g = "go",
    s = "session",
    t = "turn",
  }, "buffer-local which-key groups")
  local prefix_maps = {}
  for _, mapping in ipairs(vim.api.nvim_buf_get_keymap(buffer, "n")) do
    prefix_maps[mapping.lhs] = true
  end
  for _, prefix in ipairs({ "a", "d", "g", "s", "t" }) do
    assert(not prefix_maps[prefix], prefix .. " must be owned by which-key opts.triggers")
  end

  view:teardown()
  package.loaded["which-key"] = previous_which_key
  vim.fn.delete(home, "rf")
end

local function transcript_presentation_test()
  local Model = require("agent_manager.model")
  local View = require("agent_manager.view")
  local model = Model.new({ max_events = 8 })
  model:apply_state({ {
    id = "transcript-agent", provider = "codex", cwd = "/tmp", title = "transcript",
    state = "running", provider_options = { model = "gpt-6-astra" },
  } })
  model:record_user_input("transcript-agent", "my first line\nmy second line", "prompt")
  model:apply_event({
    agent_id = "transcript-agent", sequence = 1, provider = "codex",
    type = "message.completed", payload = { text = "Reply with **Markdown** intact." },
  })
  -- A pending model choice must not relabel the currently running response.
  local view = View.new(model, { provider_options = function() return { model = "next-model" } end }, {
    home = vim.fn.tempname(),
  })
  assert(view:open())
  local buffer = view.buffers.conversation
  assert(buffer_has_line(buffer, " ## gpt-6-astra"), "assistant label names the active model as a heading")
  assert(not buffer_has_line(buffer, " YOU"), "user messages have no speaker heading")
  assert(not buffer_has_line(buffer, " ## YOU"), "user messages have no speaker heading")
  assert(not buffer_has_line(buffer, " ASSISTANT"), "generic assistant heading is removed")
  local label_row = buffer_line_number(buffer, " ## gpt-6-astra")
  local after_label = vim.api.nvim_buf_get_lines(buffer, label_row, label_row + 2, false)
  assert(after_label[1] == "", "a blank line separates the label from the reply")
  assert(after_label[2] == " Reply with **Markdown** intact.", "the reply follows the blank line")
  assert(vim.bo[buffer].filetype == "agent-manager-conversation", "conversation keeps its pane filetype")
  assert(vim.treesitter.language.get_lang("agent-manager-conversation") == "markdown",
    "conversation filetype resolves to the markdown parser")
  assert(vim.treesitter.highlighter.active[buffer], "markdown treesitter highlighting is attached")
  assert(view:status().markdown.active, "view status reports markdown as active")
  local function highlighted(line, group)
    local row = buffer_line_number(buffer, line) - 1
    for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buffer, view.namespace, { row, 0 }, { row, -1 }, { details = true })) do
      if mark[4].hl_group == group then
        return true
      end
    end
    return false
  end
  assert(highlighted("my first line", "AgentManagerMessageUser"), "first user line is purple")
  assert(highlighted("my second line", "AgentManagerMessageUser"), "all user lines are purple")
  assert(highlighted(" ## gpt-6-astra", "AgentManagerMessageAssistant"), "model label is blue")
  assert(not highlighted("Reply with", "AgentManagerMessageAssistant"), "assistant body stays neutral")
  assert(buffer_contains(buffer, "**Markdown**"), "source formatting is preserved")
  model.agents["transcript-agent"].provider_options.model = "another-model"
  model:record_user_input("transcript-agent", "steering text", "steer")
  model:apply_event({
    agent_id = "transcript-agent", sequence = 2, provider = "codex",
    type = "message.delta", payload = { delta = "Another reply" },
  })
  view:render()
  assert(buffer_has_line(buffer, " ## gpt-6-astra"), "completed responses retain their model")
  assert(buffer_has_line(buffer, " ## another-model"), "new response uses the new model")
  assert(not buffer_contains(buffer, "YOU · STEER"), "steering has no YOU heading")
  assert(highlighted("steering text", "AgentManagerMessageUser"), "steering text is purple")
  view:teardown()

  local plain = View.new(model, {}, { home = vim.fn.tempname(), conversation_markdown = false })
  assert(plain:open())
  local plain_buffer = plain.buffers.conversation
  assert(buffer_has_line(plain_buffer, " ## gpt-6-astra"), "labels stay Markdown headings without rendering")
  assert(not vim.treesitter.highlighter.active[plain_buffer], "ui.conversation_markdown=false leaves the parser detached")
  assert(not plain:status().markdown.active, "view status reports markdown as inactive")
  plain:teardown()
  model.conversations["transcript-agent"][2].model = vim.NIL
  model.agents["transcript-agent"].capabilities = { { name = "history", available = true, reason = vim.NIL } }
  local nil_view = View.new(model, {}, { home = vim.fn.tempname() })
  assert(nil_view:open())
  assert(not buffer_contains(nil_view.buffers.conversation, "vim.NIL"), "JSON null does not become a speaker label")
  assert(not buffer_contains(nil_view.buffers.agents, "vim.NIL"), "JSON null does not become a capability note")
  nil_view:teardown()
end

local function native_presentation_test()
  local manager = require("agent_manager")
  local presentation = require("agent_manager.presentation")
  local baselines = {}
  for _, link in ipairs(presentation.native_links()) do
    baselines[link.group] = vim.api.nvim_get_hl(0, {
      name = link.group,
      link = true,
      create = false,
    })
  end
  local buffer_count = #vim.api.nvim_list_bufs()
  local initial = manager.status()
  assert_equal(initial.view.open, false, "status cache must be readable before setup")
  assert_equal(initial.summary.agent_ids, {}, "initial cached agent IDs")
  assert_equal(#vim.api.nvim_list_bufs(), buffer_count, "status cache must not initialize a view")

  assert(manager.setup({
    broker = {
      command = { "python", root .. "/tests/fixtures/fake_public_broker.py" },
    },
    providers = { claude = { python = false } },
  }))
  local ux = manager.health().ux
  assert_equal(ux.foundation.registered, false, "native mode Foundation registration")
  assert_equal(ux.native_fallback, true, "native fallback mode")
  for _, link in ipairs(presentation.native_links()) do
    local highlight = vim.api.nvim_get_hl(0, { name = link.group, link = true, create = false })
    if link.attributes then
      assert_equal(highlight.fg, tonumber(link.attributes.fg:sub(2), 16), "native transcript color")
      assert(not highlight.bold, "transcript labels and user text are not bold")
    else
      assert_equal(highlight.link, link.target, "native highlight link: " .. link.group)
    end
  end
  vim.api.nvim_exec_autocmds("ColorScheme", {
    pattern = "agent-manager-native-replay",
    modeline = false,
  })
  assert(manager.teardown())
  for group, baseline in pairs(baselines) do
    assert_equal(
      vim.api.nvim_get_hl(0, { name = group, link = true, create = false }),
      baseline,
      "native highlight restoration: " .. group
    )
  end
end

local function public_input_validation_test()
  local manager = require("agent_manager")
  local Config = require("agent_manager.config")
  local _, config_err = Config.resolve({ ui = { prompt_min_height = 0 } })
  assert_equal(config_err.kind, "configuration", "invalid prompt minimum error")
  _, config_err = Config.resolve({ ui = { prompt_min_height = 5, prompt_max_height = 4 } })
  assert_equal(config_err.kind, "configuration", "invalid prompt height range error")

  local result, err = manager.prompt(nil, "")
  assert_equal(result, nil, "empty string prompt result")
  assert_equal(err.kind, "input", "empty string prompt error")

  result, err = manager.sessions({ provider = "codex", cwd = 42 })
  assert_equal(result, nil, "invalid discovery cwd result")
  assert_equal(err.kind, "input", "invalid discovery cwd error")

  result, err = manager.sessions({ provider = "codex", active_only = "yes" })
  assert_equal(result, nil, "invalid active-only discovery result")
  assert_equal(err.kind, "input", "invalid active-only discovery error")

  result, err = manager.models("other")
  assert_equal(result, nil, "invalid model discovery result")
  assert_equal(err.kind, "input", "invalid model discovery error")

  result, err = manager.workspace_diff(42)
  assert_equal(result, nil, "invalid workspace diff result")
  assert_equal(err.kind, "input", "invalid workspace diff error")

  result, err = manager.delete_session({ provider = "codex", cwd = "/tmp" })
  assert_equal(result, nil, "invalid session delete result")
  assert_equal(err.kind, "input", "invalid session delete error")

  result, err = manager.resume({
    provider = "claude",
    provider_session_id = "session",
    cwd = 42,
  })
  assert_equal(result, nil, "invalid resume cwd result")
  assert_equal(err.kind, "input", "invalid resume cwd error")

  result, err = manager.resume({
    provider = "claude",
    provider_session_id = "session",
    managed_workspace = { repository = "agent-manager", task_id = "Bad Name" },
  })
  assert_equal(result, nil, "invalid managed resume result")
  assert_equal(err.kind, "input", "invalid managed resume error")
end

local function real_broker_handshake_test()
  local Client = require("agent_manager.client")
  local broker_path = root .. "/target/debug/agent-manager-broker"
  assert(vim.fn.executable(broker_path) == 1, "debug broker must be built before Lua tests")
  local listed = nil
  local request_error = nil
  local client = Client.new({
    command = { broker_path, "serve" },
    claude_python = false,
  })
  assert(client:start())
  await("real broker handshake", function()
    return client.state == "connected"
  end)
  assert(client:request("agent/list", {}, function(result, err)
    listed = result
    request_error = err
  end))
  await("real broker list response", function()
    return listed ~= nil or request_error ~= nil
  end)
  assert_equal(request_error, nil, "real broker list error")
  assert_equal(listed.agents, {}, "real broker starts empty")
  client:stop()
  await("real broker shutdown", function()
    return client.state == "stopped" or client.state == "disconnected"
  end)
  assert_equal(client.state, "stopped", "real broker shutdown state: " .. vim.inspect(client:status()))
end

local function durable_reconnect_test()
  local manager = require("agent_manager")
  local broker_path = root .. "/target/debug/agent-manager-broker"
  -- Keep the Unix-socket path short enough for macOS's `sun_path` limit.
  local directory = vim.fn.tempname()
  assert_equal(vim.fn.mkdir(directory, "p"), 1, "durable test directory creation")
  assert(vim.uv.fs_chmod(directory, 448), "durable test directory permissions")
  directory = assert(vim.uv.fs_realpath(directory), "canonical durable test directory")
  local socket = directory .. "/s"
  local registry = directory .. "/registry.json"

  local function start_broker()
    local job = vim.fn.jobstart({
      broker_path,
      "serve-durable",
      "--socket",
      socket,
      "--registry",
      registry,
    }, {
      stdout_buffered = false,
      stderr_buffered = false,
    })
    assert(job > 0, "durable broker process must start")
    await("durable socket", function()
      local stat = vim.uv.fs_stat(socket)
      return stat and stat.type == "socket" and (stat.mode or 0) % 64 == 0
    end)
    return job
  end

  local broker_job = start_broker()
  local ok, setup_err = manager.setup({
    broker = {
      mode = "durable",
      command = { broker_path, "serve-durable" },
      socket = socket,
      reconnect = {
        initial_delay = 20,
        max_delay = 100,
        max_attempts = 20,
        jitter = 0,
      },
    },
    providers = { claude = { python = false } },
    ui = { external_sessions = false },
  })
  assert(ok, vim.inspect(setup_err))
  assert(manager.open())
  await("durable client handshake", function()
    return manager.status().client.state == "connected"
  end)
  assert_equal(manager.health().mode, "durable", "durable health mode")

  vim.fn.jobstop(broker_job)
  vim.fn.jobwait({ broker_job }, 5000)
  await("durable disconnect", function()
    local state = manager.status().client.state
    return state == "disconnected" or state == "reconnecting" or state == "connecting"
  end)
  await("durable socket cleanup", function()
    return vim.uv.fs_stat(socket) == nil
  end)

  broker_job = start_broker()
  await("durable automatic reconnect", function()
    return manager.status().client.state == "connected"
  end)
  assert(manager.status().client.reconnect_attempt == 0, "reconnect counter must reset")
  assert(manager.teardown())
  assert_equal(vim.fn.jobwait({ broker_job }, 0)[1], -1, "teardown must not stop durable broker")
  vim.fn.jobstop(broker_job)
  vim.fn.jobwait({ broker_job }, 5000)
  vim.fn.delete(directory, "rf")
end

local function configure_fake(manager)
  vim.fn.delete(vim.fn.stdpath("state") .. "/agent-manager/session-workspaces", "rf")
  local ok, setup_err = manager.setup({
    broker = {
      command = { "python", root .. "/tests/fixtures/fake_public_broker.py" },
    },
    providers = { claude = { python = false } },
  })
  assert(ok, vim.inspect(setup_err))
end

local function integration_test()
  vim.cmd.runtime("plugin/agent_manager.lua")
  for _, command in ipairs({
    "AgentManager",
    "AgentManagerAttach",
    "AgentManagerContext",
    "AgentManagerDelete",
    "AgentManagerDiff",
    "AgentManagerFork",
  }) do
    assert_equal(vim.fn.exists(":" .. command), 2, command .. " command")
  end

  local workspace = assert(vim.uv.fs_realpath("/tmp"), "canonical integration workspace")
  local test_file = vim.fs.joinpath(
    workspace,
    vim.fs.basename(vim.fn.tempname()) .. "-agent-manager-m2.txt"
  )
  vim.fn.writefile({ "disk original" }, test_file)
  vim.env.AGENT_MANAGER_TEST_FILE = test_file
  vim.cmd("edit " .. vim.fn.fnameescape(test_file))
  local source_buffer = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_lines(source_buffer, 0, -1, false, { "dirty local edit" })
  vim.bo[source_buffer].modified = true

  local manager = require("agent_manager")
  configure_fake(manager)
  assert(manager.open())
  await("broker handshake", function()
    return manager.status().client.state == "connected"
  end)
  await("external CLI session discovery", function()
    return #(manager.status().model.external_sessions or {}) == 4
  end)
  local external_status = manager.status()
  local agents_buffer = external_status.view.buffers.agents
  assert_equal(manager.list(), {}, "external CLI sessions are not broker-owned agents")
  assert(not buffer_contains(agents_buffer, "workspace/"), "outside directories start collapsed")
  assert(manager.status().view.active_pane == "agents")
  vim.api.nvim_feedkeys("1", "x", false)
  local function expand_tree(parent, child)
    local row = assert(buffer_line_number(agents_buffer, parent), "missing tree row " .. parent)
    vim.api.nvim_win_set_cursor(0, { row, 0 })
    vim.api.nvim_feedkeys("l", "x", false)
    local expanded = vim.wait(1000, function()
      return buffer_contains(agents_buffer, child)
    end, 10, false)
    if not expanded then
      error(
        "missing tree child "
          .. child
          .. "\n"
          .. table.concat(vim.api.nvim_buf_get_lines(agents_buffer, 0, -1, false), "\n")
      )
    end
  end
  expand_tree("**/**", "workspace/")
  expand_tree("workspace/", "repos/")
  expand_tree("agent-manager/**", "codex resumable fixture")
  expand_tree("repos/", "alpha/")
  expand_tree("alpha/", "api/")
  expand_tree("api/", "Codex terminal session")
  expand_tree("web/", "Claude terminal session")
  assert(buffer_contains(agents_buffer, "● ● · Codex terminal session"), "active external symbols")
  assert(buffer_contains(agents_buffer, "● ○ · codex resumable fixture"), "resumable external symbols")
  assert(
    buffer_contains(agents_buffer, "sn new · so open · am model · ae effort"),
    "session action note"
  )

  local sessions = nil
  assert(manager.sessions({ provider = "codex", cwd = "/tmp" }, function(result, err)
    assert_equal(err, nil, "session discovery error")
    sessions = result
  end))
  await("provider session discovery", function()
    return sessions ~= nil
  end)
  assert_equal(sessions.sessions[1].provider_session_id, "codex-resumable-lua", "session id")

  local deleted = nil
  assert(manager.delete_session(sessions.sessions[1], function(result, err)
    assert_equal(err, nil, "session deletion error")
    deleted = result
  end))
  await("provider session deletion", function()
    return deleted ~= nil
  end)
  assert_equal(deleted.worktree_preserved, true, "session deletion preserves files")
  assert_equal(#manager.status().model.external_sessions, 3, "deleted session leaves the tree")

  local external_diff = nil
  assert(manager.workspace_diff("/tmp", function(result, err)
    assert_equal(err, nil, "external workspace diff error")
    external_diff = result
  end))
  await("external workspace diff", function()
    return external_diff ~= nil
  end)
  assert(external_diff.diff:find("+new", 1, true), "external workspace diff result")

  assert(manager.start({ provider = "codex", cwd = workspace, workspace_strategy = "shared" }))
  await("agent startup", function()
    local agents = manager.list()
    return agents[1] and agents[1].state == "idle"
  end)
  local agent_id = manager.list()[1].id
  local initial_status = manager.status()
  assert(buffer_contains(initial_status.view.buffers.agents, "CAPABILITIES"), "capability heading")
  assert(buffer_contains(initial_status.view.buffers.agents, "approvals"), "approval capability")
  assert(buffer_contains(initial_status.view.buffers.agents, "shared"), "workspace strategy")

  local Editor = require("agent_manager.editor")
  local context = nil
  Editor.capture("buffer", manager.list()[1], { bufnr = source_buffer }, function(result, err)
    assert_equal(err, nil, "editor context error")
    context = result
  end)
  await("editor context capture", function()
    return context ~= nil
  end)
  assert_equal(context.payload.unsaved, true, "dirty context marker")
  assert_equal(context.payload.text, "dirty local edit", "dirty context snapshot")
  local context_result = nil
  assert(manager.add_context(agent_id, context, function(result, err)
    assert_equal(err, nil, "context queue error")
    context_result = result
  end))
  await("context queue", function()
    return context_result ~= nil
  end)
  assert_equal(context_result.count, 1, "queued context count")

  assert(manager.prompt(agent_id, "interactive question"))
  await("approval request", function()
    local action = manager.status().model.pending_actions["approval-lua-1"]
    return action ~= nil and manager.list()[1].state == "waiting_approval"
  end)
  local approval_status = manager.status()
  assert_equal(approval_status.view.active_pane, "decision", "approval focus")
  assert_equal(
    vim.api.nvim_get_current_buf(),
    approval_status.view.buffers.decision,
    "streaming redraw must preserve decision focus"
  )
  assert_equal(manager.pending_approval_count(), 1, "pending approval count")
  assert(buffer_contains(approval_status.view.buffers.decision, "Provider:  codex"), "approval provider")
  assert(
    buffer_contains(approval_status.view.buffers.decision, "Workspace: " .. workspace),
    "approval cwd"
  )
  assert(buffer_contains(approval_status.view.buffers.decision, "fixture --write-file"), "approval action")
  assert(buffer_contains(approval_status.view.buffers.decision, test_file), "approval affected path")

  local defer_error = nil
  assert(manager.respond_approval(agent_id, "approval-lua-1", "defer", function(_, err)
    defer_error = err
  end))
  await("unsupported defer response", function()
    return defer_error ~= nil
  end)
  assert(manager.status().model.pending_actions["approval-lua-1"], "failed response must remain pending")

  vim.api.nvim_set_current_buf(approval_status.view.buffers.decision)
  vim.api.nvim_feedkeys("y", "x", false)
  await("clarifying question", function()
    local action = manager.status().model.pending_actions["question-lua-1"]
    return action ~= nil and manager.list()[1].state == "waiting_input"
  end)
  local question_status = manager.status()
  assert_equal(question_status.view.active_pane, "decision", "question focus")
  assert(buffer_contains(question_status.view.buffers.decision, "Which safe mode"), "question text")
  assert(buffer_contains(question_status.view.buffers.decision, "careful"), "question choice")

  local original_select = vim.ui.select
  vim.ui.select = function(items, _, callback)
    callback(items[1])
  end
  vim.api.nvim_set_current_buf(question_status.view.buffers.decision)
  vim.api.nvim_feedkeys(vim.keycode("<CR>"), "x", false)
  vim.ui.select = original_select

  await("interactive completion", function()
    local status = manager.status().model
    return status.agents[1]
      and status.agents[1].state == "completed"
      and status.usage[agent_id]
      and status.file_conflicts[agent_id]
      and status.file_conflicts[agent_id][test_file]
  end)
  local completed = manager.status()
  assert_equal(completed.model.agents[1].title, "interactive question", "shared prompt title")
  assert_equal(completed.model.usage[agent_id].input_tokens, 12, "usage input tokens")
  assert_equal(vim.api.nvim_buf_get_lines(source_buffer, 0, -1, false), {
    "dirty local edit",
  }, "dirty buffer must not be overwritten")
  assert_equal(vim.bo[source_buffer].modified, true, "dirty buffer modified flag")
  assert_equal(#completed.model.pending_order, 0, "human requests resolved")
  assert_equal(manager.pending_approval_count(), 0, "resolved approval count")
  assert(buffer_contains(completed.view.buffers.conversation, "interactive answer"), "conversation response")
  assert(buffer_contains(completed.view.buffers.agents, "input_tokens: 12"), "usage presentation")
  assert(not buffer_contains(completed.view.buffers.agents, "usage.updated"), "usage event log is hidden")
  assert(buffer_contains(completed.view.buffers.agents, "dirty buffer conflict"), "conflict presentation")

  local conflict = manager.status().model.file_conflicts[agent_id][test_file]
  local conflict_diff, conflict_error = Editor.conflict_diff(conflict)
  assert_equal(conflict_error, nil, "conflict diff error")
  assert(conflict_diff:find("dirty local edit", 1, true), "conflict diff must include buffer text")

  original_select = vim.ui.select
  vim.ui.select = function(items, _, callback)
    callback(items[#items])
  end
  manager.diff_ui()
  vim.ui.select = original_select
  await("keep-buffer resolution", function()
    return manager.status().model.file_conflicts[agent_id][test_file].resolved == true
  end)
  assert_equal(
    manager.status().model.file_conflicts[agent_id][test_file].resolution,
    "kept_buffer",
    "conflict resolution"
  )

  manager.diff_ui()
  await("workspace diff", function()
    local status = manager.status()
    return status.view.active_pane == "conversation" and buffer_contains(status.view.buffers.conversation, "+new")
  end)

  local history = nil
  assert(manager.history(agent_id, function(result, err)
    assert_equal(err, nil, "history error")
    history = result
  end))
  await("provider history", function()
    return history ~= nil and manager.status().model.conversations[agent_id][2]
  end)
  assert_equal(manager.status().model.conversations[agent_id][2].text, "historic answer", "history message")

  assert(manager.prompt(agent_id, "second question"))
  await("second active turn", function()
    return manager.list()[1].state == "running"
  end)
  local queued_prompt = nil
  assert(manager.prompt(agent_id, "queued follow-up", function(result, err)
    assert_equal(err, nil, "active prompt queues without a state error")
    queued_prompt = result
  end))
  await("queued prompt accepted", function()
    return queued_prompt ~= nil
  end)
  assert_equal(queued_prompt.queued, true, "prompt client opts into broker queue")
  assert_equal(queued_prompt.position, 1, "queued prompt position")
  assert(manager.steer(agent_id, "more detail"))
  await("steering delta", function()
    local conversation = manager.status().model.conversations[agent_id]
    for _, message in ipairs(conversation or {}) do
      if message.text and message.text:find("steered", 1, true) then
        return true
      end
    end
    return false
  end)
  assert(manager.interrupt(agent_id))
  await("interrupted state", function()
    return manager.list()[1].state == "interrupted"
  end)

  local forked = nil
  assert(manager.fork(agent_id, function(result, err)
    assert_equal(err, nil, "fork error")
    forked = result
  end))
  await("forked session", function()
    return forked ~= nil and #manager.list() == 2 and manager.list()[2].state == "idle"
  end)
  assert_equal(manager.list()[1].state, "disconnected", "fork source retirement")
  assert(manager.list()[2].provider_session_id:match("%-fork$"), "forked provider session id")

  local status = manager.status()
  for name, buffer in pairs(status.view.buffers) do
    assert(vim.api.nvim_buf_is_valid(buffer), name .. " buffer must be valid")
    assert_equal(vim.bo[buffer].swapfile, false, name .. " buffer swapfile")
    assert_equal(vim.bo[buffer].modeline, false, name .. " buffer modeline")
  end
  local focused_buffer = vim.api.nvim_get_current_buf()
  vim.api.nvim_feedkeys(vim.keycode("<Tab>"), "x", false)
  await("pane cycling", function()
    return vim.api.nvim_get_current_buf() ~= focused_buffer
  end)
  assert_equal(manager.running_count(), 0, "running agent count")

  manager.close()
  assert_equal(manager.status().view.open, false, "workspace close")
  manager.teardown()
  vim.wait(500, function()
    return false
  end, 25, false)
  pcall(vim.api.nvim_buf_delete, source_buffer, { force = true })
  vim.fn.delete(test_file)
end

local function new_task_identity_test()
  local mappings = require("agent_manager.session_workspace")
  local original_hrtime = vim.uv.hrtime
  local original_date = os.date
  vim.uv.hrtime = function() return 123456789 end
  os.date = function() return "20260908-180300" end
  local ids = {}
  for _ = 1, 100 do
    local id = mappings.new_task_id()
    assert(not ids[id], "distinct new tasks even with identical clock readings")
    assert(id:match("^session%-20260908%-180300%-s%x+$"), "lifecycle-safe task ID")
    -- A letter-prefixed final segment survives the lifecycle's repeated
    -- removal of numeric/current/retry suffixes, unlike legacy session IDs.
    assert(not id:match("%-%d+$"), "task must not look like a numbered retry")
    assert(not id:match("%-current$") and not id:match("%-retry$"), "task is not a retry sibling")
    ids[id] = true
  end
  vim.uv.hrtime = original_hrtime
  os.date = original_date
end

local function managed_workspace_ui_test()
  local manager = require("agent_manager")
  configure_fake(manager)
  assert(manager.open())
  await("managed broker handshake", function()
    return manager.status().client.state == "connected"
  end)

  local inventory = nil
  assert(manager.workspaces(function(result, err)
    assert_equal(err, nil, "workspace inventory error")
    inventory = result
  end))
  await("workspace inventory", function()
    return inventory ~= nil
  end)
  assert_equal(inventory.repositories[1].base_branch, "bluff", "managed base branch")
  assert_equal(inventory.repositories[1].tasks[1].task_id, "existing-task", "managed task")

  local prompt_input_opened = false
  local original_input = vim.ui.input
  vim.ui.input = function()
    prompt_input_opened = true
  end
  local prompt_ok, prompt_err = manager.prompt_ui()
  vim.ui.input = original_input
  assert_equal(prompt_ok, nil, "prompt without an agent")
  assert_equal(prompt_err.kind, "input", "prompt without an agent error")
  assert_equal(prompt_input_opened, false, "prompt should fail before opening input")
  vim.ui.input = function()
    prompt_input_opened = true
  end

  local original_models = manager.models
  local original_select = vim.ui.select
  local failed_catalog_picker_opened = false
  manager.models = function(_, callback)
    callback(nil, { kind = "rpc", message = "fixture model discovery failure" })
    return true
  end
  vim.ui.select = function()
    failed_catalog_picker_opened = true
  end
  manager.start_ui({
    provider = "codex",
    cwd = inventory.repositories[1].canonical_path,
    repository = "agent-manager",
  })
  assert_equal(
    failed_catalog_picker_opened,
    false,
    "failed model discovery must not show a misleading Default-only picker"
  )
  manager.models = original_models
  vim.ui.select = original_select

  local select_count = 0
  local ui_active = false
  local model_labels = nil
  vim.ui.select = function(items, opts, callback)
    assert_equal(ui_active, false, "start picker nesting")
    ui_active = true
    select_count = select_count + 1
    if opts.prompt:find("provider", 1, true) then
      callback(items[1])
    else
      model_labels = vim.tbl_map(opts.format_item, items)
      assert_equal(items[1].display_name, "Default", "Default is the initial model choice")
      callback(items[1])
    end
    ui_active = false
  end
  assert(manager.status().model.workspace_repositories[1], "workspace inventory model")
  assert(manager.status().view.active_pane == "agents")
  manager.start_ui({
    cwd = inventory.repositories[1].canonical_path,
    repository = "agent-manager",
  })
  await("managed prompt focus", function()
    local status = manager.status()
    return status.view.active_pane == "conversation"
      and vim.api.nvim_get_current_buf() == status.view.buffers.prompt
  end)
  assert(model_labels[1]:find("1  Default", 1, true), "Default model is numbered first")
  assert(model_labels[2]:find("2  GPT Fixture", 1, true), "available model is numbered")
  assert(model_labels[3]:find("3  GPT Fixture Fast", 1, true), "all models are listed")
  assert(model_labels[10]:find("a  GPT Fixture 9", 1, true), "model numbering continues to z")
  assert_equal(prompt_input_opened, false, "new-session prompt stays out of command-line input")
  assert(manager.prompt_ui("build the managed feature"))
  await("managed agent startup", function()
    local agent = manager.list()[1]
    return agent and agent.state == "completed"
  end)
  vim.ui.select = original_select
  vim.ui.input = original_input

  local agent = manager.list()[1]
  assert_equal(select_count, 2, "new session asks for provider and model")
  assert_equal(agent.workspace_strategy, "worktree", "managed strategy")
  assert_equal(agent.managed_workspace.repository, "agent-manager", "managed repository")
  assert(agent.managed_workspace.task_id:match("^session%-%d%d%d%d%d%d%d%d%-%d%d%d%d%d%d%-s%x+$"), "generated managed task ID")
  assert_equal(agent.managed_workspace.base_branch, "bluff", "managed task base")
  assert_equal(agent.provider_options.model, nil, "provider default reaches the broker")
  assert_equal(agent.runtime.provider_version, "0.153.0", "actual runtime version")
  local status = manager.status()
  assert(
    buffer_contains(
      status.view.buffers.agents,
      "agent-manager/" .. agent.managed_workspace.task_id
    ),
    "managed task presentation"
  )
  assert(
    buffer_contains(status.view.buffers.agents, "codex-app-server-stable-v1"),
    "runtime profile presentation"
  )
  assert(
    buffer_contains(
      status.view.buffers.conversation,
      agent.managed_workspace.task_id .. " · Codex — default / default"
    ),
    "conversation heading shows title, provider, model, and effort"
  )

  local model_setting_selected = false
  vim.ui.select = function(items, opts, callback)
    if opts.prompt:find("model", 1, true) then
      for _, item in ipairs(items) do
        if item.model == "gpt-fixture-fast" then
          model_setting_selected = true
          callback(item)
          return
        end
      end
    end
  end
  manager.model_ui()
  await("changed model selection", function()
    return model_setting_selected
  end)
  local effort_setting_selected = false
  vim.ui.select = function(items, _, callback)
    for _, item in ipairs(items) do
      if item == "high" then
        effort_setting_selected = true
        callback(item)
        return
      end
    end
  end
  manager.effort_ui()
  await("changed effort selection", function()
    return effort_setting_selected
  end)
  assert(manager.prompt(agent.id, "apply the changed settings"))
  await("changed model and effort", function()
    local current = manager.list()[1]
    return current
      and current.provider_options.model == "gpt-fixture-fast"
      and current.provider_options.effort == "high"
  end)
  assert(manager.interrupt(agent.id))
  vim.ui.select = original_select
  vim.ui.input = original_input
  manager.teardown()
  vim.wait(500, function()
    return false
  end, 25, false)
end

local function managed_start_uses_focused_layout_without_inventory_test()
  local manager = require("agent_manager")
  -- CI checkouts do not live at ~/repo or ~/worktrees/repo/task. Give this
  -- layout-specific test its own canonical home instead of using the checkout.
  local layout_home = vim.fn.tempname()
  local layout_root = layout_home .. "/worktrees/focused-repo/existing-task"
  vim.fn.mkdir(layout_root .. "/.git", "p")
  local original_homedir = vim.uv.os_homedir
  vim.uv.os_homedir = function() return layout_home end
  configure_fake(manager)
  assert(manager.open())
  await("focused-layout broker handshake", function()
    return manager.status().client.state == "connected"
  end)
  await("focused-layout provider sessions", function()
    return #(manager.status().model.external_sessions or {}) == 4
  end)
  assert_equal(
    manager.status().model.workspace_repositories,
    {},
    "opening the session tree must not run the full workspace audit"
  )

  local original_select = vim.ui.select
  local remembered_model = nil
  vim.ui.select = function(items, opts, callback)
    if opts.prompt:find("provider", 1, true) then
      callback(items[1])
    else
      remembered_model = items[1].model
      callback(items[1])
    end
  end

  manager.start_ui({ cwd = layout_root })
  await("focused-layout prompt focus", function()
    local status = manager.status()
    return status.view.active_pane == "conversation"
      and vim.api.nvim_get_current_buf() == status.view.buffers.prompt
  end)
  assert(manager.prompt_ui("inspect the focused layout"))
  await("focused-layout managed startup", function()
    local agent = manager.list()[1]
    return agent and agent.state == "completed"
  end)

  vim.ui.select = original_select
  vim.uv.os_homedir = original_homedir
  local agent = manager.list()[1]
  assert_equal(remembered_model, "gpt-fixture-fast", "new session defaults to the last model")
  assert_equal(agent.managed_workspace.repository, "focused-repo", "focused repository")
  assert(agent.managed_workspace.task_id:match("^session%-"), "focused task uses a generated ID")
  assert_equal(agent.provider_options.effort, "high", "new session defaults to the last effort")
  manager.teardown()
  vim.fn.delete(layout_home, "rf")
  vim.wait(500, function()
    return false
  end, 25, false)
end

local function managed_decision_render_test()
  local Model = require("agent_manager.model")
  local View = require("agent_manager.view")
  local model = Model.new({ max_events = 8 })
  model:apply_state({
    {
      id = "agent-managed",
      provider = "codex",
      provider_session_id = "thread-managed",
      cwd = "/workspace/worktrees/agent-manager/decision-task",
      workspace_strategy = "worktree",
      worktree_path = "/workspace/worktrees/agent-manager/decision-task",
      managed_workspace = {
        repository = "agent-manager",
        task_id = "decision-task",
        branch = "agent/decision-task",
        base_branch = "bluff",
      },
      runtime = {
        compatibility_profile = "codex-app-server-stable-v1",
        provider_version = "0.153.0",
      },
      title = "fixture",
      state = "waiting_approval",
      pending_approvals = 1,
      capabilities = { { name = "approvals", available = true } },
    },
  })
  assert(model:apply_event({
    sequence = 1,
    agent_id = "agent-managed",
    provider = "codex",
    type = "approval.requested",
    payload = {
      id = "approval-managed-1",
      kind = "approval",
      choices = { "allow", "deny" },
      tool_name = "Command",
      summary = "write a managed file",
    },
  }))
  assert_equal(model:focused_action().id, "approval-managed-1", "managed approval projection")

  local denied_action = nil
  local view = View.new(model, {
    deny = function(action)
      denied_action = action.id
    end,
  }, {})
  assert(view:open())
  view:render()
  local decision = view:status().buffers.decision
  assert(
    buffer_contains(decision, "Task:      agent-manager/decision-task"),
    "managed task line in the decision pane"
  )
  assert(buffer_contains(decision, "Strategy:  worktree"), "managed decision strategy")
  vim.api.nvim_set_current_buf(decision)
  vim.api.nvim_feedkeys("n", "x", false)
  assert_equal(denied_action, "approval-managed-1", "n denies the focused request")
  view:teardown()
end

local function resume_test()
  local manager = require("agent_manager")
  configure_fake(manager)
  assert(manager.open())
  await("resume broker handshake", function()
    return manager.status().client.state == "connected"
  end)
  await("all provider sessions", function()
    return #(manager.status().model.external_sessions or {}) == 4
  end)
  local session = nil
  for _, candidate in ipairs(manager.status().model.external_sessions) do
    if candidate.provider_session_id == "claude-resumable-lua" then
      session = candidate
      break
    end
  end
  assert(session, "resumable Claude session must be listed")
  local original_input = vim.ui.input
  local resume_prompt = nil
  vim.ui.input = function(opts, callback)
    resume_prompt = opts.prompt
    callback("continued-session")
  end
  manager.resume_session_ui(session)
  await("specific resume", function()
    local agent = manager.list()[1]
    local conversations = manager.status().model.conversations
    return agent and conversations[agent.id] and conversations[agent.id][2]
  end)
  vim.ui.input = original_input
  local resumed = manager.list()[1]
  assert_equal(resume_prompt, nil, "resume must not prompt for a workspace name")
  assert_equal(resumed.provider_session_id, "claude-resumable-lua", "specific resume id")
  assert_equal(resumed.workspace_strategy, "worktree", "resumed session workspace strategy")
  local mappings = require("agent_manager.session_workspace")
  assert_equal(resumed.managed_workspace.task_id, mappings.task_id(session), "automatic session workspace")
  local saved = assert(mappings.load(session))
  assert_equal(saved.task_id, resumed.managed_workspace.task_id, "resume persists the association")
  assert_equal(
    manager.status().model.conversations[resumed.id][2].text,
    "historic answer",
    "resumed history"
  )
  manager.teardown()
  vim.wait(500, function()
    return false
  end, 25, false)

  -- The provider still advertises its old canonical cwd after a fresh editor setup.
  assert(manager.setup({
    broker = { command = { "python", root .. "/tests/fixtures/fake_public_broker.py" } },
    providers = { claude = { python = false } },
  }))
  local refused, refusal = manager.resume({
    provider = session.provider,
    provider_session_id = session.provider_session_id,
    managed_workspace = { repository = saved.repository, task_id = "different-task" },
  })
  assert_equal(refused, nil, "public resume refuses workspace reassignment")
  assert_equal(refusal.kind, "workspace", "workspace reassignment error")
  local original_resume = manager.resume
  local attempts = {}
  manager.resume = function(opts)
    attempts[#attempts + 1] = opts
    return true
  end
  vim.ui.input = function()
    error("resume must not ask for a workspace name")
  end
  manager.resume_session_ui(session)
  assert_equal(#attempts, 1, "restart resumes once")
  assert_equal(attempts[1].managed_workspace, {
    repository = saved.repository, task_id = saved.task_id, resume = true,
  }, "restart reclaims the saved mapping despite stale provider cwd")

  local original_workspaces = manager.workspaces
  local legacy = vim.deepcopy(session)
  legacy.provider_session_id = "legacy-unmapped-session"
  local legacy_task = mappings.task_id(legacy)
  manager.workspaces = function(callback)
    callback({ repositories = { {
      slug = "agent-manager", canonical_path = legacy.cwd,
      worktree_root = "/workspace/worktrees/agent-manager",
      tasks = { { task_id = legacy_task, path = "/workspace/worktrees/agent-manager/" .. legacy_task } },
    } } })
  end
  manager.resume_session_ui(legacy)
  assert_equal(attempts[2].managed_workspace.resume, true, "existing automatic task is reclaimed")
  assert_equal(attempts[2].managed_workspace.task_id, legacy_task, "stable automatic task identity")
  attempts[2] = nil

  local missing = vim.deepcopy(legacy)
  missing.cwd = "/workspace/worktrees/agent-manager/missing-task"
  manager.resume_session_ui(missing)
  assert_equal(#attempts, 1, "missing task cannot become a new workspace")
  manager.workspaces = original_workspaces

  local conflicting = vim.deepcopy(session)
  conflicting.managed_workspace = { repository = saved.repository, task_id = "different-task" }
  manager.resume_session_ui(conflicting)
  assert_equal(#attempts, 1, "conflicting metadata cannot launch a replacement")

  local filename = vim.fn.stdpath("state") .. "/agent-manager/session-workspaces/"
    .. vim.fn.sha256(session.provider .. "\n" .. session.provider_session_id) .. ".json"
  vim.fn.writefile({ "invalid JSON" }, filename)
  manager.resume_session_ui(session)
  assert_equal(#attempts, 1, "corrupt mapping cannot launch a replacement")
  manager.resume = original_resume
  vim.ui.input = original_input
  manager.teardown()
end

local function codex_directory_resume_test()
  local manager = require("agent_manager")
  configure_fake(manager)
  local directory = vim.fn.tempname()
  vim.fn.mkdir(directory, "p")
  local original_resume, original_workspaces = manager.resume, manager.workspaces
  local attempts, inventories = {}, 0
  manager.resume = function(opts)
    attempts[#attempts + 1] = opts
    return true
  end
  manager.workspaces = function(callback)
    inventories = inventories + 1
    callback({ repositories = {} })
  end
  local session = {
    provider = "codex", provider_session_id = "cli-directory-resume",
    cwd = directory .. "/", external = true, activity_known = true,
    provider_options = { model = "saved-model" },
  }
  manager.resume_session_ui(session)
  assert_equal(#attempts, 1, "CLI Codex session resumes")
  assert_equal(inventories, 0, "plain directory resume never waits for lifecycle inventory")
  assert_equal(attempts[1].provider_session_id, session.provider_session_id, "original Codex identity")
  assert_equal(attempts[1].cwd, vim.uv.fs_realpath(directory), "original directory is preserved")
  assert_equal(attempts[1].workspace_strategy, "shared", "plain directory needs no Git worktree")
  assert_equal(attempts[1].provider_options, session.provider_options, "saved model is preserved")

  session.external_active = true
  manager.resume_session_ui(session)
  session.external_active = nil
  session.activity_known = false
  manager.resume_session_ui(session)
  assert_equal(#attempts, 1, "active or uncertain sessions cannot acquire a second writer")
  session.activity_known = true

  session.provider = "claude"
  manager.resume_session_ui(session)
  assert_equal(inventories, 1, "Claude keeps its existing lifecycle path")
  session.provider = "codex"
  vim.fn.writefile({ "gitdir: /missing/gitdir" }, directory .. "/.git")
  manager.resume_session_ui(session)
  assert_equal(inventories, 2, "broken Git markers cannot bypass workspace discovery")
  vim.fn.delete(directory .. "/.git")

  local mappings = require("agent_manager.session_workspace")
  assert(mappings.save(session, { repository = "demo", task_id = "original-task" }))
  manager.resume_session_ui(session)
  assert_equal(attempts[#attempts].managed_workspace, {
    repository = "demo", task_id = "original-task", resume = true,
  }, "saved mappings take precedence over a stale non-Git cwd")
  assert_equal(attempts[#attempts].cwd, nil, "mapped session cannot fall back to a plain directory")
  manager.resume, manager.workspaces = original_resume, original_workspaces
  manager.teardown()
  vim.fn.delete(directory, "rf")
end

local function session_workspace_store_test()
  local mappings = require("agent_manager.session_workspace")
  local session = { provider = "codex", provider_session_id = "workspace-store-test" }
  local workspace = { repository = "agent-manager", task_id = "original-task" }
  assert_equal(mappings.load(session), nil, "unmapped session")
  assert(mappings.save(session, workspace))
  assert(mappings.save(session, workspace))
  assert_equal(mappings.load(session), workspace, "saved mapping")
  local ok, err = mappings.save(session, { repository = "agent-manager", task_id = "replacement" })
  assert_equal(ok, nil, "mapping is immutable")
  assert(err, "conflict explanation")
  assert_equal(mappings.load(session), workspace, "original mapping survives conflict")
  assert_equal(mappings.load({ provider = "claude", provider_session_id = session.provider_session_id }), nil,
    "provider identities are separate")
end

local function run()
  dofile(root .. "/tests/lua/workflows.lua")()
  session_workspace_store_test()
  pure_client_resync_test()
  pure_client_revision_mismatch_test()
  pure_model_test()
  layout_test()
  directory_markdown_and_bottom_test()
  unified_workflow_layout_test()
  workspace_view_navigation_test()
  conversation_prompt_test()
  expanded_panes_test()
  which_key_prefix_test()
  transcript_presentation_test()
  native_presentation_test()
  public_input_validation_test()
  real_broker_handshake_test()
  durable_reconnect_test()
  new_task_identity_test()
  managed_workspace_ui_test()
  managed_start_uses_focused_layout_without_inventory_test()
  managed_decision_render_test()
  integration_test()
  resume_test()
  codex_directory_resume_test()
  print("Agent Manager Lua M4 tests passed")
end

local ok, err = xpcall(run, debug.traceback)
vim.fn.delete(test_state, "rf")
if not ok then
  io.stderr:write(err .. "\n")
  vim.cmd("cquit 1")
else
  vim.cmd("qa!")
end
