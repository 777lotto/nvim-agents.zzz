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
  h.equal(surface_options(), opening_surfaces, "teardown changed a Chrome-owned surface")
  vim.api.nvim_del_augroup_by_id(event_group)
  h.truthy(chrome.teardown())
  foundation._reset_for_tests()
  print("Agent Manager M3 Chrome coexistence passed")
end)
