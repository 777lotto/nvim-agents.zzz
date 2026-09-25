local h = require("tests.lua.m3_helpers")

local root = h.root("AGENT_MANAGER_TEST_ROOT")
local foundation_root = h.root("UX_FOUNDATION_ROOT")
local chrome_root = h.root("UX_CHROME_ROOT")
vim.opt.runtimepath:prepend(root)
vim.opt.runtimepath:prepend(foundation_root)
vim.opt.runtimepath:prepend(chrome_root)

local foundation = require("ux_foundation")
local chrome = require("ux_chrome")

local function surface_options()
  local result = {}
  for _, name in ipairs({
    "tabline",
    "statusline",
    "winbar",
    "statuscolumn",
    "foldtext",
    "foldexpr",
  }) do
    result[name] = vim.api.nvim_get_option_value(name, { scope = "global" })
  end
  return result
end

h.finish(function()
  vim.o.columns = 160
  foundation._reset_for_tests()
  chrome._reset_for_tests()
  foundation.setup({
    core = true,
    lifecycle = false,
    load_active = false,
    strict = true,
    storage_dir = vim.fn.tempname() .. "-agent-manager-chrome",
  })
  chrome.setup({
    foundation = { load_active = false },
    ownership = {
      tabline = "external",
      statusline = "external",
      winbar = "external",
      statuscolumn = "external",
      windows = "external",
      scrollbar = "external",
    },
  })
  local opening_surfaces = surface_options()

  local events = {}
  local event_group = vim.api.nvim_create_augroup("AgentManagerM3StatusTest", { clear = true })
  vim.api.nvim_create_autocmd("User", {
    group = event_group,
    pattern = "AgentManagerStateChanged",
    callback = function(event)
      events[#events + 1] = vim.deepcopy(event.data)
    end,
  })

  local manager = require("agent_manager")
  h.truthy(manager.setup({
    broker = { command = { "python", root .. "/tests/fixtures/fake_public_broker.py" } },
    providers = { claude = { python = false } },
  }))
  h.truthy(manager.open())
  h.await("embedded broker handshake", function()
    return manager.status().client.state == "connected"
  end)
  h.truthy(manager.start({ provider = "codex", cwd = "/tmp", workspace_strategy = "shared" }))
  h.await("agent start", function()
    return manager.list()[1] and manager.list()[1].state == "idle"
  end)
  local agent_id = manager.list()[1].id
  local context_queued = false
  h.truthy(manager.add_context(agent_id, {
    kind = "buffer",
    payload = {
      path = "/tmp/agent-manager-m3-fixture",
      text = "fixture",
      unsaved = false,
    },
  }, function(_, err)
    h.equal(err, nil, "fixture context error")
    context_queued = true
  end))
  h.await("fixture context", function()
    return context_queued
  end)
  h.truthy(manager.prompt(agent_id, "status cache fixture"))
  h.await("approval cache", function()
    return manager.pending_approval_count() == 1
  end)
  h.await("scheduled state event", function()
    return #events > 0 and events[#events].pending_approval_count == 1
  end)

  local summary = manager.status().summary
  h.equal(summary.running_count, manager.running_count(), "cached running count")
  h.equal(summary.pending_approval_count, 1, "cached approval count")
  h.equal(summary.agent_ids, { agent_id }, "cached stable agent IDs")
  local allowed_event_keys = {
    agent_ids = true,
    pending_approval_count = true,
    reason = true,
    running_count = true,
  }
  for _, event in ipairs(events) do
    for key in pairs(event) do
      h.truthy(allowed_event_keys[key], "state event leaked an unexpected field: " .. tostring(key))
    end
    h.truthy(not vim.inspect(event):find("status cache fixture", 1, true), "state event leaked prompt text")
  end

  local status = manager.status()
  for name, buffer in pairs(status.view.buffers) do
    h.truthy(vim.api.nvim_buf_is_valid(buffer), name .. " buffer is invalid")
    h.truthy(vim.api.nvim_buf_get_name(buffer):match("^agent%-manager://"), name .. " buffer name")
    h.truthy(vim.bo[buffer].filetype:match("^agent%-manager%-"), name .. " filetype")
    h.equal(vim.bo[buffer].modified, false, name .. " buffer modified flag")
    h.equal(vim.b[buffer].agent_manager.plugin_id, "agent.manager", name .. " buffer metadata")
  end
  for pane, window in pairs(status.view.windows) do
    if vim.api.nvim_win_is_valid(window) then
      h.equal(vim.w[window].agent_manager.plugin_id, "agent.manager", pane .. " window metadata")
    end
  end
  h.equal(surface_options(), opening_surfaces, "Agent Manager wrote a Chrome-owned surface")

  local pane_api_ok, panes = pcall(require, "ux_chrome.panes")
  if pane_api_ok then
    local conversation = status.view.windows.conversation
    -- The approval temporarily replaces the conversation window with context.
    h.equal(panes.inspect(conversation).role, "context", "approval pane role")
    h.equal(panes.inspect(conversation).content, "plaintext", "approval content")
    local tx = h.truthy(foundation.begin_transaction())
    h.truthy(tx:stage("ux.chrome.panes/context/wrap/value", false))
    h.equal(vim.wo[conversation].wrap, false, "shared wrap did not reach conversation")
    h.truthy(tx:revert())
    h.truthy(tx:commit())
    h.equal(vim.wo[conversation].wrap, true, "shared wrap revert")
  end

  local components_ok = pcall(require, "ux_chrome.components")
  if components_ok then
    local win, buf = status.view.windows.agents, status.view.buffers.agents
    local before = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    vim.api.nvim_win_set_cursor(win, { 1, 3 })
    local cursor = vim.api.nvim_win_get_cursor(win)
    local selected = manager.status().model.selected_agent_id
    local View = require("agent_manager.view")
    local original_render = View._render_agents
    View._render_agents = function() error("presentation edit rebuilt domain rows") end
    local tx = h.truthy(foundation.begin_transaction())
    h.truthy(tx:stage("ux.chrome.components/navigation/padding/value", 4))
    h.truthy(vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1]:find("    ## 1 AGENTS", 1, true))
    h.equal(vim.api.nvim_win_get_cursor(win), cursor, "shared component edit moved selection")
    h.equal(manager.status().model.selected_agent_id, selected, "shared component edit changed agent")
    h.truthy(tx:stage("ux.chrome.component.agent.manager.navigation/navigation/padding/value", 2))
    h.truthy(vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1]:find("  ## 1 AGENTS", 1, true))
    h.truthy(tx:undo())
    h.truthy(vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1]:find("    ## 1 AGENTS", 1, true))
    h.truthy(tx:revert())
    h.truthy(tx:commit())
    View._render_agents = original_render
    h.equal(vim.api.nvim_buf_get_lines(buf, 0, -1, false), before, "navigation revert")

    -- A narrow layout reuses its conversation window for navigation. Verify
    -- refocusing binds cached redraw again and clips semantic byte spans.
    local fixture_buf = vim.api.nvim_create_buf(false, true)
    local fixture_win = vim.api.nvim_open_win(fixture_buf, false, {
      relative = "editor", row = 1, col = 1, width = 3, height = 2,
    })
    local target = { id = "full-session-identity" }
    local fixture = setmetatable({
      tab = vim.api.nvim_get_current_tabpage(),
      buffers = { agents = fixture_buf },
      windows = { conversation = fixture_win },
      namespace = vim.api.nvim_create_namespace("AgentManagerComponentFixture"),
      session_rows = { target },
      navigation_content = {
        lines = { " ●界 example" },
        highlights = {
          { line = 1, start = 1, finish = 4, group = "AgentManagerProviderCodex" },
          { line = 1, start = 4, finish = 7, group = "AgentManagerStatusSuccess" },
        },
      },
    }, { __index = View })
    h.truthy(fixture:focus("agents"))
    h.equal(vim.api.nvim_buf_get_lines(fixture_buf, 0, -1, false), { " ●…" })
    local spans = vim.api.nvim_buf_get_extmarks(fixture_buf, fixture.namespace, 0, -1, { details = true })
    local provider_span
    for _, span in ipairs(spans) do
      h.truthy(span[3] <= 4 and span[4].end_col <= 4, "span crossed into the ellipsis")
      if span[4].hl_group == "AgentManagerProviderCodex" then provider_span = span end
    end
    h.truthy(provider_span, "truncation lost a visible provider highlight")
    h.equal(provider_span[3], 1)
    h.equal(provider_span[4].end_col, 4)
    vim.api.nvim_win_set_buf(fixture_win, vim.api.nvim_create_buf(false, true))
    tx = h.truthy(foundation.begin_transaction())
    h.truthy(tx:stage("ux.chrome.components/navigation/padding/value", 4))
    h.equal(vim.api.nvim_buf_get_lines(fixture_buf, 0, -1, false), { " ●…" }, "hidden callback leaked")
    h.truthy(fixture:focus("agents"))
    h.equal(vim.api.nvim_buf_get_lines(fixture_buf, 0, -1, false), { "  …" })
    h.truthy(tx:stage("ux.chrome.components/navigation/padding/value", 0))
    h.equal(vim.api.nvim_buf_get_lines(fixture_buf, 0, -1, false), { "●…" }, "refocus lost live edits")
    h.truthy(fixture.session_rows[1] == target, "presentation replaced the action target")
    h.truthy(tx:revert())
    h.truthy(tx:commit())
    vim.api.nvim_win_close(fixture_win, true)
    vim.api.nvim_buf_delete(fixture_buf, { force = true })
  end

  local health = manager.health().ux
  h.equal(health.chrome.available, true, "Chrome presence")
  h.equal(health.chrome.segment_available, false, "unexpected private Chrome segment use")
  h.equal(health.chrome.cached_status_available, true, "public cache availability")
  h.equal(health.panels.backend, "native", "Panels fallback backend")

  local buffers = vim.deepcopy(status.view.buffers)
  h.truthy(manager.teardown())
  for name, buffer in pairs(buffers) do
    h.equal(vim.api.nvim_buf_is_valid(buffer), false, name .. " buffer survived teardown")
  end
  if pane_api_ok then
    local View = require("agent_manager.view")
    local Workflows = require("agent_manager.workflows")
    local isolated = View.new(require("agent_manager.model").new({ max_events = 8 }), {},
      { home = vim.fn.tempname() })
    local workflows = Workflows.new(isolated, { python = false, refresh_ms = 60000 }, function() end)
    isolated.workflows = workflows
    h.truthy(isolated:open())
    workflows:open()
    h.equal(panes.inspect(workflows.windows.checklist).content, "markdown", "workflow directory Chrome content")
    h.equal(panes.inspect(workflows.windows.detail).content, "markdown", "workflow transcript Chrome content")
    h.equal(panes.inspect(isolated.windows.prompt).role, "input", "bottom prompt Chrome role")
    h.truthy(isolated:bottom(2))
    h.equal(panes.inspect(isolated.windows.prompt).content, "markdown", "bottom shortcuts Chrome content")
    isolated:teardown()
  end
  h.equal(surface_options(), opening_surfaces, "teardown changed a Chrome-owned surface")
  vim.api.nvim_del_augroup_by_id(event_group)
  h.truthy(chrome.teardown())
  foundation._reset_for_tests()
  print("Agent Manager M3 Chrome coexistence passed")
end)
