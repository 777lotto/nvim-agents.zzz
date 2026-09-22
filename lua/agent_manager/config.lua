local M = {}

local function source_root()
  local source = debug.getinfo(1, "S").source
  if source:sub(1, 1) == "@" then
    source = source:sub(2)
  end
  return vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(source)))
end

local function executable(path)
  return type(path) == "string" and vim.fn.executable(path) == 1
end

local function user_path(environment, fallback)
  local root = vim.env[environment]
  if type(root) ~= "string" or root == "" then
    local home = vim.env.HOME
    if type(home) ~= "string" or home == "" or home:sub(1, 1) ~= "/" then
      return nil
    end
    root = home .. fallback
  end
  if root:sub(1, 1) ~= "/" then
    return nil
  end
  return vim.fs.normalize(root)
end

local function installed_broker()
  local bin = user_path("XDG_BIN_HOME", "/.local/bin")
  return bin and bin .. "/agent-manager-broker" or nil
end

local function installed_worker_python()
  local data = user_path("XDG_DATA_HOME", "/.local/share")
  return data and data .. "/agent-manager/venv/bin/python" or nil
end

local function default_broker_command(root)
  local release = root .. "/target/release/agent-manager-broker"
  local debug = root .. "/target/debug/agent-manager-broker"
  local installed = installed_broker()
  if executable(release) then
    return { release, "serve" }
  end
  if executable(debug) then
    return { debug, "serve" }
  end
  if executable(installed) then
    return { installed, "serve" }
  end
  return { "agent-manager-broker", "serve" }
end

local function default_claude_python(root)
  local source = root .. "/python/.venv/bin/python"
  if executable(source) then
    return source
  end
  local installed = installed_worker_python()
  return executable(installed) and installed or nil
end

local function discovered_executable(name)
  local path = vim.fn.exepath(name)
  return type(path) == "string" and path ~= "" and vim.fs.normalize(path) or nil
end

local function default_socket()
  local runtime = vim.env.XDG_RUNTIME_DIR
  if type(runtime) ~= "string" or runtime == "" or runtime:sub(1, 1) ~= "/" then
    return nil
  end
  return vim.fs.normalize(runtime .. "/agent-manager/broker.sock")
end

local function defaults()
  local root = source_root()
  return {
    broker = {
      mode = "embedded",
      command = default_broker_command(root),
      socket = default_socket(),
      reconnect = {
        initial_delay = 100,
        max_delay = 5000,
        max_attempts = 8,
        jitter = 0.2,
      },
    },
    providers = {
      codex = {
        executable = discovered_executable("codex"),
        model = nil,
        effort = nil,
      },
      claude = {
        python = default_claude_python(root),
        model = nil,
        effort = nil,
      },
    },
    worktrees = {
      lifecycle = discovered_executable("zemrip-agent-workspace"),
      allow_shared = false,
    },
    workflows = {
      python = default_claude_python(root),
      root = nil,
      refresh_ms = 2000,
    },
    ui = {
      max_events = 2000,
      agent_width = 40,
      activity_width = 38,
      prompt_min_height = 3,
      prompt_max_height = 12,
      external_sessions = true,
      external_session_limit = 1000,
    },
    root = root,
  }
end

local function reconnect_error(reconnect)
  if type(reconnect) ~= "table" then
    return "broker.reconnect must be a table"
  end
  for _, key in ipairs({ "initial_delay", "max_delay", "max_attempts" }) do
    local value = reconnect[key]
    if type(value) ~= "number" or value < 1 or value % 1 ~= 0 then
      return "broker.reconnect." .. key .. " must be a positive integer"
    end
  end
  if reconnect.max_delay < reconnect.initial_delay then
    return "broker.reconnect.max_delay must be at least initial_delay"
  end
  if type(reconnect.jitter) ~= "number" or reconnect.jitter < 0 or reconnect.jitter > 1 then
    return "broker.reconnect.jitter must be between 0 and 1"
  end
end

local function command_error(command)
  if type(command) ~= "table" or #command == 0 then
    return "broker.command must be a non-empty argv list"
  end
  for _, argument in ipairs(command) do
    if type(argument) ~= "string" or argument == "" then
      return "every broker.command argument must be a non-empty string"
    end
  end
end

function M.resolve(opts)
  if opts ~= nil and type(opts) ~= "table" then
    return nil, { kind = "configuration", message = "setup options must be a table" }
  end
  opts = opts or {}
  local config = vim.tbl_deep_extend("force", defaults(), opts)
  if type(config.workflows) ~= "table"
      or type(config.workflows.refresh_ms) ~= "number"
      or config.workflows.refresh_ms < 500
      or config.workflows.refresh_ms > 60000
      or config.workflows.refresh_ms % 1 ~= 0
      or (config.workflows.python ~= nil and (type(config.workflows.python) ~= "string"
        or config.workflows.python:sub(1, 1) ~= "/"))
      or (config.workflows.root ~= nil and (type(config.workflows.root) ~= "string"
        or config.workflows.root:sub(1, 1) ~= "/")) then
    return nil, { kind = "configuration", message = "workflows needs absolute paths and refresh_ms between 500 and 60000" }
  end
  if opts.broker and opts.broker.command then
    config.broker.command = vim.deepcopy(opts.broker.command)
  end
  if config.broker.mode ~= "embedded" and config.broker.mode ~= "durable" then
    return nil, {
      kind = "configuration",
      message = "broker.mode must be 'embedded' or 'durable'",
    }
  end
  local message = command_error(config.broker.command)
  if message then
    return nil, { kind = "configuration", message = message }
  end
  if config.broker.mode == "durable" then
    if config.broker.command[1]:sub(1, 1) ~= "/" or not executable(config.broker.command[1]) then
      return nil, {
        kind = "configuration",
        message = "durable broker.command must begin with an absolute executable path",
      }
    end
    if
      type(config.broker.socket) ~= "string"
      or config.broker.socket == ""
      or config.broker.socket:sub(1, 1) ~= "/"
    then
      return nil, {
        kind = "configuration",
        message = "durable broker.socket must be an absolute path",
      }
    end
    config.broker.socket = vim.fs.normalize(config.broker.socket)
    local reconnect_message = reconnect_error(config.broker.reconnect)
    if reconnect_message then
      return nil, { kind = "configuration", message = reconnect_message }
    end
  end
  local python = config.providers.claude.python
  if python ~= nil and python ~= false and (type(python) ~= "string" or python == "") then
    return nil, {
      kind = "configuration",
      message = "providers.claude.python must be a path, false, or nil",
    }
  end
  if type(python) == "string" and python:sub(1, 1) ~= "/" then
    return nil, {
      kind = "configuration",
      message = "providers.claude.python must be an absolute path",
    }
  end
  local codex = config.providers.codex.executable
  if codex ~= nil and codex ~= false and (type(codex) ~= "string" or codex == "") then
    return nil, {
      kind = "configuration",
      message = "providers.codex.executable must be a path, false, or nil",
    }
  end
  if type(codex) == "string" and codex:sub(1, 1) ~= "/" then
    return nil, {
      kind = "configuration",
      message = "providers.codex.executable must be an absolute path",
    }
  end
  for _, provider in ipairs({ "codex", "claude" }) do
    for _, key in ipairs({ "model", "effort" }) do
      local value = config.providers[provider][key]
      if value ~= nil and (type(value) ~= "string" or value == "") then
        return nil, {
          kind = "configuration",
          message = "providers." .. provider .. "." .. key .. " must be a non-empty string",
        }
      end
    end
  end
  local claude_effort = config.providers.claude.effort
  if
    claude_effort
    and not vim.tbl_contains({ "low", "medium", "high", "xhigh", "max" }, claude_effort)
  then
    return nil, {
      kind = "configuration",
      message = "providers.claude.effort is not supported",
    }
  end
  local lifecycle = config.worktrees.lifecycle
  if
    lifecycle ~= nil
    and lifecycle ~= false
    and (type(lifecycle) ~= "string" or lifecycle == "")
  then
    return nil, {
      kind = "configuration",
      message = "worktrees.lifecycle must be an absolute path, false, or nil",
    }
  end
  if type(lifecycle) == "string" and lifecycle:sub(1, 1) ~= "/" then
    return nil, {
      kind = "configuration",
      message = "worktrees.lifecycle must be an absolute path",
    }
  end
  if type(config.worktrees.allow_shared) ~= "boolean" then
    return nil, {
      kind = "configuration",
      message = "worktrees.allow_shared must be a boolean",
    }
  end
  if type(config.ui.max_events) ~= "number" or config.ui.max_events < 1 then
    return nil, { kind = "configuration", message = "ui.max_events must be positive" }
  end
  for _, key in ipairs({ "prompt_min_height", "prompt_max_height" }) do
    local value = config.ui[key]
    if type(value) ~= "number" or value < 1 or value % 1 ~= 0 then
      return nil, {
        kind = "configuration",
        message = "ui." .. key .. " must be a positive integer",
      }
    end
  end
  if config.ui.prompt_max_height < config.ui.prompt_min_height then
    return nil, {
      kind = "configuration",
      message = "ui.prompt_max_height must be at least ui.prompt_min_height",
    }
  end
  if type(config.ui.external_sessions) ~= "boolean" then
    return nil, { kind = "configuration", message = "ui.external_sessions must be a boolean" }
  end
  if
    type(config.ui.external_session_limit) ~= "number"
    or config.ui.external_session_limit < 1
    or config.ui.external_session_limit > 1000
    or config.ui.external_session_limit % 1 ~= 0
  then
    return nil, {
      kind = "configuration",
      message = "ui.external_session_limit must be an integer from 1 to 1000",
    }
  end
  return config
end

return M
