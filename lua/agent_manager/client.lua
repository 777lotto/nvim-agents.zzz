local Client = {}
Client.__index = Client

local protocol_version = 1
local protocol_revision = 2

local function error_object(kind, message, code)
  return { kind = kind, message = message, code = code }
end

local function copy_chunks(data)
  local chunks = {}
  for index, chunk in ipairs(data or {}) do
    chunks[index] = chunk
  end
  return chunks
end

local function object_params(params)
  if params == nil or (type(params) == "table" and next(params) == nil) then
    return vim.empty_dict()
  end
  return params
end

local function close_handle(handle)
  if not handle then
    return
  end
  pcall(function()
    if not handle:is_closing() then
      handle:close()
    end
  end)
end

function Client.new(opts)
  local reconnect = opts.reconnect or {}
  return setmetatable({
    mode = opts.mode or "embedded",
    command = vim.deepcopy(opts.command),
    socket = opts.socket,
    codex_executable = opts.codex_executable,
    claude_python = opts.claude_python,
    claude_setting_sources = opts.claude_setting_sources,
    workspace_lifecycle = opts.workspace_lifecycle,
    allow_shared_workspaces = opts.allow_shared_workspaces == true,
    reconnect = {
      initial_delay = reconnect.initial_delay or 100,
      max_delay = reconnect.max_delay or 5000,
      max_attempts = reconnect.max_attempts or 8,
      jitter = reconnect.jitter or 0.2,
    },
    on_notification = opts.on_notification or function() end,
    on_status = opts.on_status or function() end,
    on_resync = opts.on_resync or function() end,
    job_id = nil,
    pipe = nil,
    reconnect_timer = nil,
    reconnect_attempt = 0,
    reconnect_delay = nil,
    generation = 0,
    next_id = 1,
    pending = {},
    ready_waiters = {},
    stdout_partial = "",
    state = "stopped",
    initialized = nil,
    last_error = nil,
    last_sequence = 0,
    resync_required = false,
    stopping = false,
  }, Client)
end

function Client:_argv()
  local command = vim.deepcopy(self.command)
  if
    self.mode == "embedded"
    and type(self.codex_executable) == "string"
    and self.codex_executable ~= ""
  then
    table.insert(command, "--codex-bin")
    table.insert(command, self.codex_executable)
  end
  if self.mode == "embedded" and type(self.claude_python) == "string" and self.claude_python ~= "" then
    table.insert(command, "--claude-python")
    table.insert(command, self.claude_python)
  end
  if
    self.mode == "embedded"
    and type(self.claude_setting_sources) == "table"
    and #self.claude_setting_sources > 0
  then
    table.insert(command, "--claude-setting-sources")
    table.insert(command, table.concat(self.claude_setting_sources, ","))
  end
  if self.mode == "embedded" then
    if type(self.workspace_lifecycle) == "string" and self.workspace_lifecycle ~= "" then
      table.insert(command, "--workspace-lifecycle")
      table.insert(command, self.workspace_lifecycle)
    else
      table.insert(command, "--disable-workspace-lifecycle")
    end
    if not self.allow_shared_workspaces then
      table.insert(command, "--deny-shared-workspaces")
    end
  end
  return command
end

function Client:_set_state(state, err)
  self.state = state
  if err then
    self.last_error = err
  elseif state == "connected" then
    self.last_error = nil
  end
  pcall(self.on_status, state, err)
end

function Client:_finish_ready(err)
  local waiters = self.ready_waiters
  self.ready_waiters = {}
  for _, callback in ipairs(waiters) do
    pcall(callback, err)
  end
end

function Client:start(callback)
  if callback then
    table.insert(self.ready_waiters, callback)
  end
  if self.state == "connected" then
    self:_finish_ready(nil)
    return true
  end
  if
    self.state == "starting"
    or self.state == "connecting"
    or self.state == "negotiating"
    or self.state == "reconnecting"
  then
    return true
  end

  self.stopping = false
  self.reconnect_attempt = 0
  self.reconnect_delay = nil
  return self:_open_transport(false)
end

function Client:_open_transport(reconnecting)
  self.generation = self.generation + 1
  local generation = self.generation
  self.stdout_partial = ""
  if self.mode == "durable" then
    return self:_connect_pipe(generation, reconnecting)
  end
  return self:_start_job(generation)
end

function Client:_start_job(generation)
  self:_set_state("starting")
  local job_id = vim.fn.jobstart(self:_argv(), {
    stdin = "pipe",
    stdout_buffered = false,
    stderr_buffered = false,
    on_stdout = function(_, data)
      local chunks = copy_chunks(data)
      vim.schedule(function()
        if self.generation == generation then
          self:_on_stdout(chunks)
        end
      end)
    end,
    on_stderr = function(_, data)
      if data and #data > 1 then
        vim.schedule(function()
          if self.generation == generation then
            self.last_error = error_object(
              "broker_diagnostic",
              "broker wrote a diagnostic to standard error; content was not retained"
            )
          end
        end)
      end
    end,
    on_exit = function(_, code)
      vim.schedule(function()
        if self.generation == generation then
          self:_on_exit(code)
        end
      end)
    end,
  })
  if job_id <= 0 then
    local err = error_object("spawn", "could not start the Agent Manager broker", job_id)
    self.job_id = nil
    self:_set_state("failed", err)
    self:_finish_ready(err)
    return nil, err
  end
  self.job_id = job_id
  self:_begin_initialize()
  return true
end

function Client:_connect_pipe(generation, reconnecting)
  local pipe = vim.uv.new_pipe(false)
  if not pipe then
    local err = error_object("socket", "could not allocate a Unix socket client")
    self:_set_state("failed", err)
    self:_finish_ready(err)
    return nil, err
  end
  self.pipe = pipe
  self:_set_state(reconnecting and "reconnecting" or "connecting")
  local connected = pcall(pipe.connect, pipe, self.socket, function(connect_err)
    vim.schedule(function()
      if self.generation ~= generation or self.pipe ~= pipe then
        close_handle(pipe)
        return
      end
      if connect_err then
        self.pipe = nil
        close_handle(pipe)
        self:_connection_lost(error_object("socket", "could not connect to the durable broker"))
        return
      end
      pipe:read_start(function(read_err, data)
        vim.schedule(function()
          if self.generation ~= generation or self.pipe ~= pipe then
            return
          end
          if read_err then
            self:_connection_lost(error_object("socket", "durable broker socket read failed"))
          elseif data == nil then
            self:_connection_lost(error_object("disconnected", "durable broker disconnected"))
          else
            self:_on_bytes(data)
          end
        end)
      end)
      self:_begin_initialize()
    end)
  end)
  if not connected then
    self.pipe = nil
    close_handle(pipe)
    local err = error_object("socket", "could not connect to the durable broker")
    self:_connection_lost(err)
  end
  return true
end

function Client:_begin_initialize()
  self:_set_state("negotiating")
  local last_sequence = self.mode == "durable" and self.last_sequence or vim.NIL
  local _, err = self:request(
    "initialize",
    {
      protocol_version = protocol_version,
      client = {
        name = "agent-manager.nvim",
        title = "Agent Manager",
        version = "0.2.0",
      },
      last_sequence = last_sequence,
    },
    function(result, request_err)
      if request_err then
        if self.mode == "durable" then
          self:_connection_lost(request_err)
        else
          self:_protocol_fault(request_err)
        end
        return
      end
      if
        not result
        or result.protocol_version ~= protocol_version
        or (self.mode == "durable" and result.mode ~= "durable")
        or (self.mode == "embedded" and result.mode ~= "embedded")
      then
        self:_protocol_fault(error_object("protocol", "broker protocol or lifecycle mode mismatch"))
        return
      end
      if result.protocol_revision ~= protocol_revision then
        self:_protocol_fault(error_object(
          "protocol",
          "broker executable does not match this Agent Manager checkout; "
            .. "reinstall its matching release artifact (or rebuild a development checkout) "
            .. "and restart Neovim"
        ))
        return
      end
      self.initialized = result
      local replay = result.replay or {}
      self.resync_required = replay.resync_required == true
      if self.resync_required then
        self.last_sequence = tonumber(replay.latest) or self.last_sequence
      end
      self:notify("initialized", {})
      self.reconnect_attempt = 0
      self.reconnect_delay = nil
      self:_set_state("connected")
      if self.resync_required then
        pcall(self.on_resync, {
          oldest = replay.oldest,
          latest = replay.latest,
        })
      end
      self:_finish_ready(nil)
    end
  )
  if err then
    if self.mode == "durable" then
      self:_connection_lost(err)
    else
      self:_protocol_fault(err)
    end
  end
end

function Client:_transport_open()
  if self.mode == "durable" then
    return self.pipe ~= nil
  end
  return self.job_id ~= nil
end

function Client:_write(encoded)
  if self.mode == "durable" then
    local pipe = self.pipe
    if not pipe then
      return nil, error_object("disconnected", "durable broker is not connected")
    end
    local generation = self.generation
    local ok = pcall(pipe.write, pipe, encoded .. "\n", function(write_err)
      if write_err then
        vim.schedule(function()
          if self.generation == generation and self.pipe == pipe then
            self:_connection_lost(error_object("socket", "durable broker socket write failed"))
          end
        end)
      end
    end)
    if not ok then
      return nil, error_object("disconnected", "could not write to the durable broker")
    end
    return true
  end
  local sent, send_result = pcall(vim.fn.chansend, self.job_id, encoded .. "\n")
  if not sent or send_result == 0 then
    return nil, error_object("disconnected", "could not write to the broker")
  end
  return true
end

function Client:request(method, params, callback)
  if not self:_transport_open() then
    return nil, error_object("disconnected", "broker is not running")
  end
  local id = self.next_id
  self.next_id = self.next_id + 1
  self.pending[id] = callback or function() end
  local ok, encoded = pcall(vim.json.encode, {
    jsonrpc = "2.0",
    id = id,
    method = method,
    params = object_params(params),
  })
  if not ok then
    self.pending[id] = nil
    return nil, error_object("encoding", "could not encode broker request")
  end
  local written, err = self:_write(encoded)
  if not written then
    self.pending[id] = nil
    return nil, err
  end
  return id
end

function Client:notify(method, params)
  if not self:_transport_open() then
    return nil, error_object("disconnected", "broker is not running")
  end
  local ok, encoded = pcall(vim.json.encode, {
    jsonrpc = "2.0",
    method = method,
    params = object_params(params),
  })
  if not ok then
    return nil, error_object("encoding", "could not encode broker notification")
  end
  return self:_write(encoded)
end

function Client:_on_stdout(data)
  if not data or #data == 0 then
    return
  end
  data[1] = self.stdout_partial .. data[1]
  self.stdout_partial = table.remove(data) or ""
  for _, line in ipairs(data) do
    self:_decode_line(line)
  end
end

function Client:_on_bytes(data)
  self.stdout_partial = self.stdout_partial .. data
  while true do
    local newline = self.stdout_partial:find("\n", 1, true)
    if not newline then
      return
    end
    local line = self.stdout_partial:sub(1, newline - 1):gsub("\r$", "")
    self.stdout_partial = self.stdout_partial:sub(newline + 1)
    self:_decode_line(line)
  end
end

function Client:_decode_line(line)
  if line == "" then
    return
  end
  local ok, message = pcall(vim.json.decode, line)
  if not ok or type(message) ~= "table" then
    self:_protocol_fault(error_object("protocol", "broker emitted malformed JSON"))
    return
  end
  self:_handle_message(message)
end

function Client:_handle_message(message)
  if message.jsonrpc ~= "2.0" then
    self:_protocol_fault(error_object("protocol", "broker emitted an invalid JSON-RPC frame"))
    return
  end
  if message.method then
    if message.method == "agent/event" then
      local sequence = tonumber(message.params and message.params.sequence)
      if sequence and sequence > self.last_sequence then
        self.last_sequence = sequence
      end
    end
    pcall(self.on_notification, message.method, message.params or {})
    return
  end
  local callback = self.pending[message.id]
  if not callback then
    return
  end
  self.pending[message.id] = nil
  if message.error then
    pcall(
      callback,
      nil,
      error_object("rpc", message.error.message or "broker request failed", message.error.code)
    )
  else
    pcall(callback, message.result, nil)
  end
end

function Client:_fail_pending(err)
  local pending = self.pending
  self.pending = {}
  for _, callback in pairs(pending) do
    pcall(callback, nil, err or error_object("disconnected", "broker disconnected"))
  end
end

function Client:_close_pipe()
  local pipe = self.pipe
  self.pipe = nil
  if pipe then
    pcall(pipe.read_stop, pipe)
    close_handle(pipe)
  end
end

function Client:_protocol_fault(err)
  self.last_error = err
  self.stopping = true
  if self.mode == "durable" then
    self:_close_pipe()
  elseif self.job_id then
    pcall(vim.fn.jobstop, self.job_id)
    self.job_id = nil
  end
  self:_fail_pending(err)
  self:_set_state("failed", err)
  self:_finish_ready(err)
end

function Client:_connection_lost(err)
  if self.stopping then
    return
  end
  self:_close_pipe()
  self:_fail_pending(err)
  self:_set_state("disconnected", err)
  self:_schedule_reconnect(err)
end

function Client:_schedule_reconnect(err)
  if self.mode ~= "durable" or self.stopping or self.reconnect_timer then
    return
  end
  self.reconnect_attempt = self.reconnect_attempt + 1
  if self.reconnect_attempt > self.reconnect.max_attempts then
    self:_set_state("failed", err)
    self:_finish_ready(err)
    return
  end
  local exponent = math.min(self.reconnect_attempt - 1, 20)
  local delay = math.min(
    self.reconnect.max_delay,
    self.reconnect.initial_delay * (2 ^ exponent)
  )
  local jitter = math.floor(delay * self.reconnect.jitter)
  if jitter > 0 then
    local seed = tonumber(vim.uv.hrtime() % (jitter * 2 + 1)) or 0
    delay = math.max(0, delay - jitter + seed)
  end
  self.reconnect_delay = delay
  self:_set_state("reconnecting", err)
  self.reconnect_timer = vim.defer_fn(function()
    self.reconnect_timer = nil
    if not self.stopping and self.state == "reconnecting" then
      self:_open_transport(true)
    end
  end, delay)
end

function Client:_on_exit(code)
  if not self.job_id and self.state == "failed" then
    return
  end
  self.job_id = nil
  if self.stopping then
    self:_fail_pending(error_object("stopped", "broker stopped"))
    self:_set_state("stopped")
    self:_finish_ready(error_object("stopped", "broker stopped"))
    return
  end
  local err = error_object("broker_exit", "broker exited unexpectedly", code)
  self:_fail_pending(err)
  self:_set_state("disconnected", err)
  self:_finish_ready(err)
end

function Client:stop()
  self.stopping = true
  if self.reconnect_timer then
    pcall(self.reconnect_timer.stop, self.reconnect_timer)
    close_handle(self.reconnect_timer)
    self.reconnect_timer = nil
  end
  if self.mode == "durable" then
    self.generation = self.generation + 1
    self:_close_pipe()
    self:_fail_pending(error_object("stopped", "durable broker client stopped"))
    self:_set_state("stopped")
    self:_finish_ready(error_object("stopped", "durable broker client stopped"))
    return true
  end
  if not self.job_id then
    self:_set_state("stopped")
    return true
  end
  if self.state == "connected" then
    local job_id = self.job_id
    self:request("broker/shutdown", {}, function()
      pcall(vim.fn.chanclose, job_id, "stdin")
      vim.defer_fn(function()
        if self.job_id == job_id then
          pcall(vim.fn.jobstop, job_id)
        end
      end, 6000)
    end)
  else
    pcall(vim.fn.jobstop, self.job_id)
  end
  return true
end

function Client:status()
  return {
    state = self.state,
    mode = self.mode,
    command = self:_argv(),
    socket = self.socket,
    initialized = vim.deepcopy(self.initialized),
    last_error = vim.deepcopy(self.last_error),
    last_sequence = self.last_sequence,
    resync_required = self.resync_required,
    reconnect_attempt = self.reconnect_attempt,
    reconnect_delay = self.reconnect_delay,
  }
end

return Client
