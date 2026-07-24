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
  local known = require("conjurer.providers.known")

  local ok, cmd = pcall(cli.command, config)
  if not ok then
    health.error("config.cli: " .. tostring(cmd))
    return
  end
  local cli_ok = vim.fn.executable(cmd[1]) == 1
  local api = known.resolve_api()

  if provider == "auto" then
    health.info(("provider: auto (resolves to %s)"):format(cli_ok and "cli" or api.name))
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
        "Install one of: " .. table.concat(
          vim.tbl_map(function(r)
            return r.bin
          end, known.clis),
          ", "
        ),
        "or set cli_cmd/cli to another command",
      })
    end
  end

  if provider == "anthropic" or provider == "openai" or provider == "gemini" or (provider == "auto" and not cli_ok) then
    local name = provider ~= "auto" and provider or api.name
    if vim.fn.executable("curl") == 1 then
      health.ok("curl found")
    else
      health.error(("curl not found (required by the %s provider)"):format(name))
    end
    local env = name == "anthropic" and config.api_key_env or (name == "openai" and "OPENAI_API_KEY" or "GEMINI_API_KEY")
    local key = vim.env[env]
    if key and key ~= "" then
      health.ok(env .. " is set")
    else
      local tips = { "export " .. env .. "=<your key>" }
      if name == "anthropic" then
        table.insert(tips, "or set config.api_key_env to the variable you use")
      end
      health.error(env .. " is not set", tips)
    end
  end
end

return M
