local M = {}

function M.check()
  local health = vim.health
  local conjure = require("conjurer")
  local config = conjure.config

  health.start("conjurer")

  if vim.fn.has("nvim-0.10") == 1 then
    health.ok("Neovim >= 0.10")
  else
    health.error("Neovim 0.10+ is required (vim.system, extmark APIs)")
  end

  -- Provider resolution
  local provider = config.provider
  if type(provider) == "function" then
    health.ok("provider: custom function")
    return
  end

  local cli = require("conjurer.providers.cli")
  local cmd = cli.command(config)
  local cli_ok = vim.fn.executable(cmd[1]) == 1

  if provider == "auto" then
    health.info(("provider: auto (resolves to %s)"):format(cli_ok and "cli" or "anthropic"))
  else
    health.info("provider: " .. provider)
  end

  if provider == "auto" or provider == "cli" then
    if cli_ok then
      health.ok(("CLI executable found: %s"):format(cmd[1]))
      health.info("CLI command: " .. table.concat(cmd, " "))
    else
      local report = provider == "cli" and health.error or health.warn
      report(("CLI executable not found: %s"):format(cmd[1]), {
        "Install the Claude Code CLI, or set cli_cmd to another command",
      })
    end
  end

  if provider == "anthropic" or (provider == "auto" and not cli_ok) then
    if vim.fn.executable("curl") == 1 then
      health.ok("curl found")
    else
      health.error("curl not found (required by the anthropic provider)")
    end
    local key = vim.env[config.api_key_env]
    if key and key ~= "" then
      health.ok(config.api_key_env .. " is set")
    else
      health.error(config.api_key_env .. " is not set", {
        "export " .. config.api_key_env .. "=<your key>",
        "or set config.api_key_env to the variable you use",
      })
    end
  end
end

return M
