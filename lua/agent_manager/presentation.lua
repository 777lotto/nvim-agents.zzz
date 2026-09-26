local M = {
  contract_version = 1,
  plugin_id = "agent.manager",
  version = "0.2.0",
}

local function copy(value, seen)
  if type(value) ~= "table" then
    return value
  end
  seen = seen or {}
  if seen[value] then
    return seen[value]
  end
  local result = {}
  seen[value] = result
  for key, item in pairs(value) do
    result[copy(key, seen)] = copy(item, seen)
  end
  return result
end

local function token(id, fallback)
  return {
    declared = { source = "literal", value = { kind = "token", id = id } },
    fallback = { kind = "rgb", value = fallback },
  }
end

local function color_property(id, label, field, value)
  return {
    id = id,
    label = label,
    field = field,
    type = { kind = "color", allow_unset = true },
    declared = copy(value.declared),
    semantic_fallback = copy(value.fallback),
    reset = "declared",
    persist = true,
    apply = { mode = "immediate" },
  }
end

local function boolean_property(id, label, field, value)
  return {
    id = id,
    label = label,
    field = field,
    type = { kind = "boolean" },
    declared = { source = "literal", value = value },
    semantic_fallback = value,
    reset = "declared",
    persist = true,
    apply = { mode = "immediate" },
  }
end

local palette = {
  base = token("ux.foundation.palette.base", "#24273A"),
  mantle = token("ux.foundation.palette.mantle", "#1E2030"),
  surface0 = token("ux.foundation.palette.surface0", "#363A4F"),
  text = token("ux.foundation.palette.text", "#CAD3F5"),
  overlay0 = token("ux.foundation.palette.overlay0", "#6E738D"),
  blue = token("ux.foundation.palette.blue", "#8AADF4"),
  mauve = token("ux.foundation.palette.mauve", "#C6A0F6"),
  lavender = token("ux.foundation.palette.lavender", "#B7BDF8"),
  sky = token("ux.foundation.palette.sky", "#91D7E3"),
  teal = token("ux.foundation.palette.teal", "#8BD5CA"),
  green = token("ux.foundation.palette.green", "#A6DA95"),
  yellow = token("ux.foundation.palette.yellow", "#EED49F"),
  red = token("ux.foundation.palette.red", "#ED8796"),
  peach = token("ux.foundation.palette.peach", "#F5A97F"),
  black = { declared = { source = "literal", value = { kind = "rgb", value = "#000000" } },
    fallback = { kind = "rgb", value = "#000000" } },
}

local function role(id, label, group, native_link, foreground, opts)
  opts = opts or {}
  local properties = {
    color_property("foreground", "Foreground", "fg", foreground),
  }
  if opts.background then
    properties[#properties + 1] = color_property("background", "Background", "bg", opts.background)
  end
  if opts.bold ~= nil then
    properties[#properties + 1] = boolean_property("bold", "Bold", "bold", opts.bold)
  end
  if opts.italic ~= nil then
    properties[#properties + 1] = boolean_property("italic", "Italic", "italic", opts.italic)
  end
  return {
    id = id,
    label = label,
    group = group,
    native_link = native_link,
    native_attributes = opts.native_attributes,
    properties = properties,
  }
end

local COMPONENTS = {
  {
    id = "shell",
    label = "Application Shell",
    roles = {
      role("normal", "Normal", "AgentManagerNormal", "Normal", palette.text, { background = palette.base }),
      role("border", "Border", "AgentManagerBorder", "FloatBorder", palette.overlay0),
      role("title", "Title", "AgentManagerTitle", "Title", palette.blue, { bold = true }),
      role("selection", "Selection", "AgentManagerSelection", "CursorLine", palette.text, {
        background = palette.surface0,
      }),
      role("muted", "Muted", "AgentManagerMuted", "Comment", palette.overlay0, { italic = true }),
    },
  },
  {
    id = "agent_list",
    label = "Agent List",
    roles = {
      role("provider_codex", "Codex Provider", "AgentManagerProviderCodex", "DiagnosticInfo", palette.blue, {
        bold = true,
      }),
      role(
        "provider_claude",
        "Claude Provider",
        "AgentManagerProviderClaude",
        "DiagnosticWarn",
        palette.peach,
        { bold = true }
      ),
    },
  },
  {
    id = "conversation",
    label = "Conversation",
    roles = {
      role("message_user", "User Message", "AgentManagerMessageUser", "Special", palette.mauve, {
        bold = false,
        native_attributes = { fg = "#C6A0F6", bold = false },
      }),
      role("message_assistant", "Model Label", "AgentManagerMessageAssistant", "DiagnosticInfo", palette.blue, {
        bold = false,
        native_attributes = { fg = "#8AADF4", bold = false },
      }),
      role("message_system", "System Message", "AgentManagerMessageSystem", "Comment", palette.overlay0, {
        italic = true,
      }),
      role("markdown_heading", "Markdown Heading", "AgentManagerMarkdownHeading", "@markup.heading", palette.lavender, {
        bold = true,
      }),
      role("markdown_fence", "Markdown Fence", "AgentManagerMarkdownFence", "Comment", palette.overlay0),
      role("markdown_code", "Markdown Code Block", "AgentManagerMarkdownCode", "@markup.raw.block", palette.teal),
      role("markdown_code_span", "Markdown Code Span", "AgentManagerMarkdownCodeSpan", "@markup.raw", palette.green),
      role("markdown_strong", "Markdown Strong", "AgentManagerMarkdownStrong", "@markup.strong", palette.text, {
        bold = true,
      }),
      role("markdown_emphasis", "Markdown Emphasis", "AgentManagerMarkdownEmphasis", "@markup.italic", palette.text, {
        italic = true,
      }),
      role("markdown_list_marker", "Markdown List Marker", "AgentManagerMarkdownListMarker", "@markup.list", palette.sky),
      role("markdown_quote", "Markdown Quote", "AgentManagerMarkdownQuote", "@markup.quote", palette.overlay0, {
        italic = true,
      }),
      role("markdown_link", "Markdown Link", "AgentManagerMarkdownLink", "@markup.link.url", palette.blue),
      role("markdown_rule", "Markdown Rule", "AgentManagerMarkdownRule", "@punctuation.special", palette.overlay0),
      role(
        "markdown_table_border",
        "Markdown Table Border",
        "AgentManagerMarkdownTableBorder",
        "@punctuation.special",
        palette.overlay0
      ),
    },
  },
  {
    id = "activity",
    label = "Activity",
    roles = {
      role("tool", "Tool Activity", "AgentManagerTool", "Function", palette.teal),
    },
  },
  {
    id = "approval",
    label = "Approvals",
    roles = {
      role("pending", "Pending", "AgentManagerApprovalPending", "DiagnosticWarn", palette.yellow, {
        bold = true,
      }),
      role("allowed", "Allowed", "AgentManagerApprovalAllowed", "DiagnosticOk", palette.green),
      role("denied", "Denied", "AgentManagerApprovalDenied", "DiagnosticError", palette.red),
    },
  },
  {
    id = "question",
    label = "Questions",
    roles = {
      role("pending", "Pending", "AgentManagerQuestionPending", "DiagnosticWarn", palette.yellow, {
        bold = true,
      }),
      role("choice", "Choice", "AgentManagerQuestionChoice", "Special", palette.sky),
    },
  },
  {
    id = "diff",
    label = "Diff",
    roles = {
      role("add", "Added", "AgentManagerDiffAdd", "DiffAdd", palette.green),
      role("change", "Changed", "AgentManagerDiffChange", "DiffChange", palette.yellow),
      role("delete", "Deleted", "AgentManagerDiffDelete", "DiffDelete", palette.red),
    },
  },
  {
    id = "input",
    label = "Input",
    roles = {
      role("prompt", "Prompt", "AgentManagerInput", "Normal", palette.text, { background = palette.mantle }),
    },
  },
  {
    id = "status",
    label = "Status",
    roles = {
      role("running", "Running", "AgentManagerStatusRunning", "DiagnosticInfo", palette.blue),
      role("waiting", "Waiting", "AgentManagerStatusWaiting", "DiagnosticWarn", palette.yellow),
      role("success", "Success", "AgentManagerStatusSuccess", "DiagnosticOk", palette.green),
      role("failure", "Failure", "AgentManagerStatusFailure", "DiagnosticError", palette.red),
      role("session_ended", "Ended Session", "AgentManagerSessionEnded", "Comment", palette.black),
      role("interrupted", "Interrupted", "AgentManagerStatusInterrupted", "DiagnosticWarn", palette.peach),
    },
  },
  {
    id = "help",
    label = "Help",
    roles = {
      role("key", "Key", "AgentManagerHelpKey", "Special", palette.blue, { bold = true }),
      role("description", "Description", "AgentManagerHelpDescription", "Comment", palette.overlay0),
    },
  },
}

local function fixture_id(component_id)
  return "agent.manager." .. component_id .. ".v1"
end

local function manifest()
  local components = {}
  for _, component in ipairs(COMPONENTS) do
    local states = {}
    for _, item in ipairs(component.roles) do
      states[#states + 1] = {
        id = item.id,
        label = item.label,
        target = {
          kind = "highlight",
          group = item.group,
          management = "managed",
        },
        properties = copy(item.properties),
      }
    end
    components[#components + 1] = {
      id = component.id,
      label = component.label,
      optional_target = "agent-manager.nvimz",
      capability = "presentation_available",
      preview = { fixture_id = fixture_id(component.id) },
      states = states,
    }
  end
  return {
    schema_version = M.contract_version,
    plugin = {
      id = M.plugin_id,
      label = "Agent Manager",
      version = M.version,
    },
    components = components,
  }
end

local function fixtures()
  local result = {}
  for _, component in ipairs(COMPONENTS) do
    local lines = {}
    local states = {}
    for _, item in ipairs(component.roles) do
      local property_id = table.concat({ M.plugin_id, component.id, item.id, "foreground" }, "/")
      lines[#lines + 1] = {
        segments = {
          {
            text = " " .. item.label .. " ",
            hl_group = item.group,
            state = item.id,
            property_id = property_id,
          },
        },
      }
      states[#states + 1] = {
        state_id = item.id,
        group = item.group,
        property_id = property_id,
      }
    end
    local id = fixture_id(component.id)
    result[id] = {
      id = id,
      schema_version = M.contract_version,
      plugin_id = M.plugin_id,
      component_id = component.id,
      label = component.label .. " · deterministic preview",
      editor = {
        termguicolors = true,
        layouts = {
          { id = "wide", columns = 160 },
          { id = "medium", columns = 110 },
          { id = "narrow", columns = 72 },
        },
      },
      states = states,
      lines = lines,
    }
  end
  return result
end

function M.manifest()
  return manifest()
end

function M.implementation()
  return {
    capabilities = {
      presentation_available = function()
        return {
          available = true,
          capabilities = {
            offline_preview = true,
            native_fallback = true,
            schema_version = M.contract_version,
          },
        }
      end,
    },
    fixtures = fixtures(),
  }
end

function M.fixtures()
  return copy(fixtures())
end

function M.fixture(id)
  return copy(fixtures()[id])
end

function M.native_links()
  local result = {}
  for _, component in ipairs(COMPONENTS) do
    for _, item in ipairs(component.roles) do
      result[#result + 1] = {
        group = item.group,
        target = item.native_link,
        attributes = copy(item.native_attributes),
      }
    end
  end
  return copy(result)
end

return M
