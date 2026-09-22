local View = {}
View.__index = View

local pane_names = { "agents", "conversation", "activity" }

local function valid_buffer(buffer)
  return buffer ~= nil and vim.api.nvim_buf_is_valid(buffer)
end

local function valid_window(window)
  return window ~= nil and vim.api.nvim_win_is_valid(window)
end

local function valid_tab(tab)
  return tab ~= nil and vim.api.nvim_tabpage_is_valid(tab)
end

local function inline(value)
  value = tostring(value or "")
  return value:gsub("%z", "�"):gsub("[\r\n]", " ")
end

local function add_phrase_highlight(highlights, line_number, line, phrase, group)
  local start = line:find(phrase, 1, true)
  if start then
    table.insert(highlights, {
      line = line_number,
      group = group,
      start = start - 1,
      finish = start - 1 + #phrase,
    })
  end
end

local function text_lines(value)
  value = tostring(value or ""):gsub("%z", "�"):gsub("\r", "")
  return vim.split(value, "\n", { plain = true })
end

local function action_has_choice(action, choice)
  for _, candidate in ipairs(action and action.payload.choices or {}) do
    if candidate == choice then
      return true
    end
  end
  return false
end

local function session_is_active(session)
  if session.external_active == true then
    return true
  end
  if session.external then
    return session.active == true
  end
  return session.state ~= "disconnected" and session.state ~= "failed"
end

local function broker_session_is_active(session)
  return session.managed
    and session.external_active ~= true
    and session.state ~= "disconnected"
    and session.state ~= "failed"
end

local function session_badge(session)
  if session_is_active(session) then
    return "●", "AgentManagerStatusSuccess"
  end
  if not broker_session_is_active(session) and session.activity_known == false then
    return "?", "AgentManagerStatusWaiting"
  end
  if type(session.provider_session_id) == "string" and session.provider_session_id ~= "" then
    return "○", "AgentManagerInput"
  end
  return "×", "AgentManagerMuted"
end

local function usage_lines(value, prefix, lines, depth)
  if depth > 4 or #lines >= 16 then
    return
  end
  if type(value) ~= "table" then
    table.insert(lines, string.format(" %s: %s", prefix, inline(value)))
    return
  end
  local keys = vim.tbl_keys(value)
  table.sort(keys, function(left, right)
    return tostring(left) < tostring(right)
  end)
  for _, key in ipairs(keys) do
    local next_prefix = prefix == "" and tostring(key) or (prefix .. "." .. tostring(key))
    usage_lines(value[key], next_prefix, lines, depth + 1)
    if #lines >= 16 then
      break
    end
  end
end

local function sorted_keys(values)
  local keys = vim.tbl_keys(values)
  table.sort(keys, function(left, right)
    return tostring(left) < tostring(right)
  end)
  return keys
end

local function normalized_path(path)
  path = tostring(path or ""):gsub("\\", "/")
  if path == "/" or path:match("^[A-Za-z]:/$") then
    return path
  end
  path = path:gsub("/+$", "")
  return path ~= "" and path or "/"
end

local function absolute_path(path)
  return path:sub(1, 1) == "/" or path:match("^[A-Za-z]:/") ~= nil
end

local function join_path(parent, child)
  if parent == "/" then
    return "/" .. child
  end
  return tostring(parent):gsub("/+$", "") .. "/" .. child
end

local function session_path(path, home)
  local normalized_home = normalized_path(home)
  local normalized = tostring(path or ""):gsub("\\", "/")
  if normalized == "" or normalized == "." or normalized == "~" then
    return normalized_home
  end
  if normalized:sub(1, 2) == "~/" then
    return normalized_path(join_path(normalized_home, normalized:sub(3)))
  end
  if not absolute_path(normalized) then
    return normalized_path(join_path(normalized_home, normalized))
  end
  return normalized_path(normalized)
end

local function path_within(path, root)
  path = normalized_path(path)
  root = normalized_path(root)
  return root == "/" or path == root or path:sub(1, #root + 1) == root .. "/"
end

local function relative_parts(path, root)
  if not path_within(path, root) then
    return nil
  end
  local remainder = normalized_path(path):sub(#normalized_path(root) + 1):gsub("^/+", "")
  local parts = {}
  for part in remainder:gmatch("[^/]+") do
    table.insert(parts, part)
  end
  return parts
end

local function directory_parts(path, home)
  local normalized = session_path(path, home)
  local normalized_home = normalized_path(home)
  local root = "/"
  local remainder = normalized:gsub("^/+", "")
  if normalized_home ~= "" and (normalized == normalized_home or normalized:sub(1, #normalized_home + 1) == normalized_home .. "/") then
    root = normalized_home .. (normalized_home == "/" and "" or "/")
    remainder = normalized:sub(#normalized_home + 1):gsub("^/+", "")
  else
    local drive, rest = normalized:match("^([A-Za-z]:)/?(.*)$")
    if drive then
      root = drive
      remainder = rest
    end
  end
  local parts = {}
  for part in remainder:gmatch("[^/]+") do
    table.insert(parts, part)
  end
  local root_path = root
  if root == normalized_home .. (normalized_home == "/" and "" or "/") then
    root_path = normalized_home
  end
  return root, root_path, parts
end

local function tree_node(roots, path, home)
  local root_name, root_path, parts = directory_parts(path, home)
  roots[root_name] = roots[root_name]
    or { path = root_path, directories = {}, sessions = {} }
  local node = roots[root_name]
  for _, part in ipairs(parts) do
    node.directories[part] = node.directories[part]
      or {
        path = join_path(node.path, part),
        directories = {},
        sessions = {},
      }
    node = node.directories[part]
  end
  return node
end

local function overlay_node(path)
  return { path = path, directories = {}, sessions = {} }
end

local function overlay_path(root, path, home)
  local normalized = session_path(path, home)
  local parts = relative_parts(normalized, home)
  if not parts then
    return nil, normalized
  end
  local node = root
  for _, part in ipairs(parts) do
    node.directories[part] = node.directories[part] or overlay_node(join_path(node.path, part))
    node = node.directories[part]
  end
  return node, normalized
end

local function session_tree(sessions, repositories, directory_hints, home)
  local root = overlay_node(home)
  local outside = {}
  for _, session in ipairs(sessions) do
    local node, path = overlay_path(root, session.cwd, home)
    if not node then
      node = tree_node(outside, path, home)
    end
    table.insert(node.sessions, session)
    if session.managed_workspace and session.managed_workspace ~= vim.NIL then
      node.repository = session.managed_workspace.repository
    end
  end
  for _, repository in ipairs(repositories or {}) do
    local node, path = overlay_path(root, repository.canonical_path, home)
    if not node then
      node = tree_node(outside, path, home)
    end
    node.repository = repository.slug
  end
  for path in pairs(directory_hints or {}) do
    local node, normalized = overlay_path(root, path, home)
    if not node then
      node = tree_node(outside, normalized, home)
    end
    node.directory_hint = true
  end
  return root, outside
end

local function timestamp_epoch(value)
  if type(value) == "number" then
    while value > 100000000000 do
      value = value / 1000
    end
    return value
  end
  if type(value) ~= "string" or value == "" then
    return nil
  end
  local numeric = tonumber(value)
  if numeric then
    return timestamp_epoch(numeric)
  end
  local normalized = value
    :gsub("%.%d+([+-])", "%1")
    :gsub("%.%d+Z$", "Z")
    :gsub("Z$", "+0000")
    :gsub("([+-]%d%d):(%d%d)$", "%1%2")
  local ok, epoch = pcall(vim.fn.strptime, "%Y-%m-%dT%H:%M:%S%z", normalized)
  return ok and epoch ~= 0 and epoch or nil
end

local function sorted_sessions(node)
  local sessions = vim.deepcopy(node.sessions or {})
  table.sort(sessions, function(left, right)
    local left_epoch = timestamp_epoch(left.updated_at)
    local right_epoch = timestamp_epoch(right.updated_at)
    if left_epoch ~= right_epoch then
      if left_epoch == nil or right_epoch == nil then
        return left_epoch ~= nil
      end
      return left_epoch > right_epoch
    end
    local left_updated = tostring(left.updated_at == vim.NIL and "" or left.updated_at or "")
    local right_updated = tostring(right.updated_at == vim.NIL and "" or right.updated_at or "")
    if left_updated ~= right_updated then
      return left_updated > right_updated
    end
    if left.title ~= right.title then
      return tostring(left.title) < tostring(right.title)
    end
    if left.provider ~= right.provider then
      return tostring(left.provider) < tostring(right.provider)
    end
    return tostring(left.key) < tostring(right.key)
  end)
  return sessions
end

local function annotate_session_counts(node)
  local count = #(node.sessions or {})
  for _, child in pairs(node.directories or {}) do
    count = count + annotate_session_counts(child)
  end
  node.session_count = count
  return count
end

local function sorted_directory_names(directories)
  local names = vim.tbl_keys(directories)
  table.sort(names, function(left, right)
    local left_count = directories[left].node.session_count or 0
    local right_count = directories[right].node.session_count or 0
    if (left_count > 0) ~= (right_count > 0) then
      return left_count > 0
    end
    local left_folded = left:lower()
    local right_folded = right:lower()
    return left_folded == right_folded and left < right or left_folded < right_folded
  end)
  return names
end

local function home_directory(path)
  local candidate = path
  if type(candidate) ~= "string" or candidate == "" then
    candidate = vim.uv.os_homedir() or vim.env.HOME or vim.uv.cwd()
  end
  candidate = normalized_path(candidate)
  local resolved = vim.uv.fs_realpath(candidate)
  return normalized_path(resolved or candidate)
end

local function set_window_options(window, wrap, pane)
  vim.wo[window].number = false
  vim.wo[window].relativenumber = false
  vim.wo[window].signcolumn = "no"
  vim.wo[window].foldcolumn = "0"
  vim.wo[window].list = false
  vim.wo[window].wrap = wrap
  vim.wo[window].linebreak = wrap
  vim.wo[window].breakindent = wrap
  vim.wo[window].cursorline = true
  vim.w[window].agent_manager = {
    plugin_id = "agent.manager",
    pane = pane,
  }
end

function View.layout_for(columns)
  if columns >= 140 then
    return { mode = "wide", visible = { "agents", "conversation", "activity" } }
  end
  if columns >= 90 then
    return { mode = "medium", visible = { "agents", "conversation" } }
  end
  return { mode = "narrow", visible = { "conversation" } }
end

function View.new(model, actions, opts)
  opts = opts or {}
  local home = home_directory(opts.home)
  local self = setmetatable({
    model = model,
    actions = actions or {},
    opts = opts,
    home = home,
    buffers = {},
    windows = {},
    tab = nil,
    mode = nil,
    active_pane = "agents",
    pane_index = 1,
    agent_rows = {},
    session_rows = {},
    session_group_rows = {},
    session_group_path_rows = {},
    directory_rows = {},
    directory_path_rows = {},
    file_rows = {},
    directory_hints = {},
    expanded_directories = { [home] = true },
    expanded_session_groups = {},
    directory_cache = {},
    namespace = vim.api.nvim_create_namespace("AgentManagerView"),
    prompt_namespace = vim.api.nvim_create_namespace("AgentManagerPrompt"),
    render_pending = false,
    prompt_submitting = false,
    last_action_id = nil,
  }, View)
  self:_create_autocmds()
  return self
end

function View:add_directory_hint(path)
  if type(path) ~= "string" or path == "" then
    return false
  end
  path = session_path(path, self.home)
  self.directory_hints[path] = true
  self:schedule_render()
  return true
end

function View:_directory_listing(path)
  local cached = self.directory_cache[path]
  if cached then
    return cached.entries, cached.error
  end
  local entries = {}
  local ok, err = pcall(function()
    for name, entry_type in vim.fs.dir(path) do
      if name ~= "." and name ~= ".." then
        table.insert(entries, {
          name = name,
          path = join_path(path, name),
          type = entry_type or "file",
        })
      end
    end
  end)
  table.sort(entries, function(left, right)
    local left_directory = left.type == "directory"
    local right_directory = right.type == "directory"
    if left_directory ~= right_directory then
      return left_directory
    end
    local left_name = left.name:lower()
    local right_name = right.name:lower()
    return left_name == right_name and left.name < right.name or left_name < right_name
  end)
  cached = {
    entries = entries,
    error = ok and nil or tostring(err),
  }
  self.directory_cache[path] = cached
  return cached.entries, cached.error
end

function View:refresh_filesystem()
  self.directory_cache = {}
  self:schedule_render()
end

function View:_create_autocmds()
  self.augroup = vim.api.nvim_create_augroup("AgentManagerView", { clear = true })
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = self.augroup,
    callback = function()
      self:schedule_render()
    end,
  })
  vim.api.nvim_create_autocmd("VimResized", {
    group = self.augroup,
    callback = function()
      vim.schedule(function()
        if valid_tab(self.tab) and vim.api.nvim_get_current_tabpage() == self.tab then
          local next_mode = View.layout_for(vim.o.columns).mode
          if not self.expanded and next_mode ~= self.mode then
            local active_pane = self.active_pane
            self:_build_layout(active_pane)
            self:render()
          else
            self:_resize_prompt()
          end
        end
      end)
    end,
  })
end

function View:_buffer(name)
  if valid_buffer(self.buffers[name]) then
    return self.buffers[name]
  end
  local buffer = vim.api.nvim_create_buf(false, true)
  self.buffers[name] = buffer
  pcall(vim.api.nvim_buf_set_name, buffer, "agent-manager://" .. name)
  vim.bo[buffer].buftype = "nofile"
  vim.bo[buffer].bufhidden = "hide"
  vim.bo[buffer].swapfile = false
  vim.bo[buffer].undofile = false
  vim.bo[buffer].modeline = false
  vim.bo[buffer].modifiable = name == "prompt"
  vim.bo[buffer].filetype = "agent-manager-" .. name
  vim.b[buffer].agent_manager = {
    plugin_id = "agent.manager",
    pane = name,
  }
  if name == "prompt" then
    self:_map_prompt_buffer(buffer)
    vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
      group = self.augroup,
      buffer = buffer,
      callback = function()
        self:_render_prompt()
        self:_resize_prompt()
      end,
    })
  else
    self:_map_buffer(buffer)
  end
  return buffer
end

function View:_map_windows(buffer)
  local opts = { buffer = buffer, silent = true, nowait = true }
  vim.keymap.set("n", "we", function()
    self:toggle_expanded()
  end, vim.tbl_extend("force", opts, { desc = "Agent Manager: toggle expanded pane" }))
  for index, pane in ipairs(pane_names) do
    local target = pane
    vim.keymap.set("n", "w" .. index, function()
      self:focus(target)
    end, vim.tbl_extend("force", opts, { desc = "Agent Manager: focus " .. target }))
  end
end

function View:_map_prompt_buffer(buffer)
  self:_map_windows(buffer)
  for key, motion in pairs({ ["<Up>"] = "gk", ["<Down>"] = "gj" }) do
    vim.keymap.set("n", key, motion, { buffer = buffer, silent = true })
    vim.keymap.set("i", key, "<C-o>" .. motion, { buffer = buffer, silent = true })
  end
  local opts = function(description)
    return {
      buffer = buffer,
      silent = true,
      nowait = true,
      desc = "Agent Manager: " .. description,
    }
  end
  local submit = function()
    vim.schedule(function()
      self:_submit_prompt()
    end)
  end
  vim.keymap.set({ "n", "i" }, "<CR>", submit, opts("send prompt"))
  vim.keymap.set("n", "q", function()
    self:close()
  end, opts("close workspace"))
  vim.keymap.set("n", "<Tab>", function()
    self:cycle(1)
  end, opts("next pane"))
  vim.keymap.set("n", "<S-Tab>", function()
    self:cycle(-1)
  end, opts("previous pane"))
  for index, pane in ipairs(pane_names) do
    local target = pane
    vim.keymap.set("n", tostring(index), function()
      self:focus(target)
    end, opts("focus " .. target .. " pane"))
  end
end

function View:_map_buffer(buffer)
  for _, key in ipairs({ "gs", "gw" }) do
    vim.keymap.set("n", key, function()
      if self.actions.workflows then self.actions.workflows() end
    end, { buffer = buffer, silent = true, desc = "Show long-running workflows" })
  end
  self:_map_windows(buffer)
  local map_opts = function(description)
    return { buffer = buffer, silent = true, nowait = true, desc = description }
  end
  local map = function(keys, callback, description)
    vim.keymap.set("n", keys, callback, map_opts("Agent Manager: " .. description))
  end
  vim.keymap.set("n", "<Tab>", function()
    self:cycle(1)
  end, map_opts("Agent Manager: next pane"))
  vim.keymap.set("n", "<S-Tab>", function()
    self:cycle(-1)
  end, map_opts("Agent Manager: previous pane"))
  for index, pane in ipairs(pane_names) do
    local target = pane
    vim.keymap.set("n", tostring(index), function()
      self:focus(target)
    end, map_opts("Agent Manager: focus " .. target .. " pane"))
  end
  vim.keymap.set("n", "q", function()
    self:close()
  end, map_opts("Agent Manager: close workspace"))
  vim.keymap.set("n", "<CR>", function()
    self:_activate_row()
  end, map_opts("Agent Manager: select item"))
  map("y", function()
    local action = self:_focused_decision()
    if action and action.kind == "approval" and action_has_choice(action, "allow") and self.actions.allow then
      self.actions.allow(action)
    end
  end, "yes / allow focused approval")
  map("n", function()
    local action = self:_focused_decision()
    if action and action_has_choice(action, "deny") and self.actions.deny then
      self.actions.deny(action)
    end
  end, "no / deny focused request")

  map("sn", function()
    if self.actions.start then
      self.actions.start(self:_start_context())
    end
  end, "start new session")
  map("so", function()
    local session = self:_focused_session()
    if session and self.actions.attach then
      self.actions.attach(session)
    end
  end, "open or continue session")
  map("sf", function()
    local session = self:_focused_session()
    if session and self.actions.fork then
      self.actions.fork(session)
    end
  end, "fork session")
  map("sa", function()
    local session = self:_focused_session()
    if session and self.actions.archive then
      self.actions.archive(session)
    end
  end, "archive session")

  map("am", function()
    if self.actions.model then
      self.actions.model()
    end
  end, "change model")
  map("ae", function()
    if self.actions.effort then
      self.actions.effort()
    end
  end, "change effort")

  map("tp", function()
    if self.actions.prompt then
      self.actions.prompt()
    end
  end, "prompt selected agent")
  map("ts", function()
    if self.actions.steer then
      self.actions.steer()
    end
  end, "steer active turn")
  map("ti", function()
    if self.actions.interrupt then
      self.actions.interrupt()
    end
  end, "interrupt active turn")
  map("tc", function()
    if self.actions.context then
      self.actions.context()
    end
  end, "add editor context")

  map("df", function()
    if self.actions.diff then
      self.actions.diff(self:_focused_target())
    end
  end, "show file diff")
  map("ds", function()
    local session = self:_focused_session()
    if session and self.actions.delete_session then
      self.actions.delete_session(session)
    end
  end, "delete session")

  map("ga", function()
    self:focus("agents")
  end, "go to agents")
  map("gc", function()
    self:focus("conversation")
  end, "go to conversation")
  map("gt", function()
    self:focus("activity")
  end, "go to activity")
  map("gr", function()
    self:refresh_filesystem()
    if self.actions.refresh then
      self.actions.refresh()
    end
  end, "refresh tree and sessions")
  map("g?", function()
    self:show_help()
  end, "show help")

  map("h", function()
    self:_collapse_row()
  end, "collapse directory")
  map("l", function()
    self:_expand_row()
  end, "expand or open item")
  map("?", function()
    self:show_help()
  end, "show help")

  local ok, which_key = pcall(require, "which-key")
  if ok and type(which_key.add) == "function" then
    which_key.add({
      { "a", group = "agent settings", buffer = buffer },
      { "d", group = "diff / delete", buffer = buffer },
      { "g", group = "go", buffer = buffer },
      { "s", group = "session", buffer = buffer },
      { "t", group = "turn", buffer = buffer },
    })
  end
end

function View:set_draft(draft)
  self.draft = draft and vim.deepcopy(draft) or nil
  self:schedule_render()
end

function View:open()
  if valid_tab(self.tab) then
    vim.api.nvim_set_current_tabpage(self.tab)
    self:render()
    return true
  end
  for _, name in ipairs(pane_names) do
    self:_buffer(name)
  end
  self:_buffer("prompt")
  vim.cmd("tabnew")
  self.tab = vim.api.nvim_get_current_tabpage()
  self:_build_layout("agents")
  self:render()
  return true
end

function View:_build_layout(initial_pane)
  if self.workspace_mode == "workflows" and self.workflows then
    self.workflows:layout()
    return
  end
  if not valid_tab(self.tab) or vim.api.nvim_get_current_tabpage() ~= self.tab then
    return
  end
  local tab_windows = vim.api.nvim_tabpage_list_wins(self.tab)
  local main = tab_windows[1]
  if not valid_window(main) then
    return
  end
  vim.api.nvim_set_current_win(main)
  for index = 2, #tab_windows do
    if valid_window(tab_windows[index]) then
      pcall(vim.api.nvim_win_close, tab_windows[index], true)
    end
  end
  vim.wo[main].winfixwidth = false
  vim.wo[main].winfixheight = false
  self.windows = { conversation = main }
  vim.api.nvim_win_set_buf(main, self:_buffer("conversation"))
  set_window_options(main, true, "conversation")
  local layout = self.expanded and { mode = "expanded" } or View.layout_for(vim.o.columns)
  if self.expanded and initial_pane ~= "conversation" then
    self.windows = { [initial_pane] = main }
    vim.api.nvim_win_set_buf(main, self:_buffer(initial_pane))
    set_window_options(main, initial_pane ~= "agents", initial_pane)
    self.mode = "expanded"
    self:focus(initial_pane)
    return
  end
  self.mode = layout.mode

  if layout.mode == "wide" or layout.mode == "medium" then
    vim.api.nvim_set_current_win(main)
    vim.cmd("topleft vertical split")
    local agents = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(agents, self:_buffer("agents"))
    vim.api.nvim_win_set_width(agents, self.opts.agent_width or 28)
    vim.wo[agents].winfixwidth = true
    set_window_options(agents, false, "agents")
    self.windows.agents = agents
  end
  if layout.mode == "wide" then
    vim.api.nvim_set_current_win(main)
    vim.cmd("botright vertical split")
    local activity = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(activity, self:_buffer("activity"))
    vim.api.nvim_win_set_width(activity, self.opts.activity_width or 38)
    vim.wo[activity].winfixwidth = true
    set_window_options(activity, true, "activity")
    self.windows.activity = activity
  end

  vim.api.nvim_set_current_win(main)
  vim.cmd("belowright split")
  local prompt = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(prompt, self:_buffer("prompt"))
  vim.wo[prompt].winfixheight = true
  set_window_options(prompt, true, "prompt")
  vim.wo[prompt].cursorline = false
  self.windows.prompt = prompt
  self:_resize_prompt()

  initial_pane = vim.tbl_contains(pane_names, initial_pane) and initial_pane or "agents"
  if not self:focus(initial_pane) then
    self:focus("conversation")
  end
end

function View:toggle_expanded()
  if not valid_tab(self.tab) or vim.api.nvim_get_current_tabpage() ~= self.tab then
    return false
  end
  local pane = pane_names[self.pane_index]
  local metadata = vim.b[vim.api.nvim_get_current_buf()].agent_manager
  if metadata then
    local name = metadata.pane
    if vim.tbl_contains(pane_names, name) then
      pane = name
    elseif name == "prompt" or name == "decision" then
      pane = "conversation"
    end
  end
  if self.expanded then
    local saved = self.expanded
    self.expanded = nil
    self:_build_layout(pane)
    vim.cmd("stopinsert")
    self:render()
    for _, name in ipairs({ "agents", "activity", "conversation", "prompt" }) do
      local state, window = saved[name], self.windows[name]
      if state and valid_window(window) then
        pcall(vim.api.nvim_win_set_width, window, state.width)
        pcall(vim.api.nvim_win_set_height, window, state.height)
        vim.api.nvim_win_call(window, function()
          vim.fn.winrestview(state.view)
        end)
      end
    end
  else
    self.expanded = {}
    for name, window in pairs(self.windows) do
      if valid_window(window) then
        self.expanded[name] = {
          width = vim.api.nvim_win_get_width(window),
          height = vim.api.nvim_win_get_height(window),
          view = vim.api.nvim_win_call(window, vim.fn.winsaveview),
        }
      end
    end
    self:_build_layout(pane)
    self:render()
  end
  return true
end

function View:cycle(direction)
  if not valid_tab(self.tab) then
    return false
  end
  local index = ((self.pane_index - 1 + direction) % #pane_names) + 1
  return self:focus(pane_names[index])
end

function View:focus(pane)
  local index = type(pane) == "number" and pane or nil
  if not index then
    for candidate, name in ipairs(pane_names) do
      if name == pane then
        index = candidate
        break
      end
    end
  end
  if not index or not valid_tab(self.tab) then
    return false
  end
  pane = pane_names[index]
  if not pane then
    return false
  end
  if self.expanded and not valid_window(self.windows[pane]) then
    self:_build_layout(pane)
    return true
  end
  self.pane_index = index
  self.active_pane = pane
  if pane == "conversation" then
    local content = self.windows.conversation
    if valid_window(content) then
      vim.api.nvim_win_set_buf(content, self:_buffer("conversation"))
      set_window_options(content, true, "conversation")
    end
    return self:focus_prompt()
  end
  local window = self.windows[pane]
  if valid_window(window) then
    vim.api.nvim_win_set_buf(window, self:_buffer(pane))
    set_window_options(window, pane ~= "agents", pane)
    vim.api.nvim_set_current_win(window)
    return true
  end
  local content = self.windows.conversation
  if not valid_window(content) then
    content = vim.api.nvim_tabpage_list_wins(self.tab)[1]
  end
  if valid_window(content) then
    vim.api.nvim_win_set_buf(content, self:_buffer(pane))
    self.windows.conversation = content
    vim.api.nvim_set_current_win(content)
    set_window_options(content, pane ~= "agents", pane)
    return true
  end
  return false
end

function View:focus_prompt()
  if not valid_tab(self.tab) then
    return false
  end
  if self.expanded and not valid_window(self.windows.prompt) then
    return self:focus("conversation")
  end
  local prompt = self.windows.prompt
  if not valid_window(prompt) then
    return false
  end
  if vim.api.nvim_get_current_tabpage() ~= self.tab then
    vim.api.nvim_set_current_tabpage(self.tab)
  end
  vim.api.nvim_win_set_buf(prompt, self:_buffer("prompt"))
  set_window_options(prompt, true, "prompt")
  vim.wo[prompt].cursorline = false
  vim.api.nvim_set_current_win(prompt)
  local lines = vim.api.nvim_buf_get_lines(self.buffers.prompt, 0, -1, false)
  local last_line = math.max(1, #lines)
  local last_column = #(lines[last_line] or "")
  vim.api.nvim_win_set_cursor(prompt, { last_line, last_column })
  self.active_pane = "conversation"
  self.pane_index = 2
  if not self.expanded then
    vim.cmd("startinsert")
  end
  return true
end

function View:_prompt_height()
  local prompt = self.buffers.prompt
  local window = self.windows.prompt
  local minimum = math.max(1, tonumber(self.opts.prompt_min_height) or 3)
  local maximum = math.max(minimum, tonumber(self.opts.prompt_max_height) or 12)
  if not valid_buffer(prompt) or not valid_window(window) then
    return minimum
  end
  local width = math.max(1, vim.api.nvim_win_get_width(window) - 1)
  local height = 0
  for _, line in ipairs(vim.api.nvim_buf_get_lines(prompt, 0, -1, false)) do
    local columns = vim.fn.strdisplaywidth(line)
    height = height + math.max(1, math.ceil(columns / width))
  end
  return math.max(minimum, math.min(maximum, height))
end

function View:_resize_prompt()
  local window = self.windows.prompt
  if not valid_window(window) then
    return false
  end
  pcall(vim.api.nvim_win_set_height, window, self:_prompt_height())
  return true
end

function View:_render_prompt()
  local buffer = self.buffers.prompt
  if not valid_buffer(buffer) then
    return
  end
  vim.api.nvim_buf_clear_namespace(buffer, self.prompt_namespace, 0, -1)
  local lines = vim.api.nvim_buf_get_lines(buffer, 0, -1, false)
  local empty = #lines == 0 or (#lines == 1 and lines[1] == "")
  if empty then
    local hint = (self.draft or self.model:selected_agent()) and "Type a prompt…"
      or "Start or select a session in pane 1"
    pcall(vim.api.nvim_buf_set_extmark, buffer, self.prompt_namespace, 0, 0, {
      virt_text = { { hint, "AgentManagerMuted" } },
      virt_text_pos = "overlay",
      hl_mode = "combine",
    })
  end
end

function View:_clear_prompt()
  local buffer = self.buffers.prompt
  if not valid_buffer(buffer) then
    return
  end
  vim.bo[buffer].modifiable = true
  vim.api.nvim_buf_set_lines(buffer, 0, -1, false, { "" })
  vim.bo[buffer].modified = false
  self:_render_prompt()
  self:_resize_prompt()
end

function View:_submit_prompt()
  local buffer = self.buffers.prompt
  if not valid_buffer(buffer) then
    return false
  end
  local text = table.concat(vim.api.nvim_buf_get_lines(buffer, 0, -1, false), "\n")
  if not text:find("%S") then
    return false
  end
  if not self.actions.prompt then
    return false
  end
  if self.prompt_submitting then
    return false
  end
  self.prompt_submitting = true
  local ok = self.actions.prompt(text, function(_, err)
    self.prompt_submitting = false
    if err or not valid_buffer(buffer) then
      return
    end
    local current = table.concat(vim.api.nvim_buf_get_lines(buffer, 0, -1, false), "\n")
    if current == text then
      self:_clear_prompt()
    end
  end)
  if not ok then
    self.prompt_submitting = false
  end
  return ok and true or false
end

function View:_start_context()
  if vim.api.nvim_get_current_buf() ~= self.buffers.agents then
    return nil
  end
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local directory = self.directory_rows[row] or self.session_group_rows[row]
  if directory then
    return vim.deepcopy(directory)
  end
  local session = self.session_rows[row]
  if session then
    return {
      cwd = session.cwd,
      provider = session.provider,
      repository = session.managed_workspace and session.managed_workspace ~= vim.NIL
          and session.managed_workspace.repository
        or nil,
    }
  end
  return nil
end

function View:_focused_session()
  if vim.api.nvim_get_current_buf() ~= self.buffers.agents then
    return nil
  end
  local row = vim.api.nvim_win_get_cursor(0)[1]
  return vim.deepcopy(self.session_rows[row])
end

function View:_focused_target()
  if vim.api.nvim_get_current_buf() ~= self.buffers.agents then
    return nil
  end
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local target = self.session_rows[row] or self.directory_rows[row] or self.session_group_rows[row]
  if not target and self.file_rows[row] then
    target = { cwd = vim.fs.dirname(self.file_rows[row].path) }
  end
  return vim.deepcopy(target)
end

function View:_toggle_directory(directory, expanded)
  if not directory or type(directory.cwd) ~= "string" then
    return false
  end
  if expanded == nil then
    expanded = not self.expanded_directories[directory.cwd]
  end
  self.expanded_directories[directory.cwd] = expanded or nil
  self:schedule_render()
  return true
end

function View:_toggle_session_group(group, expanded)
  if not group or type(group.cwd) ~= "string" then
    return false
  end
  if expanded == nil then
    expanded = self.expanded_session_groups[group.cwd] == false
  end
  self.expanded_session_groups[group.cwd] = expanded
  self:schedule_render()
  return true
end

function View:_expand_row()
  if vim.api.nvim_get_current_buf() ~= self.buffers.agents then
    return false
  end
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local group = self.session_group_rows[row]
  if group then
    return self:_toggle_session_group(group, true)
  end
  local directory = self.directory_rows[row]
  if directory then
    return self:_toggle_directory(directory, true)
  end
  return self:_activate_row()
end

function View:_collapse_row()
  if vim.api.nvim_get_current_buf() ~= self.buffers.agents then
    return false
  end
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local group = self.session_group_rows[row]
  if group and self.expanded_session_groups[group.cwd] ~= false then
    return self:_toggle_session_group(group, false)
  end
  local directory = self.directory_rows[row]
  if directory and self.expanded_directories[directory.cwd] then
    return self:_toggle_directory(directory, false)
  end
  local session = self.session_rows[row]
  if group or session then
    local group_path = group and group.cwd or session.cwd
    local group_row = self.session_group_path_rows[group_path]
    if group_row and group_row ~= row then
      vim.api.nvim_win_set_cursor(0, { group_row, 0 })
      return true
    end
    local directory_row = self.directory_path_rows[group_path]
    if directory_row then
      vim.api.nvim_win_set_cursor(0, { directory_row, 0 })
      return true
    end
  end
  local target_path = directory and directory.cwd
  if not target_path then
    local file = self.file_rows[row]
    target_path = session and session.cwd or file and vim.fs.dirname(file.path)
  end
  if not target_path then
    return false
  end
  local parent = normalized_path(vim.fs.dirname(target_path))
  while parent and path_within(parent, self.home) do
    local parent_row = self.directory_path_rows[parent]
    if parent_row then
      vim.api.nvim_win_set_cursor(0, { parent_row, 0 })
      return true
    end
    if parent == self.home or parent == "/" then
      break
    end
    parent = normalized_path(vim.fs.dirname(parent))
  end
  return false
end

function View:_open_file(file)
  if not file or type(file.path) ~= "string" then
    return false
  end
  local window = self.windows.conversation
  if not valid_window(window) then
    return false
  end
  vim.api.nvim_set_current_win(window)
  vim.cmd("edit " .. vim.fn.fnameescape(file.path))
  return true
end

function View:_activate_row()
  local buffer = vim.api.nvim_get_current_buf()
  if buffer == self.buffers.decision then
    local action = self:_focused_decision()
    if action and action.kind == "question" and self.actions.answer then
      self.actions.answer(action)
    end
    return
  end
  if buffer ~= self.buffers.agents then
    return
  end
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local group = self.session_group_rows[row]
  if group then
    self:_toggle_session_group(group)
    return
  end
  local directory = self.directory_rows[row]
  if directory then
    self:_toggle_directory(directory)
    return
  end
  local file = self.file_rows[row]
  if file then
    self:_open_file(file)
    return
  end
  local session = self.session_rows[row]
  if not session then
    return
  end
  if session.id and broker_session_is_active(session) then
    local selected = self.actions.select and self.actions.select(session)
      or self.model:select(session.id)
    if selected then
      self:render()
    end
  elseif self.actions.resume then
    self.actions.resume(vim.deepcopy(session))
  end
end

function View:_focused_decision()
  if vim.api.nvim_get_current_buf() ~= self.buffers.decision then
    return nil
  end
  return self.model:focused_action()
end

function View:schedule_render()
  if self.render_pending then
    return
  end
  self.render_pending = true
  vim.schedule(function()
    self.render_pending = false
    self:render()
  end)
end

function View:render()
  if not valid_tab(self.tab) then
    return
  end
  if self.workspace_mode == "workflows" and self.workflows then
    self.workflows:render()
    return
  end
  self:_render_agents()
  self:_render_conversation()
  self:_render_activity()
  self:_render_prompt()
  self:_resize_prompt()
  local action = self.model:focused_action()
  self:_render_decision(action)
  self:_sync_decision(action)
end

function View:_set_lines(name, lines, highlights)
  local buffer = self:_buffer(name)
  vim.bo[buffer].modifiable = true
  vim.api.nvim_buf_set_lines(buffer, 0, -1, false, lines)
  vim.bo[buffer].modifiable = false
  vim.bo[buffer].modified = false
  vim.api.nvim_buf_clear_namespace(buffer, self.namespace, 0, -1)
  for _, highlight in ipairs(highlights or {}) do
    pcall(
      vim.api.nvim_buf_add_highlight,
      buffer,
      self.namespace,
      highlight.group,
      highlight.line - 1,
      highlight.start or 0,
      highlight.finish or -1
    )
  end
end

function View:_render_agents()
  local sessions = self.model:session_list()
  local provider_legend = " key · ● Codex · ◆ Claude"
  local primary_state_legend = "       ● active · ○ resume"
  local secondary_state_legend = "       ? check · × ended"
  local lines = {
    " 1 AGENTS · BY DIRECTORY",
    string.format(" broker: %s · sessions: %d", inline(self.model.client_state), #sessions),
    provider_legend,
    primary_state_legend,
    secondary_state_legend,
    "",
  }
  local highlights = {
    { line = 1, group = "AgentManagerTitle" },
    { line = 2, group = "AgentManagerMuted" },
  }
  add_phrase_highlight(highlights, 3, provider_legend, "● Codex", "AgentManagerProviderCodex")
  add_phrase_highlight(highlights, 3, provider_legend, "◆ Claude", "AgentManagerProviderClaude")
  add_phrase_highlight(highlights, 4, primary_state_legend, "● active", "AgentManagerStatusSuccess")
  add_phrase_highlight(highlights, 4, primary_state_legend, "○ resume", "AgentManagerInput")
  add_phrase_highlight(highlights, 5, secondary_state_legend, "? check", "AgentManagerStatusWaiting")
  add_phrase_highlight(highlights, 5, secondary_state_legend, "× ended", "AgentManagerMuted")
  self.agent_rows = {}
  self.session_rows = {}
  self.session_group_rows = {}
  self.session_group_path_rows = {}
  self.directory_rows = {}
  self.directory_path_rows = {}
  self.file_rows = {}
  local repositories = self.model:workspace_list()

  local function directory_suffix(node, exists)
    if node.repository then
      return "  [repo]"
    end
    if node.directory_hint then
      return "  [cwd]"
    end
    return exists == false and "  [missing]" or ""
  end

  local function add_directory_row(node, exists)
    self.directory_rows[#lines] = {
      cwd = node.path,
      repository = node.repository,
      exists = exists ~= false,
    }
    self.directory_path_rows[node.path] = #lines
  end

  local function add_session_row(session, prefix, connector)
    session = vim.deepcopy(session)
    session.cwd = session_path(session.cwd, self.home)
    local selected = session.managed and session.id == self.model.selected_agent_id and ">" or " "
    local provider = session.provider == "claude" and "◆" or "●"
    local badge, badge_group = session_badge(session)
    local pending = session.managed and #self.model:pending(session.id) or 0
    local marker = pending > 0 and (" !" .. tostring(pending)) or ""
    local lead = string.format("%s%s%s ", prefix, connector, selected)
    table.insert(lines, string.format(
      "%s%s %s · %s%s",
      lead,
      provider,
      badge,
      inline(session.title),
      marker
    ))
    self.session_rows[#lines] = session
    table.insert(highlights, {
      line = #lines,
      group = session.provider == "claude" and "AgentManagerProviderClaude"
        or "AgentManagerProviderCodex",
      start = #lead,
      finish = #lead + #provider,
    })
    table.insert(highlights, {
      line = #lines,
      group = badge_group,
      start = #lead + #provider + 1,
      finish = #lead + #provider + 1 + #badge,
    })
    if session.managed then
      self.agent_rows[#lines] = session.id
    end
  end

  local function add_session_group(node, prefix, connector, continues)
    local sessions_in_group = sorted_sessions(node)
    if #sessions_in_group == 0 then
      return
    end
    local expanded = self.expanded_session_groups[node.path] ~= false
    local icon = expanded and "▾ " or "▸ "
    table.insert(
      lines,
      string.format("%s%s%sSessions (%d)", prefix, connector, icon, #sessions_in_group)
    )
    self.session_group_rows[#lines] = { cwd = node.path, repository = node.repository }
    self.session_group_path_rows[node.path] = #lines
    table.insert(highlights, { line = #lines, group = "AgentManagerTitle" })
    if not expanded then
      return
    end
    local child_prefix = prefix .. (continues and "│  " or "   ")
    for index, session in ipairs(sessions_in_group) do
      add_session_row(session, child_prefix, index == #sessions_in_group and "└─ " or "├─ ")
    end
  end

  local render_home_node
  render_home_node = function(node, prefix, exists, filesystem_expanded)
    local entries, read_error = {}, nil
    if filesystem_expanded and exists ~= false then
      entries, read_error = self:_directory_listing(node.path)
    end
    local directories = {}
    local files = {}
    for _, entry in ipairs(entries) do
      if entry.type == "directory" then
        directories[entry.name] = {
          name = entry.name,
          node = node.directories[entry.name] or overlay_node(entry.path),
          exists = true,
        }
      else
        table.insert(files, entry)
      end
    end
    if filesystem_expanded then
      for name, child in pairs(node.directories) do
        directories[name] = directories[name] or { name = name, node = child, exists = false }
      end
    end
    local items = {}
    if #(node.sessions or {}) > 0 then
      table.insert(items, { kind = "sessions" })
    end
    for _, name in ipairs(sorted_directory_names(directories)) do
      table.insert(items, vim.tbl_extend("force", { kind = "directory" }, directories[name]))
    end
    for _, file in ipairs(files) do
      table.insert(items, { kind = "file", file = file })
    end
    if read_error then
      table.insert(items, { kind = "error" })
    end

    for index, item in ipairs(items) do
      local last = index == #items
      local connector = last and "└─ " or "├─ "
      if item.kind == "sessions" then
        add_session_group(node, prefix, connector, not last)
      elseif item.kind == "directory" then
        local expanded = self.expanded_directories[item.node.path] == true
        local icon = expanded and "▾ " or "▸ "
        table.insert(
          lines,
          prefix
            .. connector
            .. icon
            .. inline(item.name)
            .. "/"
            .. directory_suffix(item.node, item.exists)
        )
        add_directory_row(item.node, item.exists)
        table.insert(highlights, {
          line = #lines,
          group = item.node.repository and "AgentManagerTitle" or "AgentManagerMuted",
        })
        render_home_node(
          item.node,
          prefix .. (last and "   " or "│  "),
          item.exists,
          expanded
        )
      elseif item.kind == "file" then
        local suffix = item.file.type == "link" and "@" or ""
        table.insert(lines, prefix .. connector .. "  " .. inline(item.file.name) .. suffix)
        self.file_rows[#lines] = vim.deepcopy(item.file)
        table.insert(highlights, { line = #lines, group = "AgentManagerMuted" })
      else
        table.insert(lines, prefix .. connector .. "  [directory unreadable]")
        table.insert(highlights, { line = #lines, group = "AgentManagerStatusFailure" })
      end
    end
  end

  local home_root, outside = session_tree(sessions, repositories, self.directory_hints, self.home)
  annotate_session_counts(home_root)
  for _, root in pairs(outside) do
    annotate_session_counts(root)
  end
  local home_label = self.home == "/" and "/" or self.home .. "/"
  local home_expanded = self.expanded_directories[self.home] == true
  table.insert(
    lines,
    " "
      .. (home_expanded and "▾ " or "▸ ")
      .. inline(home_label)
      .. directory_suffix(home_root, true)
  )
  add_directory_row(home_root, true)
  table.insert(highlights, { line = #lines, group = "AgentManagerTitle" })
  render_home_node(home_root, " ", true, home_expanded)

  local render_virtual_node
  render_virtual_node = function(node, prefix, filesystem_expanded)
    local directories = {}
    if filesystem_expanded then
      for name, child in pairs(node.directories) do
        directories[name] = { name = name, node = child }
      end
    end
    local items = {}
    if #(node.sessions or {}) > 0 then
      table.insert(items, { kind = "sessions" })
    end
    for _, name in ipairs(sorted_directory_names(directories)) do
      table.insert(items, { kind = "directory", name = name, node = directories[name].node })
    end
    for index, item in ipairs(items) do
      local last = index == #items
      local connector = last and "└─ " or "├─ "
      if item.kind == "sessions" then
        add_session_group(node, prefix, connector, not last)
      elseif item.kind == "directory" then
        local expanded = self.expanded_directories[item.node.path] == true
        table.insert(
          lines,
          prefix
            .. connector
            .. (expanded and "▾ " or "▸ ")
            .. inline(item.name)
            .. "/"
            .. directory_suffix(item.node, false)
        )
        add_directory_row(item.node, false)
        table.insert(highlights, { line = #lines, group = "AgentManagerMuted" })
        render_virtual_node(item.node, prefix .. (last and "   " or "│  "), expanded)
      end
    end
  end

  for _, root_name in ipairs(sorted_keys(outside)) do
    local root = outside[root_name]
    table.insert(lines, "")
    local expanded = self.expanded_directories[root.path] == true
    table.insert(
      lines,
      " " .. (expanded and "▾ " or "▸ ") .. inline(root_name) .. directory_suffix(root, false)
    )
    add_directory_row(root, false)
    table.insert(highlights, { line = #lines, group = "AgentManagerTitle" })
    render_virtual_node(root, " ", expanded)
  end

  table.insert(lines, "")
  table.insert(lines, " sn new · so open · am model · ae effort · df diff · ds delete · gr refresh")
  table.insert(highlights, { line = #lines, group = "AgentManagerMuted" })
  for _, provider in ipairs({ "codex", "claude" }) do
    local activity = self.model.external_activity[provider]
    if activity and (activity.error or not activity.available) then
      table.insert(lines, " ! " .. provider .. " CLI session discovery unavailable")
      table.insert(highlights, { line = #lines, group = "AgentManagerStatusFailure" })
    end
  end
  local selected = self.model:selected_agent()
  if selected then
    table.insert(lines, "")
    table.insert(lines, " WORKSPACE")
    table.insert(highlights, { line = #lines, group = "AgentManagerTitle" })
    table.insert(lines, " " .. inline(selected.cwd))
    table.insert(lines, " " .. inline(selected.workspace_strategy))
    if selected.managed_workspace and selected.managed_workspace ~= vim.NIL then
      table.insert(
        lines,
        " "
          .. inline(selected.managed_workspace.repository)
          .. "/"
          .. inline(selected.managed_workspace.task_id)
      )
      table.insert(
        lines,
        " "
          .. inline(selected.managed_workspace.branch)
          .. " ← "
          .. inline(selected.managed_workspace.base_branch)
      )
    end
    if selected.runtime and selected.runtime ~= vim.NIL then
      table.insert(
        lines,
        " runtime "
          .. inline(selected.runtime.provider_version)
          .. " · "
          .. inline(selected.runtime.compatibility_profile)
      )
    end
    local conflicts = self.model:file_conflict_list(selected.id)
    if #conflicts > 0 then
      table.insert(lines, " ! " .. tostring(#conflicts) .. " dirty buffer conflict(s)")
      table.insert(highlights, { line = #lines, group = "AgentManagerStatusFailure" })
    end
    table.insert(lines, "")
    table.insert(lines, " CAPABILITIES")
    table.insert(highlights, { line = #lines, group = "AgentManagerTitle" })
    for _, capability in ipairs(selected.capabilities or {}) do
      local mark = capability.available and "+" or "-"
      table.insert(lines, string.format(" %s %s", mark, inline(capability.name)))
      table.insert(highlights, {
        line = #lines,
        group = capability.available and "AgentManagerStatusSuccess" or "AgentManagerMuted",
      })
      if capability.reason and capability.reason ~= "" then
        table.insert(lines, "   " .. inline(capability.reason))
        table.insert(highlights, { line = #lines, group = "AgentManagerMuted" })
      end
    end
  end
  self:_set_lines("agents", lines, highlights)
end

function View:_render_conversation()
  local agent = self.draft and nil or self.model:selected_agent()
  local subject = agent or self.draft
  local options = subject and subject.provider_options or {}
  if agent and self.actions.provider_options then
    options = self.actions.provider_options(agent) or options
  end
  local provider = subject and (subject.provider == "claude" and "Claude" or "Codex") or nil
  local model = inline(options and options.model or "default")
  local effort = inline(options and options.effort or "default")
  local provider_label = provider and string.format("%s — %s / %s", provider, model, effort) or nil
  local title = "no session configured"
  if agent then
    title = string.format("%s · %s · %s", inline(agent.title), provider_label, inline(agent.state))
  elseif self.draft then
    title = provider_label
  end
  local lines = { " 2 CONVERSATION", " " .. title, "" }
  local highlights = {
    { line = 1, group = "AgentManagerTitle" },
    { line = 2, group = "AgentManagerMuted" },
  }
  local messages = self.draft and {} or self.model:conversation()
  if #messages == 0 then
    if agent then
      table.insert(lines, " Type in the prompt box below and press <CR> to send.")
    elseif self.draft then
      table.insert(lines, " Enter the first prompt below to start this session.")
    else
      table.insert(lines, " Start a session in pane 1 with sn.")
    end
    table.insert(highlights, { line = #lines, group = "AgentManagerMuted" })
  end
  for _, message in ipairs(messages) do
    if message.role ~= "user" then
      local active_options = agent and agent.provider_options or {}
      local label = message.model or active_options.model or (provider or "Agent") .. " (default model)"
      if message.role == "system" then
        label = "SYSTEM"
      end
      table.insert(lines, " " .. inline(label))
      table.insert(highlights, {
        line = #lines,
        group = message.role == "system" and "AgentManagerMessageSystem"
          or "AgentManagerMessageAssistant",
      })
    end
    for _, line in ipairs(text_lines(message.text)) do
      table.insert(lines, " " .. line)
      if message.role == "user" then
        table.insert(highlights, { line = #lines, group = "AgentManagerMessageUser" })
      end
    end
    if message.streaming then
      table.insert(lines, " …")
      table.insert(highlights, { line = #lines, group = "AgentManagerMuted" })
    end
    table.insert(lines, "")
  end
  self:_set_lines("conversation", lines, highlights)
end

function View:_render_activity()
  local lines = { " 3 ACTIVITY", "" }
  local highlights = { { line = 1, group = "AgentManagerTitle" } }
  local activity = self.model:activity()
  local usage = self.model:usage_for()
  if next(usage) then
    table.insert(lines, " USAGE")
    table.insert(highlights, { line = #lines, group = "AgentManagerTitle" })
    local projected = {}
    usage_lines(usage, "", projected, 0)
    vim.list_extend(lines, projected)
    table.insert(lines, "")
  end
  if self.inspected_diff then
    if self.inspected_diff.agent_id ~= self.model.selected_agent_id then
      self.inspected_diff = nil
    else
      local offset = #lines
      vim.list_extend(lines, self.inspected_diff.lines)
      for _, highlight in ipairs(self.inspected_diff.highlights) do
        table.insert(highlights, { line = offset + highlight.line, group = highlight.group })
      end
      table.insert(lines, "")
    end
  end
  if #activity == 0 then
    table.insert(lines, " Tool and provider activity appears here.")
    table.insert(highlights, { line = #lines, group = "AgentManagerMuted" })
  end
  for _, entry in ipairs(activity) do
    table.insert(lines, string.format(" %04d  %s", entry.sequence or 0, inline(entry.type)))
    table.insert(highlights, { line = #lines, group = "AgentManagerTool" })
    if entry.detail and entry.detail ~= "" then
      for _, line in ipairs(text_lines(entry.detail)) do
        table.insert(lines, "       " .. line)
      end
    end
    local payload = entry.payload or {}
    if entry.type:match("^file%.") or entry.type:match("^diff%.") then
      local function append_diff(diff)
        if type(diff) ~= "string" then
          return
        end
        for _, line in ipairs(text_lines(diff)) do
          table.insert(lines, line)
          local group = line:sub(1, 1) == "+" and line:sub(1, 3) ~= "+++" and "AgentManagerDiffAdd"
            or line:sub(1, 1) == "-" and line:sub(1, 3) ~= "---" and "AgentManagerDiffDelete"
            or line:sub(1, 2) == "@@" and "AgentManagerDiffChange"
          if group then
            table.insert(highlights, { line = #lines, group = group })
          end
        end
      end
      append_diff(payload.diff)
      local item = type(payload.item) == "table" and payload.item or {}
      local changes = payload.changes or item.changes
      if type(changes) == "table" then
        for _, change in ipairs(changes) do
          if type(change) == "table" then
            table.insert(lines, "       " .. inline(change.path))
            append_diff(change.diff)
          end
        end
      elseif payload.path then
        table.insert(lines, "       " .. inline(payload.path))
      end
    end
  end
  self:_set_lines("activity", lines, highlights)
end

function View:_render_decision(action)
  if not action then
    self:_set_lines("decision", { " DECISION", "", " No pending human request." }, {
      { line = 1, group = "AgentManagerTitle" },
      { line = 3, group = "AgentManagerMuted" },
    })
    return
  end
  local agent = self.model.agents[action.agent_id] or {}
  local payload = action.payload or {}
  local title = action.kind == "approval" and " APPROVAL REQUIRED" or " QUESTION REQUIRED"
  local lines = {
    title,
    "",
    " Provider:  " .. inline(action.provider or agent.provider),
    " Workspace: " .. inline(agent.cwd),
    " Strategy:  " .. inline(agent.workspace_strategy),
    " Session:   " .. inline(agent.provider_session_id),
    "",
  }
  local highlights = {
    {
      line = 1,
      group = action.kind == "approval" and "AgentManagerApprovalPending"
        or "AgentManagerQuestionPending",
    },
    { line = 3, group = "AgentManagerMuted" },
    { line = 4, group = "AgentManagerMuted" },
    { line = 5, group = "AgentManagerMuted" },
    { line = 6, group = "AgentManagerMuted" },
  }
  if agent.managed_workspace and agent.managed_workspace ~= vim.NIL then
    table.insert(
      lines,
      7,
      " Task:      "
        .. inline(agent.managed_workspace.repository)
        .. "/"
        .. inline(agent.managed_workspace.task_id)
    )
    table.insert(highlights, { line = 7, group = "AgentManagerMuted" })
  end
  if action.kind == "approval" then
    table.insert(lines, " Action:  " .. inline(payload.tool_name))
    table.insert(lines, " Summary: " .. inline(payload.summary))
    if payload.command then
      table.insert(lines, "")
      table.insert(lines, " Command")
      table.insert(highlights, { line = #lines, group = "AgentManagerTitle" })
      for _, line in ipairs(text_lines(payload.command)) do
        table.insert(lines, "   " .. line)
      end
    end
    if payload.cwd then
      table.insert(lines, " Working directory: " .. inline(payload.cwd))
    end
    for _, detail in ipairs({
      { label = "Risk", value = payload.risk },
      { label = "Permission suggestions", value = payload.permission_suggestions },
    }) do
      if detail.value ~= nil and detail.value ~= vim.NIL then
        local ok, encoded = pcall(vim.json.encode, detail.value)
        if ok then
          table.insert(lines, " " .. detail.label .. ": " .. inline(encoded))
        end
      end
    end
    if #(payload.paths or {}) > 0 then
      table.insert(lines, "")
      table.insert(lines, " Affected paths")
      table.insert(highlights, { line = #lines, group = "AgentManagerTitle" })
      for _, path in ipairs(payload.paths) do
        table.insert(lines, "   " .. inline(path))
      end
    end
  else
    for index, question in ipairs(payload.questions or {}) do
      table.insert(lines, string.format(" %d. %s", index, inline(question.header or "Question")))
      table.insert(highlights, { line = #lines, group = "AgentManagerTitle" })
      for _, line in ipairs(text_lines(question.question)) do
        table.insert(lines, "    " .. line)
      end
      for _, option in ipairs(question.options or {}) do
        local description = option.description and option.description ~= ""
            and (" — " .. inline(option.description))
          or ""
        table.insert(lines, "      • " .. inline(option.label) .. description)
        table.insert(highlights, { line = #lines, group = "AgentManagerQuestionChoice" })
      end
      if question.multi_select then
        table.insert(lines, "    Multiple answers may be selected.")
        table.insert(highlights, { line = #lines, group = "AgentManagerMuted" })
      end
      table.insert(lines, "")
    end
  end
  table.insert(lines, "")
  if action.kind == "approval" then
    table.insert(lines, " y yes / allow    n no / deny")
  else
    table.insert(lines, " <CR> answer    n no / deny")
  end
  table.insert(highlights, { line = #lines, group = "AgentManagerHelpKey" })
  self:_set_lines("decision", lines, highlights)
end

function View:_sync_decision(action)
  if action and action.id ~= self.last_action_id and self.expanded then
    self:focus("conversation")
  end
  local content = self.windows.conversation
  if not valid_window(content) then
    return
  end
  local current = vim.api.nvim_win_get_buf(content)
  if action and (action.id ~= self.last_action_id or self.active_pane == "conversation") then
    vim.api.nvim_win_set_buf(content, self:_buffer("decision"))
    set_window_options(content, true, "decision")
    self.active_pane = "decision"
    if vim.api.nvim_get_current_tabpage() == self.tab then
      vim.api.nvim_set_current_win(content)
    end
  elseif not action and current == self.buffers.decision then
    vim.api.nvim_win_set_buf(content, self:_buffer("conversation"))
    set_window_options(content, true, "conversation")
    self.active_pane = "conversation"
  end
  self.last_action_id = action and action.id or nil
end

function View:show_diff(diff, title)
  if not valid_tab(self.tab) then
    self:open()
  end
  local lines = { " " .. inline(title or "DIFF"), "" }
  local highlights = { { line = 1, group = "AgentManagerTitle" } }
  if diff == "" then
    table.insert(lines, " No changes.")
    table.insert(highlights, { line = #lines, group = "AgentManagerMuted" })
  else
    for _, line in ipairs(text_lines(diff)) do
      table.insert(lines, line)
      local group = nil
      if line:sub(1, 1) == "+" and line:sub(1, 3) ~= "+++" then
        group = "AgentManagerDiffAdd"
      elseif line:sub(1, 1) == "-" and line:sub(1, 3) ~= "---" then
        group = "AgentManagerDiffDelete"
      elseif line:sub(1, 2) == "@@" then
        group = "AgentManagerDiffChange"
      end
      if group then
        table.insert(highlights, { line = #lines, group = group })
      end
    end
  end
  self.inspected_diff = {
    lines = lines,
    highlights = highlights,
    agent_id = self.model.selected_agent_id,
  }
  self:_render_activity()
  self:focus("activity")
end

function View:show_help()
  local lines = {
    " HELP",
    "",
    " SESSION",
    " sn      start a new session in focused directory",
    " so      open or continue focused session",
    " sf      fork focused session",
    " sa      archive selected inactive agent",
    "",
    " AGENT SETTINGS",
    " am      change model (applies on the next prompt)",
    " ae      change effort (applies on the next prompt)",
    "",
    " TURN",
    " tp      prompt selected agent",
    " ts      steer active turn",
    " ti      interrupt active turn",
    " tc      add explicit editor context",
    "",
    " DIFF / DELETE",
    " df      show focused session or directory diff",
    " ds      permanently delete focused provider session",
    "",
    " GO",
    " ga/gc/gt focus agents / conversation / activity",
    " gr      refresh filesystem, agents, and CLI sessions",
    "",
    " y / n   yes / allow or no / deny focused request",
    " 1 / 2 / 3 focus agents / conversation / activity",
    " <Tab>   cycle panes",
    " we      toggle expanded pane",
    " w1/w2/w3 focus Agents / Conversation / Activity (also while expanded)",
    " prompt: <CR> send · <C-j> newline",
    " <CR>    expand directory, open file/session, or answer question",
    " h / l   collapse / expand directory",
    " q       close workspace",
  }
  local highlights = { { line = 1, group = "AgentManagerTitle" } }
  for line = 3, #lines do
    table.insert(highlights, { line = line, group = "AgentManagerHelpDescription" })
  end
  self:_set_lines("activity", lines, highlights)
  self:focus("activity")
end

function View:close()
  if not valid_tab(self.tab) then
    self.tab = nil
    self.expanded = nil
    self.windows = {}
    return true
  end
  local number = vim.api.nvim_tabpage_get_number(self.tab)
  pcall(vim.cmd, "tabclose " .. number)
  self.tab = nil
  self.expanded = nil
  self.windows = {}
  return true
end

function View:teardown()
  self:close()
  if self.workflows then self.workflows:teardown() end
  if self.augroup then
    pcall(vim.api.nvim_del_augroup_by_id, self.augroup)
    self.augroup = nil
  end
  for _, buffer in pairs(self.buffers) do
    if valid_buffer(buffer) then
      pcall(vim.api.nvim_buf_delete, buffer, { force = true })
    end
  end
  self.buffers = {}
end

function View:status()
  return {
    open = valid_tab(self.tab),
    mode = self.mode,
    expanded = self.expanded ~= nil,
    active_pane = self.active_pane,
    home = self.home,
    buffers = vim.deepcopy(self.buffers),
    windows = vim.deepcopy(self.windows),
    backend = "native",
  }
end

return View
