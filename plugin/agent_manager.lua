if vim.g.loaded_agent_manager == 1 then
  return
end
vim.g.loaded_agent_manager = 1

local function manager()
  return require("agent_manager")
end

vim.api.nvim_create_user_command("AgentManager", function()
  manager().open()
end, { desc = "Open the Agent Manager workspace" })

vim.api.nvim_create_user_command("AgentManagerWorkflows", function()
  manager().open_workflows()
end, { desc = "Inspect long-running workflow checklists and sessions" })

vim.api.nvim_create_user_command("AgentManagerStart", function(args)
  local cwd = vim.fs.root(0, { ".git" }) or vim.uv.cwd()
  local provider = args.args ~= "" and args.args or nil
  manager().open()
  manager().start_ui({
    provider = provider,
    cwd = cwd,
  })
end, {
  nargs = "?",
  complete = function()
    return { "codex", "claude" }
  end,
  desc = "Start a new Codex or Claude session",
})

vim.api.nvim_create_user_command("AgentManagerAttach", function()
  manager().open()
  manager().attach_ui()
end, { desc = "Open an active session or continue a saved session" })

vim.api.nvim_create_user_command("AgentManagerSend", function(args)
  manager().prompt_ui(args.args)
end, { nargs = "*", desc = "Send a prompt to the selected agent" })

vim.api.nvim_create_user_command("AgentManagerSteer", function(args)
  manager().steer_ui(args.args)
end, { nargs = "*", desc = "Steer the selected active turn" })

vim.api.nvim_create_user_command("AgentManagerInterrupt", function()
  manager().confirm_interrupt()
end, { desc = "Confirm and interrupt the selected active turn" })

vim.api.nvim_create_user_command("AgentManagerFork", function()
  manager().fork()
end, { desc = "Fork the selected resumable session" })

vim.api.nvim_create_user_command("AgentManagerArchive", function()
  manager().confirm_archive()
end, { desc = "Confirm and archive the selected inactive agent" })

vim.api.nvim_create_user_command("AgentManagerDelete", function()
  manager().confirm_delete_session()
end, { desc = "Confirm and permanently delete the selected provider session" })

vim.api.nvim_create_user_command("AgentManagerContext", function()
  manager().context_ui()
end, { desc = "Queue explicit editor context for the selected agent" })

vim.api.nvim_create_user_command("AgentManagerDiff", function()
  manager().diff_ui()
end, { desc = "Show the workspace diff or resolve dirty-buffer conflicts" })

vim.api.nvim_create_user_command("AgentManagerHealth", function()
  vim.cmd("checkhealth agent_manager")
end, { desc = "Show Agent Manager health diagnostics" })

vim.api.nvim_create_user_command("AgentManagerClose", function()
  manager().close()
end, { desc = "Close the Agent Manager workspace" })
