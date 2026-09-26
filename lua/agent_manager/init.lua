local Config = require("agent_manager.config")
local Client = require("agent_manager.client")
local Editor = require("agent_manager.editor")
local Model = require("agent_manager.model")
local SessionWorkspace = require("agent_manager.session_workspace")
local UX = require("agent_manager.ux")
local View = require("agent_manager.view")

local M = {}
local runtime = nil
local remembered_provider_options = {
  codex = {},
  claude = {},
}
local state_event_pending = false
local state_event_data = nil
local cached_summary = {
  running_count = 0,
  pending_approval_count = 0,
  agent_ids = {},
}

local function summary_for(model)
  local ids = {}
  for _, agent in ipairs(model and model:list() or {}) do
    ids[#ids + 1] = agent.id
  end
  return {
    running_count = model and model:running_count() or 0,
    pending_approval_count = model and model:pending_approval_count() or 0,
    agent_ids = ids,
  }
end

local function publish_state(model, reason)
  cached_summary = summary_for(model)
  state_event_data = vim.tbl_extend("force", vim.deepcopy(cached_summary), {
    reason = reason or "state_changed",
  })
  if state_event_pending then
    return
  end
  state_event_pending = true
  vim.schedule(function()
    state_event_pending = false
    local data = state_event_data
    state_event_data = nil
    if data then
      pcall(vim.api.nvim_exec_autocmds, "User", {
        pattern = "AgentManagerStateChanged",
        modeline = false,
        data = data,
      })
    end
  end)
end

local function structured_error(kind, message)
  return { kind = kind, message = message }
end

local function report(err)
  if not err then
    return
  end
  if runtime then
    runtime.model:set_client_state(runtime.client.state, err)
    runtime.view:schedule_render()
  end
  vim.notify("Agent Manager: " .. (err.message or "operation failed"), vim.log.levels.ERROR)
end

local function finish(callback, result, err)
  if callback then
    pcall(callback, result, err)
  end
end

local function remember_workspace(agent)
  if agent and type(agent.provider_session_id) == "string" and type(agent.managed_workspace) == "table" then
    local _, err = SessionWorkspace.save(agent, agent.managed_workspace)
    if err then
      vim.notify("Agent Manager: " .. err, vim.log.levels.ERROR)
    end
  end
end

local function project_root()
  return vim.fs.root(0, { ".git" }) or vim.uv.cwd()
end

local function session_directory(path)
  if type(path) ~= "string" then
    return nil
  end
  local home = vim.uv.os_homedir() or vim.env.HOME
  if path == "" or path == "." or path == "~" then
    return home
  end
  if path:sub(1, 2) == "~/" and home then
    return (home == "/" and "" or home) .. path:sub(2)
  end
  if path:sub(1, 1) ~= "/" and home then
    return (home == "/" and "" or home) .. "/" .. path
  end
  return path
end

local function ensure_setup()
  if runtime then
    return true
  end
  return M.setup({})
end

local function with_client(action, callback)
  local ok, setup_err = ensure_setup()
  if not ok then
    finish(callback, nil, setup_err)
    return nil, setup_err
  end
  local started, start_err = runtime.client:start(function(err)
    if err then
      report(err)
      finish(callback, nil, err)
      return
    end
    action()
  end)
  if not started then
    return nil, start_err
  end
  return true
end

local function selected_id(agent_id)
  if agent_id then
    return agent_id
  end
  return runtime and runtime.model.selected_agent_id or nil
end

local function selected_agent()
  return runtime and runtime.model:selected_agent() or nil
end

local function normalized_provider_options(provider, options)
  options = type(options) == "table" and options or {}
  local normalized = {}
  for _, key in ipairs({ "model", "effort" }) do
    local value = options[key]
    if value ~= nil and value ~= vim.NIL then
      if type(value) ~= "string" or value == "" then
        return nil, structured_error("input", "provider " .. key .. " must be a non-empty string")
      end
      normalized[key] = value
    end
  end
  if
    provider == "claude"
    and normalized.effort
    and not vim.tbl_contains({ "low", "medium", "high", "xhigh", "max" }, normalized.effort)
  then
    return nil, structured_error(
      "input",
      "Claude effort must be low, medium, high, xhigh, or max"
    )
  end
  return next(normalized) and normalized or vim.empty_dict()
end

local function agent_by_id(agent_id)
  for _, agent in ipairs(runtime and runtime.model:list() or {}) do
    if agent.id == agent_id then
      return agent
    end
  end
  return nil
end

local function options_for_agent(agent)
  if not agent then
    return {}
  end
  return vim.deepcopy(
    runtime.agent_options[agent.id] or agent.provider_options or remembered_provider_options[agent.provider] or {}
  )
end

local function remember_options(provider, options)
  remembered_provider_options[provider] = vim.deepcopy(options or {})
end

local function has_live_agent()
  if not runtime then
    return false
  end
  for _, agent in ipairs(runtime.model:list()) do
    if agent.state ~= "disconnected" then
      return true
    end
  end
  return false
end

local function choice_available(action, choice)
  for _, candidate in ipairs(action.payload.choices or {}) do
    if candidate == choice then
      return true
    end
  end
  return false
end

function M.setup(opts)
  if runtime then
    local torn_down, teardown_err = M.teardown()
    if not torn_down then
      return nil, teardown_err
    end
  end
  local config, err = Config.resolve(opts)
  if not config then
    return nil, err
  end
  local model
  local client
  local view
  local ux = UX.new()
  model = Model.new({
    max_events = config.ui.max_events,
    on_change = function(reason)
      publish_state(model, reason)
      for _, agent in ipairs(reason == "broker_state" and model and model:list() or {}) do
        remember_workspace(agent)
      end
    end,
  })
  client = Client.new({
    mode = config.broker.mode,
    command = config.broker.command,
    socket = config.broker.socket,
    reconnect = config.broker.reconnect,
    codex_executable = config.providers.codex.executable,
    claude_python = config.providers.claude.python,
    claude_setting_sources = config.providers.claude.setting_sources,
    workspace_lifecycle = config.worktrees.lifecycle,
    allow_shared_workspaces = config.worktrees.allow_shared,
    on_notification = function(method, params)
      local changed = model:apply_notification(method, params)
      if changed and method == "agent/event" and params.type == "file.changed" then
        changed = Editor.observe_file_event(params, model) or changed
      end
      if changed and view then
        view:schedule_render()
      end
    end,
    on_status = function(state, status_err)
      model:set_client_state(state, status_err)
      if view then
        view:schedule_render()
      end
    end,
    on_resync = function(replay)
      model:begin_resync(replay.latest)
      vim.schedule(function()
        if not runtime or runtime.client ~= client then
          return
        end
        M.refresh(function(result, refresh_err)
          if refresh_err then
            return
          end
          for _, agent in ipairs((result and result.agents) or {}) do
            if agent.state ~= "disconnected" and agent.provider_session_id then
              M.history(agent.id)
            end
          end
        end)
      end)
    end,
  })
  local actions = {
    start = function(context)
      M.start_ui(context)
    end,
    prompt = function(text, callback)
      return M.prompt_ui(text, callback)
    end,
    steer = function()
      M.steer_ui()
    end,
    interrupt = function()
      M.confirm_interrupt()
    end,
    attach = function(session)
      M.attach_ui(session)
    end,
    resume = function(session)
      M.resume_session_ui(session)
    end,
    fork = function(session)
      if not session or not session.id then
        vim.notify(
          "Agent Manager: only a broker-owned session can be forked",
          vim.log.levels.WARN
        )
        return
      end
      runtime.model:select(session.id)
      M.fork(session.id)
    end,
    archive = function(session)
      M.confirm_archive(session)
    end,
    model = function()
      M.model_ui()
    end,
    effort = function()
      M.effort_ui()
    end,
    provider_options = function(agent)
      return options_for_agent(agent)
    end,
    transcript = function(agent_id)
      M.transcript(agent_id)
    end,
    select = function(session)
      runtime.draft = nil
      view:set_draft(nil)
      return model:select(session.id)
    end,
    allow = function(action)
      M.respond_approval(action.agent_id, action.id, "allow")
    end,
    deny = function(action)
      if action.kind == "question" then
        M.respond_question(action.agent_id, action.id, "deny", {})
      else
        M.respond_approval(action.agent_id, action.id, "deny")
      end
    end,
    answer = function(action)
      M.answer_ui(action)
    end,
    context = function()
      M.context_ui()
    end,
    diff = function(target)
      M.diff_ui(target)
    end,
    delete_session = function(session)
      M.confirm_delete_session(session)
    end,
    refresh = function()
      M.refresh()
    end,
  }
  view = View.new(model, actions, config.ui)
  actions.workflows = function() M.open_workflows() end
  view.workflows = require("agent_manager.workflows").new(view, config.workflows, function()
    view.workspace_mode = "sessions"
    view:_build_layout("agents")
    M.open()
  end)
  runtime = {
    config = config,
    model = model,
    client = client,
    view = view,
    ux = ux,
    draft = nil,
    agent_options = {},
    model_catalogs = {},
    transcript_requests = {},
  }
  for _, provider in ipairs({ "codex", "claude" }) do
    local configured = config.providers[provider] or {}
    if next(remembered_provider_options[provider]) == nil then
      local options = normalized_provider_options(provider, configured)
      remembered_provider_options[provider] = options or {}
    end
  end
  publish_state(model, "setup")
  return true
end

function M.open()
  local ok, err = ensure_setup()
  if not ok then
    return nil, err
  end
  runtime.view:add_directory_hint(project_root())
  runtime.view:open()
  local started, start_err = runtime.client:start(function(ready_err)
    if ready_err then
      report(ready_err)
    elseif not runtime.client.resync_required then
      M.refresh()
    end
  end)
  if not started then
    report(start_err)
    return nil, start_err
  end
  return true
end

function M.open_workflows()
  local ok, err = ensure_setup()
  if not ok then return nil, err end
  runtime.view:open()
  runtime.view.workflows:open()
  return true
end

function M.close()
  if not runtime then
    return true
  end
  return runtime.view:close()
end

local function valid_managed_identifier(value, allow_dot)
  if type(value) ~= "string" or value == "" or #value > 128 then
    return false
  end
  local previous_separator = true
  for index = 1, #value do
    local character = value:sub(index, index)
    if character:match("[a-z0-9]") then
      previous_separator = false
    elseif (character == "-" or (allow_dot and character == ".")) and not previous_separator then
      previous_separator = true
    else
      return false
    end
  end
  return not previous_separator
end

local function request_agent_start(params, callback)
  return with_client(function()
    local _, request_err = runtime.client:request("agent/start", params, function(result, rpc_err)
      if rpc_err then
        report(rpc_err)
        finish(callback, nil, rpc_err)
        return
      end
      if result and result.agent then
        remember_workspace(result.agent)
        runtime.agent_options[result.agent.id] = vim.deepcopy(
          result.agent.provider_options or params.provider_options or {}
        )
        remember_options(result.agent.provider, runtime.agent_options[result.agent.id])
        runtime.draft = nil
        runtime.view:set_draft(nil)
        runtime.model:select(result.agent.id)
        runtime.view:schedule_render()
      end
      finish(callback, result, nil)
    end)
    if request_err then
      report(request_err)
      finish(callback, nil, request_err)
    end
  end, callback)
end

function M.start(opts, callback)
  opts = opts or {}
  if type(opts) ~= "table" then
    local err = structured_error("input", "start options must be a table")
    finish(callback, nil, err)
    return nil, err
  end
  local provider = opts.provider or "codex"
  if provider ~= "codex" and provider ~= "claude" then
    local err = structured_error("input", "provider must be 'codex' or 'claude'")
    finish(callback, nil, err)
    return nil, err
  end
  local provider_options, options_err = normalized_provider_options(provider, opts.provider_options)
  if not provider_options then
    finish(callback, nil, options_err)
    return nil, options_err
  end
  if opts.managed_workspace ~= nil then
    local workspace = opts.managed_workspace
    if type(workspace) ~= "table" then
      local err = structured_error("input", "managed_workspace must be a table")
      finish(callback, nil, err)
      return nil, err
    end
    if
      not valid_managed_identifier(workspace.repository, true)
      or not valid_managed_identifier(workspace.task_id, false)
    then
      local err = structured_error(
        "input",
        "managed repository and task IDs must use normalized lowercase names"
      )
      finish(callback, nil, err)
      return nil, err
    end
    if workspace.resume ~= nil and type(workspace.resume) ~= "boolean" then
      local err = structured_error("input", "managed_workspace.resume must be a boolean")
      finish(callback, nil, err)
      return nil, err
    end
    return request_agent_start({
      provider = provider,
      provider_options = provider_options,
      managed_workspace = {
        repository = workspace.repository,
        task_id = workspace.task_id,
        resume = workspace.resume == true,
      },
    }, callback)
  end
  local cwd = opts.cwd or project_root()
  if type(cwd) ~= "string" then
    local err = structured_error("input", "cwd must be a directory path")
    finish(callback, nil, err)
    return nil, err
  end
  cwd = vim.uv.fs_realpath(vim.fs.normalize(cwd))
  if not cwd then
    local err = structured_error("input", "cwd does not identify an existing directory")
    finish(callback, nil, err)
    return nil, err
  end
  local strategy = opts.workspace_strategy or "shared"
  if strategy ~= "shared" and strategy ~= "worktree" then
    local err = structured_error("input", "workspace_strategy must be 'shared' or 'worktree'")
    finish(callback, nil, err)
    return nil, err
  end
  local worktree_path = nil
  if strategy == "worktree" then
    if type(opts.worktree_path) ~= "string" then
      local err = structured_error("input", "worktree strategy requires worktree_path")
      finish(callback, nil, err)
      return nil, err
    end
    worktree_path = vim.uv.fs_realpath(vim.fs.normalize(opts.worktree_path))
    if worktree_path ~= cwd then
      local err = structured_error("input", "worktree_path must identify the agent cwd")
      finish(callback, nil, err)
      return nil, err
    end
  end
  return request_agent_start({
    provider = provider,
    provider_options = provider_options,
    cwd = cwd,
    workspace_strategy = strategy,
    worktree_path = worktree_path,
  }, callback)
end

local function normalize_input(input)
  if type(input) == "string" then
    if input == "" then
      return nil, structured_error("input", "input text must not be empty")
    end
    return { text = input, attachments = {} }
  end
  if type(input) ~= "table" then
    return nil, structured_error("input", "input must be text or a table")
  end
  if type(input.text) ~= "string" or input.text == "" then
    return nil, structured_error("input", "input.text must not be empty")
  end
  return {
    text = input.text,
    attachments = vim.deepcopy(input.attachments or {}),
  }
end

local function send_input(method, kind, agent_id, input, callback)
  local normalized, input_err = normalize_input(input)
  if not normalized then
    finish(callback, nil, input_err)
    return nil, input_err
  end
  local ok, setup_err = ensure_setup()
  if not ok then
    finish(callback, nil, setup_err)
    return nil, setup_err
  end
  agent_id = selected_id(agent_id)
  if not agent_id then
    local err = structured_error("input", "no agent is selected")
    finish(callback, nil, err)
    return nil, err
  end
  local params = { agent_id = agent_id, input = normalized }
  if kind == "prompt" then
    local agent = agent_by_id(agent_id)
    if not agent then
      local err = structured_error("input", "the selected agent is no longer available")
      finish(callback, nil, err)
      return nil, err
    end
    local provider_options, options_err = normalized_provider_options(
      agent.provider,
      options_for_agent(agent)
    )
    if not provider_options then
      finish(callback, nil, options_err)
      return nil, options_err
    end
    params.provider_options = provider_options
    params.queue = true
  end
  return with_client(function()
    local _, request_err = runtime.client:request(
      method,
      params,
      function(result, rpc_err)
        if rpc_err then
          report(rpc_err)
          finish(callback, nil, rpc_err)
          return
        end
        if result and result.queued then
          vim.notify("Agent Manager: prompt queued (" .. tostring(result.position) .. ")", vim.log.levels.INFO)
        end
        runtime.view:schedule_render()
        finish(callback, result, nil)
      end
    )
    if request_err then
      report(request_err)
      finish(callback, nil, request_err)
    end
  end, callback)
end

function M.prompt(agent_id, input, callback)
  return send_input("agent/prompt", "prompt", agent_id, input, callback)
end

function M.steer(agent_id, input, callback)
  return send_input("agent/steer", "steer", agent_id, input, callback)
end

function M.interrupt(agent_id, callback)
  local ok, setup_err = ensure_setup()
  if not ok then
    finish(callback, nil, setup_err)
    return nil, setup_err
  end
  agent_id = selected_id(agent_id)
  if not agent_id then
    local err = structured_error("input", "no agent is selected")
    finish(callback, nil, err)
    return nil, err
  end
  return with_client(function()
    local _, request_err = runtime.client:request(
      "agent/interrupt",
      { agent_id = agent_id },
      function(result, rpc_err)
        if rpc_err then
          report(rpc_err)
        end
        finish(callback, result, rpc_err)
      end
    )
    if request_err then
      report(request_err)
      finish(callback, nil, request_err)
    end
  end, callback)
end

function M.attach(agent_id, callback)
  local ok, setup_err = ensure_setup()
  if not ok then
    finish(callback, nil, setup_err)
    return nil, setup_err
  end
  agent_id = selected_id(agent_id)
  if not agent_id then
    local err = structured_error("input", "no broker-owned agent is selected")
    finish(callback, nil, err)
    return nil, err
  end
  return with_client(function()
    local _, request_err = runtime.client:request(
      "agent/attach",
      { agent_id = agent_id },
      function(result, rpc_err)
        if rpc_err then
          report(rpc_err)
          finish(callback, nil, rpc_err)
          return
        end
        if result and result.agent then
          remember_workspace(result.agent)
          runtime.draft = nil
          runtime.view:set_draft(nil)
          runtime.agent_options[result.agent.id] = vim.deepcopy(result.agent.provider_options or {})
          remember_options(result.agent.provider, runtime.agent_options[result.agent.id])
          runtime.model:select(result.agent.id)
          runtime.view:schedule_render()
        end
        finish(callback, result, nil)
      end
    )
    if request_err then
      report(request_err)
      finish(callback, nil, request_err)
    end
  end, callback)
end

function M.workspaces(callback)
  return with_client(function()
    local _, request_err = runtime.client:request("workspace/list", {}, function(result, rpc_err)
      if rpc_err then
        report(rpc_err)
        finish(callback, nil, rpc_err)
        return
      end
      if result and result.repositories then
        runtime.model:apply_workspace_inventory(result.repositories)
        runtime.view:schedule_render()
      end
      finish(callback, result, nil)
    end)
    if request_err then
      report(request_err)
      finish(callback, nil, request_err)
    end
  end, callback)
end

function M.handoff_workspace(repository, task_id, callback)
  if
    not valid_managed_identifier(repository, true)
    or not valid_managed_identifier(task_id, false)
  then
    local err = structured_error("input", "invalid managed repository or task ID")
    finish(callback, nil, err)
    return nil, err
  end
  return with_client(function()
    local _, request_err = runtime.client:request(
      "workspace/handoff",
      { repository = repository, task_id = task_id },
      function(result, rpc_err)
        if rpc_err then
          report(rpc_err)
          finish(callback, nil, rpc_err)
          return
        end
        finish(callback, result, nil)
      end
    )
    if request_err then
      report(request_err)
      finish(callback, nil, request_err)
    end
  end, callback)
end

function M.sessions(opts, callback)
  opts = opts or {}
  if type(opts) ~= "table" or (opts.provider ~= "codex" and opts.provider ~= "claude") then
    local err = structured_error("input", "session discovery requires a Codex or Claude provider")
    finish(callback, nil, err)
    return nil, err
  end
  if opts.active_only ~= nil and type(opts.active_only) ~= "boolean" then
    local err = structured_error("input", "active_only must be a boolean")
    finish(callback, nil, err)
    return nil, err
  end
  local cwd = nil
  if opts.cwd ~= nil then
    if type(opts.cwd) ~= "string" then
      local err = structured_error("input", "cwd must be a directory path")
      finish(callback, nil, err)
      return nil, err
    end
    cwd = vim.uv.fs_realpath(vim.fs.normalize(opts.cwd))
    if not cwd then
      local err = structured_error("input", "cwd does not identify an existing directory")
      finish(callback, nil, err)
      return nil, err
    end
  end
  return with_client(function()
    local params = {
      provider = opts.provider,
      cursor = opts.cursor or vim.NIL,
      limit = opts.limit or 50,
      active_only = opts.active_only == true,
    }
    if cwd then
      params.cwd = cwd
    end
    local _, request_err = runtime.client:request(
      "provider/session/list",
      params,
      function(result, rpc_err)
        if rpc_err then
          report(rpc_err)
        end
        finish(callback, result, rpc_err)
      end
    )
    if request_err then
      report(request_err)
      finish(callback, nil, request_err)
    end
  end, callback)
end

function M.models(provider, callback)
  if provider ~= "codex" and provider ~= "claude" then
    local err = structured_error("input", "model discovery requires a Codex or Claude provider")
    finish(callback, nil, err)
    return nil, err
  end
  if runtime and runtime.model_catalogs[provider] then
    finish(callback, vim.deepcopy(runtime.model_catalogs[provider]), nil)
    return true
  end
  return with_client(function()
    local _, request_err = runtime.client:request(
      "provider/model/list",
      { provider = provider },
      function(result, rpc_err)
        if runtime and result and type(result.models) == "table" then
          runtime.model_catalogs[provider] = vim.deepcopy(result)
        end
        if rpc_err then
          report(rpc_err)
        end
        finish(callback, result, rpc_err)
      end
    )
    if request_err then
      report(request_err)
      finish(callback, nil, request_err)
    end
  end, callback)
end

function M.resume(opts, callback)
  opts = opts or {}
  if type(opts) ~= "table" then
    local err = structured_error("input", "resume options must be a table")
    finish(callback, nil, err)
    return nil, err
  end
  local provider = opts.provider
  local session_id = opts.provider_session_id or opts.session_id
  if (provider ~= "codex" and provider ~= "claude") or type(session_id) ~= "string" or session_id == "" then
    local err = structured_error("input", "resume requires a provider and provider_session_id")
    finish(callback, nil, err)
    return nil, err
  end
  local params = {
    provider = provider,
    provider_session_id = session_id,
  }
  local saved, mapping_err = SessionWorkspace.load(params)
  if mapping_err then
    local err = structured_error("workspace", mapping_err)
    finish(callback, nil, err)
    return nil, err
  end
  if saved then
    local requested = opts.managed_workspace
    local conflicts = requested ~= nil and (type(requested) ~= "table"
      or requested.repository ~= saved.repository or requested.task_id ~= saved.task_id)
    if conflicts or opts.cwd ~= nil or opts.worktree_path ~= nil or opts.workspace_strategy ~= nil
    then
      local err = structured_error("workspace", "Resume must reuse the saved session workspace")
      finish(callback, nil, err)
      return nil, err
    end
    opts = vim.tbl_extend("force", opts, {
      managed_workspace = { repository = saved.repository, task_id = saved.task_id, resume = true },
    })
  end
  local provider_options, options_err = normalized_provider_options(provider, opts.provider_options)
  if not provider_options then
    finish(callback, nil, options_err)
    return nil, options_err
  end
  params.provider_options = provider_options
  if opts.managed_workspace ~= nil then
    local workspace = opts.managed_workspace
    if type(workspace) ~= "table" then
      local err = structured_error("input", "managed_workspace must be a table")
      finish(callback, nil, err)
      return nil, err
    end
    if
      not valid_managed_identifier(workspace.repository, true)
      or not valid_managed_identifier(workspace.task_id, false)
    then
      local err = structured_error(
        "input",
        "managed repository and session names must use normalized lowercase names"
      )
      finish(callback, nil, err)
      return nil, err
    end
    if workspace.resume ~= nil and type(workspace.resume) ~= "boolean" then
      local err = structured_error("input", "managed_workspace.resume must be a boolean")
      finish(callback, nil, err)
      return nil, err
    end
    params.managed_workspace = {
      repository = workspace.repository,
      task_id = workspace.task_id,
      resume = workspace.resume == true,
    }
  else
    local cwd = opts.cwd or project_root()
    if type(cwd) ~= "string" then
      local err = structured_error("input", "cwd must be a directory path")
      finish(callback, nil, err)
      return nil, err
    end
    cwd = vim.uv.fs_realpath(vim.fs.normalize(cwd))
    if not cwd then
      local err = structured_error("input", "cwd does not identify an existing directory")
      finish(callback, nil, err)
      return nil, err
    end
    local strategy = opts.workspace_strategy or "shared"
    if strategy ~= "shared" and strategy ~= "worktree" then
      local err = structured_error("input", "workspace_strategy must be 'shared' or 'worktree'")
      finish(callback, nil, err)
      return nil, err
    end
    local worktree_path = nil
    if strategy == "worktree" then
      if type(opts.worktree_path) ~= "string" then
        local err = structured_error("input", "worktree strategy requires worktree_path")
        finish(callback, nil, err)
        return nil, err
      end
      worktree_path = vim.uv.fs_realpath(vim.fs.normalize(opts.worktree_path))
      if worktree_path ~= cwd then
        local err = structured_error("input", "worktree_path must identify the agent cwd")
        finish(callback, nil, err)
        return nil, err
      end
    end
    params.cwd = cwd
    params.workspace_strategy = strategy
    params.worktree_path = worktree_path
  end
  return with_client(function()
    local _, request_err = runtime.client:request(
      "agent/resume",
      params,
      function(result, rpc_err)
        if rpc_err then
          report(rpc_err)
          finish(callback, nil, rpc_err)
          return
        end
        if result and result.agent then
          remember_workspace(result.agent)
          runtime.draft = nil
          runtime.view:set_draft(nil)
          runtime.agent_options[result.agent.id] = vim.deepcopy(
            result.agent.provider_options or provider_options
          )
          remember_options(result.agent.provider, runtime.agent_options[result.agent.id])
          runtime.model:select(result.agent.id)
          M.history(result.agent.id)
          runtime.view:schedule_render()
        end
        finish(callback, result, nil)
      end
    )
    if request_err then
      report(request_err)
      finish(callback, nil, request_err)
    end
  end, callback)
end

function M.fork(agent_id, callback)
  if not ensure_setup() then
    local err = structured_error("configuration", "Agent Manager setup failed")
    finish(callback, nil, err)
    return nil, err
  end
  agent_id = selected_id(agent_id)
  if not agent_id then
    local err = structured_error("input", "no agent is selected")
    finish(callback, nil, err)
    return nil, err
  end
  return with_client(function()
    local _, request_err = runtime.client:request(
      "agent/fork",
      { agent_id = agent_id },
      function(result, rpc_err)
        if rpc_err then
          report(rpc_err)
          finish(callback, nil, rpc_err)
          return
        end
        if result and result.agent then
          remember_workspace(result.agent)
          runtime.draft = nil
          runtime.view:set_draft(nil)
          runtime.agent_options[result.agent.id] = vim.deepcopy(result.agent.provider_options or {})
          remember_options(result.agent.provider, runtime.agent_options[result.agent.id])
          runtime.model:select(result.agent.id)
          M.history(result.agent.id)
          runtime.view:schedule_render()
        end
        finish(callback, result, nil)
      end
    )
    if request_err then
      report(request_err)
      finish(callback, nil, request_err)
    end
  end, callback)
end

function M.archive(agent_id, callback)
  if not ensure_setup() then
    local err = structured_error("configuration", "Agent Manager setup failed")
    finish(callback, nil, err)
    return nil, err
  end
  agent_id = selected_id(agent_id)
  if not agent_id then
    local err = structured_error("input", "no agent is selected")
    finish(callback, nil, err)
    return nil, err
  end
  return with_client(function()
    local _, request_err = runtime.client:request(
      "agent/archive",
      { agent_id = agent_id },
      function(result, rpc_err)
        if rpc_err then
          report(rpc_err)
        end
        finish(callback, result, rpc_err)
      end
    )
    if request_err then
      report(request_err)
      finish(callback, nil, request_err)
    end
  end, callback)
end

function M.history(agent_id, callback)
  if not ensure_setup() then
    local err = structured_error("configuration", "Agent Manager setup failed")
    finish(callback, nil, err)
    return nil, err
  end
  agent_id = selected_id(agent_id)
  if not agent_id then
    local err = structured_error("input", "no agent is selected")
    finish(callback, nil, err)
    return nil, err
  end
  return with_client(function()
    local _, request_err = runtime.client:request(
      "agent/history",
      { agent_id = agent_id, cursor = vim.NIL, limit = 200 },
      function(result, rpc_err)
        if rpc_err then
          report(rpc_err)
        end
        finish(callback, result, rpc_err)
      end
    )
    if request_err then
      report(request_err)
      finish(callback, nil, request_err)
    end
  end, callback)
end

-- Fetch the broker-owned transcript snapshot for an agent. The view asks for
-- it when no cached transcript exists or a patch could not be applied in
-- order; one request per agent is in flight at a time.
function M.transcript(agent_id, callback)
  if not ensure_setup() then
    local err = structured_error("configuration", "Agent Manager setup failed")
    finish(callback, nil, err)
    return nil, err
  end
  agent_id = selected_id(agent_id)
  if not agent_id then
    local err = structured_error("input", "no agent is selected")
    finish(callback, nil, err)
    return nil, err
  end
  if runtime.transcript_requests[agent_id] then
    finish(callback, nil, nil)
    return true
  end
  runtime.transcript_requests[agent_id] = true
  local requesting = runtime
  return with_client(function()
    local _, request_err = runtime.client:request(
      "agent/transcript",
      { agent_id = agent_id },
      function(result, rpc_err)
        if runtime == requesting then
          runtime.transcript_requests[agent_id] = nil
        end
        if runtime == requesting and result and runtime.model:set_transcript(result) then
          runtime.view:schedule_render()
        end
        if rpc_err then
          report(rpc_err)
        end
        finish(callback, result, rpc_err)
      end
    )
    if request_err then
      if runtime == requesting then
        runtime.transcript_requests[agent_id] = nil
      end
      report(request_err)
      finish(callback, nil, request_err)
    end
  end, callback)
end

function M.respond_approval(agent_id, approval_id, decision, opts, callback)
  if type(opts) == "function" then
    callback = opts
    opts = {}
  end
  opts = opts or {}
  if
    type(opts) ~= "table"
    or type(approval_id) ~= "string"
    or not ({ allow = true, deny = true, defer = true })[decision]
    or (opts.updated_input ~= nil and type(opts.updated_input) ~= "table")
    or (opts.message ~= nil and type(opts.message) ~= "string")
  then
    local err = structured_error("input", "invalid approval response")
    finish(callback, nil, err)
    return nil, err
  end
  if not ensure_setup() then
    local err = structured_error("configuration", "Agent Manager setup failed")
    finish(callback, nil, err)
    return nil, err
  end
  agent_id = selected_id(agent_id)
  if not agent_id then
    local err = structured_error("input", "no agent is selected")
    finish(callback, nil, err)
    return nil, err
  end
  return with_client(function()
    local _, request_err = runtime.client:request(
      "agent/approval/respond",
      {
        agent_id = agent_id,
        approval_id = approval_id,
        decision = decision,
        updated_input = opts.updated_input,
        message = opts.message or vim.NIL,
      },
      function(result, rpc_err)
        if rpc_err then
          report(rpc_err)
        end
        finish(callback, result, rpc_err)
      end
    )
    if request_err then
      report(request_err)
      finish(callback, nil, request_err)
    end
  end, callback)
end

function M.respond_question(agent_id, question_id, decision, answers, opts, callback)
  if type(opts) == "function" then
    callback = opts
    opts = {}
  end
  opts = opts or {}
  if
    type(opts) ~= "table"
    or type(question_id) ~= "string"
    or (decision ~= "answer" and decision ~= "deny")
    or type(answers) ~= "table"
    or (opts.message ~= nil and type(opts.message) ~= "string")
  then
    local err = structured_error("input", "invalid question response")
    finish(callback, nil, err)
    return nil, err
  end
  if not ensure_setup() then
    local err = structured_error("configuration", "Agent Manager setup failed")
    finish(callback, nil, err)
    return nil, err
  end
  agent_id = selected_id(agent_id)
  if not agent_id then
    local err = structured_error("input", "no agent is selected")
    finish(callback, nil, err)
    return nil, err
  end
  return with_client(function()
    local _, request_err = runtime.client:request(
      "agent/question/respond",
      {
        agent_id = agent_id,
        question_id = question_id,
        decision = decision,
        answers = next(answers) and answers or vim.empty_dict(),
        message = opts.message or vim.NIL,
      },
      function(result, rpc_err)
        if rpc_err then
          report(rpc_err)
        end
        finish(callback, result, rpc_err)
      end
    )
    if request_err then
      report(request_err)
      finish(callback, nil, request_err)
    end
  end, callback)
end

function M.add_context(agent_id, context, callback)
  if type(context) ~= "table" then
    local err = structured_error("input", "context must be a table")
    finish(callback, nil, err)
    return nil, err
  end
  if not ensure_setup() then
    local err = structured_error("configuration", "Agent Manager setup failed")
    finish(callback, nil, err)
    return nil, err
  end
  agent_id = selected_id(agent_id)
  if not agent_id then
    local err = structured_error("input", "no agent is selected")
    finish(callback, nil, err)
    return nil, err
  end
  return with_client(function()
    local _, request_err = runtime.client:request(
      "agent/context/add",
      { agent_id = agent_id, context = vim.deepcopy(context) },
      function(result, rpc_err)
        if rpc_err then
          report(rpc_err)
        end
        finish(callback, result, rpc_err)
      end
    )
    if request_err then
      report(request_err)
      finish(callback, nil, request_err)
    end
  end, callback)
end

function M.diff(agent_id, callback)
  if not ensure_setup() then
    local err = structured_error("configuration", "Agent Manager setup failed")
    finish(callback, nil, err)
    return nil, err
  end
  agent_id = selected_id(agent_id)
  if not agent_id then
    local err = structured_error("input", "no agent is selected")
    finish(callback, nil, err)
    return nil, err
  end
  return with_client(function()
    local _, request_err = runtime.client:request(
      "agent/diff",
      { agent_id = agent_id },
      function(result, rpc_err)
        if rpc_err then
          report(rpc_err)
        end
        finish(callback, result, rpc_err)
      end
    )
    if request_err then
      report(request_err)
      finish(callback, nil, request_err)
    end
  end, callback)
end

function M.workspace_diff(cwd, callback)
  if type(cwd) ~= "string" then
    local err = structured_error("input", "workspace diff requires a directory path")
    finish(callback, nil, err)
    return nil, err
  end
  cwd = vim.uv.fs_realpath(vim.fs.normalize(cwd))
  if not cwd then
    local err = structured_error("input", "workspace diff directory does not exist")
    finish(callback, nil, err)
    return nil, err
  end
  return with_client(function()
    local _, request_err = runtime.client:request(
      "workspace/diff",
      { cwd = cwd },
      function(result, rpc_err)
        if rpc_err then
          report(rpc_err)
        end
        finish(callback, result, rpc_err)
      end
    )
    if request_err then
      report(request_err)
      finish(callback, nil, request_err)
    end
  end, callback)
end

function M.delete_session(session, callback)
  if type(session) ~= "table" then
    local err = structured_error("input", "session deletion requires a focused session")
    finish(callback, nil, err)
    return nil, err
  end
  local provider = session.provider
  local provider_session_id = session.provider_session_id
  if
    (provider ~= "codex" and provider ~= "claude")
    or type(provider_session_id) ~= "string"
    or provider_session_id == ""
  then
    local err = structured_error("input", "session deletion requires a provider session identity")
    finish(callback, nil, err)
    return nil, err
  end
  if type(session.cwd) ~= "string" then
    local err = structured_error("input", "session deletion requires a directory path")
    finish(callback, nil, err)
    return nil, err
  end
  local raw_cwd = session_directory(session.cwd)
  local cwd = raw_cwd and vim.uv.fs_realpath(vim.fs.normalize(raw_cwd)) or nil
  if not cwd then
    local err = structured_error("input", "session directory does not exist")
    finish(callback, nil, err)
    return nil, err
  end
  return with_client(function()
    local _, request_err = runtime.client:request(
      "provider/session/delete",
      {
        provider = provider,
        provider_session_id = provider_session_id,
        cwd = cwd,
      },
      function(result, rpc_err)
        if rpc_err then
          report(rpc_err)
          finish(callback, nil, rpc_err)
          return
        end
        M.refresh(function(_, refresh_err)
          finish(callback, result, refresh_err)
        end)
      end
    )
    if request_err then
      report(request_err)
      finish(callback, nil, request_err)
    end
  end, callback)
end

local function refresh_external_sessions(callback)
  if not runtime.config.ui.external_sessions then
    runtime.model:clear_external_sessions()
    callback({ sessions = {}, activity = {} })
    return
  end
  local remaining = 2
  local activity = {}
  local function settle(provider, result, err)
    local sessions = result and result.sessions or {}
    local available = result and result.activity_available == true or false
    runtime.model:apply_external_sessions(provider, sessions, available, err)
    activity[provider] = {
      available = available,
      error = err,
    }
    remaining = remaining - 1
    if remaining == 0 then
      callback({
        sessions = runtime.model:external_session_list(),
        activity = activity,
      })
    end
  end
  for _, provider in ipairs({ "codex", "claude" }) do
    local current_provider = provider
    local _, request_err = runtime.client:request(
      "provider/session/list",
      {
        provider = current_provider,
        cursor = vim.NIL,
        limit = runtime.config.ui.external_session_limit,
        active_only = false,
      },
      function(result, rpc_err)
        settle(current_provider, result, rpc_err)
      end
    )
    if request_err then
      settle(current_provider, nil, request_err)
    end
  end
end

function M.refresh(callback)
  local ok, setup_err = ensure_setup()
  if not ok then
    finish(callback, nil, setup_err)
    return nil, setup_err
  end
  runtime.ux:refresh()
  return with_client(function()
    local _, request_err = runtime.client:request("agent/list", {}, function(result, rpc_err)
      if result and result.agents then
        runtime.model:apply_state(result.agents)
        runtime.view:schedule_render()
      end
      if rpc_err then
        report(rpc_err)
        finish(callback, nil, rpc_err)
        return
      end
      result = result or {}
      refresh_external_sessions(function(external)
        result.external_sessions = external.sessions
        result.external_activity = external.activity
        result.repositories = runtime.model:workspace_list()
        runtime.view:schedule_render()
        finish(callback, result, nil)
      end)
    end)
    if request_err then
      report(request_err)
      finish(callback, nil, request_err)
    end
  end, callback)
end

local function repository_label(repository)
  local state = repository.canonical_clean and "clean" or "dirty"
  return string.format(
    "%s · base %s · %s",
    repository.slug,
    repository.base_branch,
    state
  )
end

local function load_workspace_inventory(callback)
  M.workspaces(function(result, err)
    if err then
      callback(nil, err)
      return
    end
    local repositories = result and result.repositories or {}
    if #repositories == 0 then
      vim.notify("Agent Manager: no registered repositories are available", vim.log.levels.WARN)
      callback({}, nil)
      return
    end
    callback(repositories, nil)
  end)
end

local function schedule_ui(callback)
  local owner = runtime
  vim.schedule(function()
    if runtime == owner then
      callback()
    end
  end)
end

local function normalized_path(path)
  if type(path) ~= "string" or path == "" then
    return nil
  end
  local normalized = vim.fs.normalize(path):gsub("/+$", "")
  return normalized == "" and "/" or normalized
end

local function path_within(path, root)
  path = normalized_path(path)
  root = normalized_path(root)
  if not path or not root then
    return false
  end
  return root == "/" or path == root or path:sub(1, #root + 1) == root .. "/"
end

local function managed_layout_context(context)
  context = type(context) == "table" and context or {}
  if valid_managed_identifier(context.repository, true) then
    return { repository = context.repository }
  end
  if type(context.cwd) ~= "string" or context.cwd == "" then
    return nil
  end
  local cwd = vim.uv.fs_realpath(vim.fs.normalize(context.cwd))
  if not cwd then
    return nil
  end
  local git_root = vim.fs.root(cwd, { ".git" })
  if not git_root then
    return nil
  end
  git_root = normalized_path(vim.uv.fs_realpath(git_root) or git_root)
  local home = vim.uv.os_homedir() or vim.env.HOME
  home = home and normalized_path(vim.uv.fs_realpath(home) or home) or nil
  if not git_root or not home or not path_within(git_root, home) or git_root == home then
    return nil
  end
  local relative = git_root:sub(#home + 2)
  local parts = vim.split(relative, "/", { plain = true, trimempty = true })
  local repository = nil
  local task_id = nil
  if #parts == 1 then
    repository = parts[1]:lower()
  elseif #parts == 3 and parts[1] == "worktrees" then
    repository = parts[2]:lower()
    task_id = parts[3]
  end
  if not valid_managed_identifier(repository, true) then
    return nil
  end
  if task_id and not valid_managed_identifier(task_id, false) then
    return nil
  end
  return { repository = repository, task_id = task_id }
end

local function contextual_repository(repositories, context)
  context = type(context) == "table" and context or {}
  if type(context.repository) == "string" then
    for _, repository in ipairs(repositories) do
      if repository.slug == context.repository then
        return repository
      end
    end
  end
  local selected = nil
  local selected_length = -1
  for _, repository in ipairs(repositories) do
    local roots = { repository.canonical_path }
    if repository.worktree_root ~= nil and repository.worktree_root ~= vim.NIL then
      table.insert(roots, repository.worktree_root)
    end
    for _, root in ipairs(roots) do
      if type(root) == "string" and path_within(context.cwd, root) and #root > selected_length then
        selected = repository
        selected_length = #root
      end
    end
  end
  return selected
end

local function provider_name(provider)
  return provider == "claude" and "Claude Code" or "Codex"
end

local function picker_text(value)
  return tostring(value or ""):gsub("%z", "�"):gsub("[\r\n]", " ")
end

local function picker_key(index)
  if index <= 9 then
    return tostring(index)
  end
  if index <= 35 then
    return string.char(string.byte("a") + index - 10)
  end
  return tostring(index)
end

local function model_choices(models, default_model)
  local choices = {
    {
      model = default_model,
      display_name = "Default",
      description = default_model and ("Use " .. default_model) or "Use the provider default",
      default_choice = true,
    },
  }
  local seen = {}
  for _, model in ipairs(type(models) == "table" and models or {}) do
    if
      type(model) == "table"
      and type(model.id) == "string"
      and model.id ~= ""
      and not seen[model.id]
    then
      seen[model.id] = true
      table.insert(choices, {
        model = model.id,
        display_name = type(model.display_name) == "string" and model.display_name or model.id,
        description = type(model.description) == "string" and model.description or nil,
        provider_default = model.is_default == true,
      })
    end
  end
  for index, choice in ipairs(choices) do
    choice.key = picker_key(index)
  end
  return choices
end

local function model_choice_label(choice)
  local label = choice.key .. "  " .. picker_text(choice.display_name)
  if choice.provider_default then
    label = label .. " (provider default)"
  end
  if choice.description and choice.description ~= "" then
    label = label .. " — " .. picker_text(choice.description)
  end
  return label
end

local function select_model(provider, default_model, prompt, callback)
  local expected_runtime = runtime
  M.models(provider, function(result, err)
    if err then
      return
    end
    schedule_ui(function()
      if not runtime or runtime ~= expected_runtime then
        return
      end
      local choices = model_choices(result and result.models or {}, default_model)
      vim.ui.select(choices, {
        prompt = prompt,
        format_item = model_choice_label,
      }, function(choice)
        if choice then
          schedule_ui(function()
            if runtime == expected_runtime then
              callback(choice.model)
            end
          end)
        end
      end)
    end)
  end)
end

local function begin_session_draft(provider, context, repository)
  local options = vim.deepcopy(remembered_provider_options[provider] or {})
  select_model(
    provider,
    options.model,
    "New " .. provider_name(provider) .. " session · choose model",
    function(model)
      options.model = model
      local normalized, options_err = normalized_provider_options(provider, options)
      if not normalized then
        report(options_err)
        return
      end
      remember_options(provider, normalized)
      schedule_ui(function()
        if not runtime then
          return
        end
        runtime.draft = {
          provider = provider,
          provider_options = normalized,
          context = vim.deepcopy(context),
          repository = repository and repository.slug or nil,
          starting = false,
        }
        runtime.view:set_draft(runtime.draft)
        runtime.view:render()
        runtime.view:focus_prompt()
      end)
    end
  )
end

local function start_new_session(provider, context)
  if not runtime.config.worktrees.lifecycle and runtime.config.worktrees.allow_shared then
    begin_session_draft(provider, context, nil)
    return
  end

  local cached = runtime.model:workspace_list()
  local known = contextual_repository(cached, context)
  local layout = managed_layout_context(context)
  if not known and layout then
    for _, repository in ipairs(cached) do
      if repository.slug == layout.repository then
        known = repository
        break
      end
    end
    known = known or { slug = layout.repository }
  end
  if known then
    begin_session_draft(provider, context, known)
    return
  end

  vim.notify("Agent Manager: loading registered repositories for " .. provider_name(provider) .. "…")
  load_workspace_inventory(function(repositories)
    if not repositories then
      return
    end
    local repository = contextual_repository(repositories, context)
    if repository then
      begin_session_draft(provider, context, repository)
      return
    end
    vim.ui.select(repositories, {
      prompt = "New " .. provider_name(provider) .. " session · choose directory",
      format_item = repository_label,
    }, function(selected)
      if selected then
        schedule_ui(function()
          begin_session_draft(provider, context, selected)
        end)
      end
    end)
  end)
end

function M.start_ui(context)
  if not ensure_setup() then
    return
  end
  context = type(context) == "table" and vim.deepcopy(context) or {}
  if runtime.config.broker.mode == "embedded" and has_live_agent() then
    vim.notify("Agent Manager embedded mode supports one live agent", vim.log.levels.WARN)
    return
  end
  if context.provider == "codex" or context.provider == "claude" then
    start_new_session(context.provider, context)
    return
  end
  vim.ui.select({ "codex", "claude" }, {
    prompt = "Start a new session · choose provider",
    format_item = provider_name,
  }, function(provider)
    if provider then
      schedule_ui(function()
        start_new_session(provider, context)
      end)
    end
  end)
end

local function active_session(session)
  if session.external_active == true then
    return true
  end
  if session.external then
    return session.active == true
  end
  return session.state ~= "disconnected" and session.state ~= "failed"
end

local function session_label(session)
  local updated = session.updated_at and session.updated_at ~= vim.NIL
      and (" · " .. tostring(session.updated_at))
    or ""
  local status = active_session(session) and "ACTIVE"
    or session.activity_known == false and "CHECK"
    or "RESUME"
  local cwd = session_directory(session.cwd) or "unknown cwd"
  return string.format(
    "%s · %s · %s · %s%s",
    provider_name(session.provider),
    status,
    session.title or session.provider_session_id,
    cwd,
    updated
  )
end

local function resume_notice(session, result)
  local agent = result and result.agent
  if agent then
    vim.notify(string.format(
      "Agent Manager: continued %s in %s — press tp to prompt",
      provider_name(session.provider),
      agent.cwd
    ))
  end
end

local function resume_with_workspace(session, managed_workspace)
  vim.notify("Agent Manager: continuing " .. provider_name(session.provider) .. " session…")
  local ok, resume_err = M.resume({
    provider = session.provider,
    provider_session_id = session.provider_session_id,
    provider_options = session.provider_options or remembered_provider_options[session.provider],
    managed_workspace = managed_workspace,
  }, function(result, err)
    if not err then
      resume_notice(session, result)
    end
  end)
  if not ok and resume_err then
    report(resume_err)
  end
end

local function task_for_directory(repositories, cwd)
  local selected_repository = nil
  local selected_task = nil
  local selected_length = -1
  for _, repository in ipairs(repositories) do
    for _, task in ipairs(repository.tasks or {}) do
      if type(task.path) == "string" and path_within(cwd, task.path) and #task.path > selected_length then
        selected_repository = repository
        selected_task = task
        selected_length = #task.path
      end
    end
  end
  return selected_repository, selected_task
end

local function automatic_resume_workspace(session, repository, repositories)
  local task_id = SessionWorkspace.task_id(session)
  for _, candidate in ipairs(repositories) do
    if candidate.slug == repository.slug then
      for _, task in ipairs(candidate.tasks or {}) do
        if task.task_id == task_id then
          resume_with_workspace(session, {
            repository = repository.slug,
            task_id = task_id,
            resume = true,
          })
          return
        end
      end
    end
  end
  resume_with_workspace(session, { repository = repository.slug, task_id = task_id, resume = false })
end

function M.resume_session_ui(session)
  if not ensure_setup() or type(session) ~= "table" then
    return
  end
  session = vim.deepcopy(session)
  session.cwd = session_directory(session.cwd) or session.cwd
  if active_session(session) then
    if session.external or session.external_active == true then
      vim.notify(
        "Agent Manager: this session is active in another terminal; switch to that terminal to avoid two writers",
        vim.log.levels.WARN
      )
    elseif session.id then
      M.attach(session.id)
    end
    return
  end
  if type(session.provider_session_id) ~= "string" or session.provider_session_id == "" then
    vim.notify("Agent Manager: this entry has no saved provider session to continue", vim.log.levels.WARN)
    return
  end
  if session.activity_known == false then
    vim.notify(
      "Agent Manager: provider activity could not be checked, so this session cannot be continued safely",
      vim.log.levels.WARN
    )
    return
  end
  if runtime.config.broker.mode == "embedded" and has_live_agent() then
    vim.notify("Agent Manager embedded mode supports one live agent", vim.log.levels.WARN)
    return
  end
  local saved, mapping_err = SessionWorkspace.load(session)
  if mapping_err then
    vim.notify("Agent Manager: " .. mapping_err, vim.log.levels.ERROR)
    return
  end
  local managed = session.managed_workspace
  if managed and managed ~= vim.NIL and saved
    and (managed.repository ~= saved.repository or managed.task_id ~= saved.task_id)
  then
    vim.notify(
      "Agent Manager: conflicting session workspaces; restore the original mapping before resuming",
      vim.log.levels.ERROR
    )
    return
  end
  managed = saved or managed
  if managed and managed ~= vim.NIL then
    resume_with_workspace(session, {
      repository = managed.repository,
      task_id = managed.task_id,
      resume = true,
    })
    return
  end

  local layout = managed_layout_context({ cwd = session.cwd })
  if layout and layout.task_id then
    resume_with_workspace(session, {
      repository = layout.repository,
      task_id = layout.task_id,
      resume = true,
    })
    return
  end

  -- CLI sessions can live outside Git (for example, in the home directory).
  -- There is no checkout to lease there, and a global cleanup audit is both
  -- unnecessary and too expensive for opening a saved conversation.
  local cwd = type(session.cwd) == "string" and vim.uv.fs_realpath(session.cwd) or nil
  local home = vim.uv.os_homedir()
  local task_root = home and (home .. "/worktrees") or nil
  if session.provider == "codex" and cwd and vim.fn.isdirectory(cwd) == 1
    and not vim.fs.root(cwd, { ".git" }) and not path_within(cwd, task_root)
  then
    local ok, resume_err = M.resume({
      provider = session.provider,
      provider_session_id = session.provider_session_id,
      provider_options = session.provider_options or remembered_provider_options[session.provider],
      cwd = cwd,
      workspace_strategy = "shared",
    }, function(result, err)
      if not err then resume_notice(session, result) end
    end)
    if not ok and resume_err then report(resume_err) end
    return
  end

  vim.notify("Agent Manager: finding a safe workspace for the saved session…")
  load_workspace_inventory(function(repositories)
    if not repositories then
      return
    end
    local repository, task = task_for_directory(repositories, session.cwd)
    if repository and task then
      resume_with_workspace(session, {
        repository = repository.slug,
        task_id = task.task_id,
        resume = true,
      })
      return
    end
    repository = contextual_repository(repositories, { cwd = session.cwd })
    if repository and path_within(session.cwd, repository.canonical_path) then
      automatic_resume_workspace(session, repository, repositories)
      return
    end
    if repository then
      vim.notify(
        "Agent Manager: the saved task workspace is missing from the inventory; restore it before resuming",
        vim.log.levels.ERROR
      )
      return
    end
    if runtime.config.worktrees.allow_shared then
      M.resume({
        provider = session.provider,
        provider_session_id = session.provider_session_id,
        provider_options = session.provider_options or remembered_provider_options[session.provider],
        cwd = session.cwd,
        workspace_strategy = "shared",
      }, function(result, err)
        if not err then
          resume_notice(session, result)
        end
      end)
      return
    end
    vim.notify(
      "Agent Manager: the saved session directory is not a registered repository: " .. tostring(session.cwd),
      vim.log.levels.ERROR
    )
  end)
end

function M.attach_ui(focused_session)
  if not ensure_setup() then
    return
  end
  if type(focused_session) == "table" then
    M.resume_session_ui(focused_session)
    return
  end
  local choices = runtime.model:session_list()
  if #choices == 0 then
    vim.notify("Agent Manager: no sessions are available")
    return
  end
  vim.ui.select(choices, {
    prompt = "Open or continue session",
    format_item = session_label,
  }, function(session)
    if session then
      M.resume_session_ui(session)
    end
  end)
end

local function input_ui(prompt, callback)
  vim.ui.input({ prompt = prompt }, function(text)
    if text and text ~= "" then
      callback(text)
    end
  end)
end

local function start_draft_with_prompt(text, callback)
  local draft = runtime and runtime.draft
  if not draft then
    local err = structured_error("input", "no session draft is configured")
    finish(callback, nil, err)
    return nil, err
  end
  if draft.starting then
    vim.notify("Agent Manager: the session is already starting", vim.log.levels.WARN)
    return true
  end
  draft.starting = true
  runtime.view:set_draft(draft)
  local callback_finished = false
  local function complete(result, err)
    if callback_finished then
      return
    end
    callback_finished = true
    finish(callback, result, err)
  end
  local start_options = {
    provider = draft.provider,
    provider_options = draft.provider_options,
  }
  if draft.repository then
    start_options.managed_workspace = {
      repository = draft.repository,
      task_id = SessionWorkspace.new_task_id(),
      resume = false,
    }
  else
    start_options.cwd = draft.context.cwd or project_root()
    start_options.workspace_strategy = "shared"
  end
  local ok, start_err = M.start(start_options, function(result, err)
    if err then
      if runtime and runtime.draft == draft then
        draft.starting = false
        runtime.view:set_draft(draft)
      end
      complete(nil, err)
      return
    end
    local agent = result and result.agent
    if not agent then
      local missing_err = structured_error("protocol", "broker start response omitted the agent")
      if runtime and runtime.draft == draft then
        draft.starting = false
        runtime.view:set_draft(draft)
      end
      report(missing_err)
      complete(nil, missing_err)
      return
    end
    local prompted, prompt_err = M.prompt(agent.id, text, complete)
    if not prompted and prompt_err then
      report(prompt_err)
      complete(nil, prompt_err)
    end
  end)
  if not ok then
    draft.starting = false
    runtime.view:set_draft(draft)
    if start_err then
      report(start_err)
    end
    complete(nil, start_err)
  end
  return ok, start_err
end

local function provider_option_subject()
  if runtime.draft then
    return runtime.draft.provider, runtime.draft.provider_options, runtime.draft
  end
  local agent = selected_agent()
  if not agent then
    return nil
  end
  return agent.provider, options_for_agent(agent), agent
end

local function update_provider_option(provider, subject, key, value)
  local options = vim.deepcopy(
    subject == runtime.draft and subject.provider_options or options_for_agent(subject)
  )
  options[key] = value
  local normalized, options_err = normalized_provider_options(provider, options)
  if not normalized then
    report(options_err)
    return false
  end
  subject.provider_options = normalized
  remember_options(provider, normalized)
  if subject == runtime.draft then
    runtime.draft.provider_options = normalized
    runtime.view:set_draft(runtime.draft)
  else
    runtime.agent_options[subject.id] = normalized
    runtime.view:schedule_render()
  end
  return true
end

function M.model_ui()
  if not ensure_setup() then
    return
  end
  local provider, options, subject = provider_option_subject()
  if not provider then
    vim.notify("Agent Manager: start or select a session before changing its model", vim.log.levels.WARN)
    return
  end
  select_model(provider, options.model, provider_name(provider) .. " model", function(model)
    update_provider_option(provider, subject, "model", model)
  end)
end

function M.effort_ui()
  if not ensure_setup() then
    return
  end
  local provider, options, subject = provider_option_subject()
  if not provider then
    vim.notify("Agent Manager: start or select a session before changing effort", vim.log.levels.WARN)
    return
  end
  local choices = provider == "claude"
      and { "default", "low", "medium", "high", "xhigh", "max" }
    or { "default", "minimal", "low", "medium", "high", "xhigh", "max" }
  local current = options.effort or "default"
  for index, value in ipairs(choices) do
    if value == current and index > 1 then
      table.remove(choices, index)
      table.insert(choices, 1, value)
      break
    end
  end
  vim.ui.select(choices, {
    prompt = provider_name(provider) .. " effort",
    format_item = function(value)
      return value == current and (value .. " (current)") or value
    end,
  }, function(effort)
    if effort then
      update_provider_option(
        provider,
        subject,
        "effort",
        effort ~= "default" and effort or nil
      )
    end
  end)
end

function M.prompt_ui(initial, callback)
  if not ensure_setup() then
    return
  end
  local function focus_prompt()
    runtime.view:open()
    return runtime.view:focus_prompt()
  end
  if runtime.draft then
    if initial and initial ~= "" then
      return start_draft_with_prompt(initial, callback)
    end
    return focus_prompt()
  end
  local agent = selected_agent()
  if not agent then
    local err = structured_error(
      "input",
      "no agent is selected — press 1, focus a directory, then press sn"
    )
    report(err)
    finish(callback, nil, err)
    return nil, err
  end
  if agent.state == "disconnected" or agent.state == "failed" then
    local err = structured_error(
      "input",
      "the selected session is not active — press 1, focus its resumable row, then press Enter"
    )
    report(err)
    finish(callback, nil, err)
    return nil, err
  end
  if initial and initial ~= "" then
    local ok, err = M.prompt(nil, initial, callback)
    if not ok and err then
      report(err)
    end
    return ok, err
  end
  return focus_prompt()
end

function M.steer_ui(initial)
  if initial and initial ~= "" then
    return M.steer(nil, initial)
  end
  input_ui("Steer: ", function(text)
    M.steer(nil, text)
  end)
end

function M.confirm_interrupt()
  if not runtime or not runtime.model.selected_agent_id then
    report(structured_error("input", "no agent is selected"))
    return
  end
  vim.ui.select({ "Cancel", "Interrupt" }, { prompt = "Interrupt active turn?" }, function(choice)
    if choice == "Interrupt" then
      M.interrupt()
    end
  end)
end

function M.confirm_archive(session)
  if type(session) == "table" then
    if not session.id then
      vim.notify(
        "Agent Manager: only a broker-owned session can be archived; use ds to delete saved provider history",
        vim.log.levels.WARN
      )
      return
    end
    runtime.model:select(session.id)
  end
  local agent = selected_agent()
  if not agent then
    report(structured_error("input", "no agent is selected"))
    return
  end
  vim.ui.select({ "Cancel", "Archive" }, {
    prompt = "Archive " .. tostring(agent.title or agent.id) .. " from Agent Manager?",
  }, function(choice)
    if choice == "Archive" then
      M.archive(agent.id)
    end
  end)
end

function M.confirm_delete_session(session)
  if not ensure_setup() then
    return
  end
  if type(session) ~= "table" and runtime.view then
    session = runtime.view:_focused_session()
  end
  session = type(session) == "table" and session or selected_agent()
  if type(session) ~= "table" then
    vim.notify("Agent Manager: focus a session before pressing ds", vim.log.levels.WARN)
    return
  end
  if type(session.provider_session_id) ~= "string" or session.provider_session_id == "" then
    vim.notify("Agent Manager: this entry has no saved provider history to delete", vim.log.levels.WARN)
    return
  end
  if session.external_active == true or (session.external and session.active == true) then
    vim.notify(
      "Agent Manager: this session is active in another terminal and cannot be deleted",
      vim.log.levels.WARN
    )
    return
  end
  if
    session.state == "starting"
    or session.state == "running"
    or session.state == "waiting_input"
    or session.state == "waiting_approval"
  then
    vim.notify("Agent Manager: active work must finish or be interrupted before deletion", vim.log.levels.WARN)
    return
  end
  local label = session.title or session.provider_session_id or "session"
  vim.ui.select({ "Cancel", "Delete session permanently" }, {
    prompt = string.format(
      "Delete %s provider history for %s? The worktree and project files will be kept.",
      provider_name(session.provider),
      label
    ),
  }, function(choice)
    if choice ~= "Delete session permanently" then
      return
    end
    M.delete_session(session, function(result, err)
      if err then
        return
      end
      local suffix = result and result.workspace_handed_off and " and released its workspace lease"
        or ""
      vim.notify("Agent Manager: deleted provider session" .. suffix .. "; files were preserved")
    end)
  end)
end

local function answer_question(action, questions, index, answers)
  local question = questions[index]
  if not question then
    M.respond_question(action.agent_id, action.id, "answer", answers)
    return
  end
  local prompt = (question.header and (question.header .. ": ") or "")
    .. (question.question or "Answer")
  local options = question.options or {}
  if #options > 0 and not question.multi_select and not question.secret then
    vim.ui.select(options, {
      prompt = prompt,
      format_item = function(option)
        local description = option.description and option.description ~= ""
            and (" — " .. option.description)
          or ""
        return tostring(option.label) .. description
      end,
    }, function(option)
      if option then
        answers[question.id] = tostring(option.label)
        answer_question(action, questions, index + 1, answers)
      end
    end)
    return
  end

  local function accept(value)
    if value == nil then
      return
    end
    if question.multi_select then
      local selected = {}
      for item in value:gmatch("[^,]+") do
        item = vim.trim(item)
        if item ~= "" then
          table.insert(selected, item)
        end
      end
      answers[question.id] = selected
    else
      answers[question.id] = value
    end
    answer_question(action, questions, index + 1, answers)
  end

  local suffix = question.multi_select and " (comma-separated)" or ""
  local input_prompt = prompt .. suffix .. ": "
  if question.secret then
    local ok, value = pcall(vim.fn.inputsecret, input_prompt)
    if ok then
      accept(value)
    end
  else
    vim.ui.input({ prompt = input_prompt }, accept)
  end
end

function M.answer_ui(action)
  if not ensure_setup() then
    return
  end
  action = action or runtime.model:focused_action()
  if not action or action.kind ~= "question" or not choice_available(action, "answer") then
    vim.notify("Agent Manager: focus a pending question before answering", vim.log.levels.WARN)
    return
  end
  local questions = action.payload.questions or {}
  if #questions == 0 then
    report(structured_error("protocol", "the provider question has no answerable prompts"))
    return
  end
  answer_question(action, questions, 1, {})
end

local function capture_context(kind, agent, buffer)
  Editor.capture(kind, agent, { bufnr = buffer }, function(context, err)
    if err then
      report(err)
      return
    end
    M.add_context(agent.id, context, function(result, rpc_err)
      if not rpc_err then
        vim.notify(
          string.format("Agent Manager: queued %s context (%d total)", kind, result.count or 1)
        )
      end
    end)
  end)
end

function M.context_ui()
  if not ensure_setup() then
    return
  end
  local agent = selected_agent()
  if not agent then
    report(structured_error("input", "no agent is selected"))
    return
  end
  local current = vim.api.nvim_get_current_buf()
  local candidates = Editor.context_buffers(agent)
  local preferred = nil
  for _, candidate in ipairs(candidates) do
    if candidate.bufnr == current then
      preferred = candidate
      break
    end
  end

  local function select_kind(candidate)
    vim.ui.select({ "buffer", "range", "diagnostics", "diff" }, {
      prompt = "Context from " .. candidate.label,
    }, function(kind)
      if kind then
        capture_context(kind, agent, candidate.bufnr)
      end
    end)
  end

  if preferred then
    select_kind(preferred)
  elseif #candidates == 0 then
    report(structured_error("editor_context", "no loaded file buffer belongs to the agent cwd"))
  else
    vim.ui.select(candidates, {
      prompt = "Context source buffer",
      format_item = function(candidate)
        return candidate.label .. (candidate.modified and " [unsaved]" or "")
      end,
    }, function(candidate)
      if candidate then
        select_kind(candidate)
      end
    end)
  end
end

local function resolve_conflict(conflict, resolution)
  runtime.model:resolve_file_conflict(conflict.agent_id, conflict.path, resolution)
  runtime.view:schedule_render()
end

local function conflict_ui(conflict)
  vim.ui.select({ "Inspect buffer", "Show disk/buffer diff", "Reload from disk", "Keep buffer" }, {
    prompt = "Resolve external change: " .. conflict.path,
  }, function(choice)
    if choice == "Inspect buffer" then
      local _, err = Editor.inspect(conflict)
      report(err)
    elseif choice == "Show disk/buffer diff" then
      local diff, err = Editor.conflict_diff(conflict)
      if err then
        report(err)
      else
        runtime.view:show_diff(diff, "DISK ↔ DIRTY BUFFER · " .. conflict.path)
      end
    elseif choice == "Reload from disk" then
      vim.ui.select({ "Cancel", "Reload and discard buffer edits" }, {
        prompt = "Discard unsaved edits in " .. conflict.path .. "?",
      }, function(confirm)
        if confirm == "Reload and discard buffer edits" then
          local ok, err = Editor.reload(conflict)
          if ok then
            resolve_conflict(conflict, "reloaded")
          else
            report(err)
          end
        end
      end)
    elseif choice == "Keep buffer" then
      resolve_conflict(conflict, "kept_buffer")
      vim.notify("Agent Manager: kept the dirty buffer without reloading")
    end
  end)
end

function M.diff_ui(target)
  if not ensure_setup() then
    return
  end
  if type(target) == "table" and target.id then
    runtime.model:select(target.id)
  end
  local agent = selected_agent()
  local target_is_agent = type(target) ~= "table" or (target.id and agent and agent.id == target.id)
  if type(target) == "table" and not target.id then
    local cwd = target.cwd
    M.workspace_diff(cwd, function(result, err)
      if not err then
        local title = "WORKSPACE DIFF · " .. (result.cwd or cwd)
        if result.truncated then
          title = title .. " · TRUNCATED"
        end
        runtime.view:show_diff(result.diff or "", title)
      end
    end)
    return
  end
  if not agent or not target_is_agent then
    report(structured_error("input", "focus a session or directory before opening its diff"))
    return
  end
  local conflicts = runtime.model:file_conflict_list(agent.id)
  if #conflicts > 0 then
    if #conflicts == 1 then
      conflict_ui(conflicts[1])
    else
      vim.ui.select(conflicts, {
        prompt = "Dirty buffers changed on disk",
        format_item = function(conflict)
          return conflict.path
        end,
      }, function(conflict)
        if conflict then
          conflict_ui(conflict)
        end
      end)
    end
    return
  end
  M.diff(agent.id, function(result, err)
    if not err then
      local title = "WORKSPACE DIFF · " .. (result.cwd or agent.cwd)
      if result.truncated then
        title = title .. " · TRUNCATED"
      end
      runtime.view:show_diff(result.diff or "", title)
    end
  end)
end

function M.list()
  if not ensure_setup() then
    return {}
  end
  return runtime.model:list()
end

function M.status()
  if not runtime then
    return {
      model = {
        agents = {},
        client_state = "stopped",
      },
      client = { state = "stopped" },
      view = {
        open = false,
        buffers = {},
        windows = {},
        backend = "native",
      },
      summary = vim.deepcopy(cached_summary),
    }
  end
  return {
    model = runtime.model:snapshot(),
    client = runtime.client:status(),
    view = runtime.view:status(),
    summary = vim.deepcopy(cached_summary),
  }
end

function M.running_count()
  return cached_summary.running_count
end

function M.pending_approval_count()
  return cached_summary.pending_approval_count
end

function M.health()
  local status = M.status()
  local config = runtime and runtime.config or select(1, Config.resolve({}))
  local broker = status.client or {}
  if config and broker.command == nil then
    broker.command = vim.deepcopy(config.broker.command)
  end
  return {
    neovim = tostring(vim.version()),
    root = config and config.root or nil,
    broker = broker,
    mode = config and config.broker.mode or nil,
    codex_executable = config and config.providers.codex.executable or nil,
    claude_python = config and config.providers.claude.python or nil,
    claude_setting_sources = config and config.providers.claude.setting_sources or nil,
    worktrees = config and vim.deepcopy(config.worktrees) or nil,
    agents = status.model and status.model.agents or {},
    ux = runtime and runtime.ux:status() or UX.detect(),
    markdown = status.view and status.view.markdown
      or { enabled = config and config.ui.conversation_markdown ~= false, active = false },
  }
end

function M.teardown()
  if not runtime then
    return true
  end
  local old = runtime
  runtime = nil
  old.view:teardown()
  old.client:stop()
  local ux_ok, ux_err = old.ux:teardown()
  publish_state(nil, "teardown")
  if not ux_ok then
    return nil, structured_error("ux_teardown", "UX presentation teardown failed: " .. tostring(
      type(ux_err) == "table" and (ux_err.message or vim.inspect(ux_err)) or ux_err
    ))
  end
  return true
end

return M
