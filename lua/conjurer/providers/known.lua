-- Shared registry of known local CLIs and direct APIs, so "auto" resolution
-- and :checkhealth stay in sync instead of hand-rolling the priority order
-- twice.
local M = {}

-- Tried in order; the first whose binary is executable wins (unless
-- config.cli names one explicitly). Each command(config) returns a fresh
-- string[] — never bake config.model directly into a table literal (a nil
-- model there leaves a hole mid-array, and vim.system's argv handling on a
-- table with a hole is undefined) — always resolve a local default first.
M.clis = {
  {
    name = "claude",
    bin = "claude",
    command = function(config)
      local model = config.model or "claude-opus-4-8"
      return {
        "claude",
        "-p",
        "--model",
        model,
        "--output-format",
        "stream-json",
        "--include-partial-messages",
        "--verbose",
      }
    end,
  },
  {
    name = "codex",
    bin = "codex",
    command = function(config)
      -- exec reads the whole prompt from stdin via "-"; read-only sandbox
      -- since we only want it as a text-transform backend, not letting it
      -- touch files itself.
      local cmd = { "codex", "exec", "-", "--sandbox", "read-only" }
      if config.model then
        vim.list_extend(cmd, { "--model", config.model })
      end
      return cmd
    end,
  },
  {
    name = "gemini",
    bin = "gemini",
    command = function(config)
      -- Piped, non-TTY stdin is treated as the full prompt in headless mode.
      local cmd = { "gemini" }
      if config.model then
        vim.list_extend(cmd, { "--model", config.model })
      end
      return cmd
    end,
  },
}

-- Tried in order for "auto" once no known CLI is executable; the first
-- whose env var is actually set wins, else default to the first (anthropic)
-- so "auto" with nothing configured fails exactly like it does today (a
-- clear "ANTHROPIC_API_KEY is not set" at request time).
M.apis = {
  { name = "anthropic", env = "ANTHROPIC_API_KEY" },
  { name = "openai", env = "OPENAI_API_KEY" },
  { name = "gemini", env = "GEMINI_API_KEY" },
}

--- Which direct-API provider "auto" should use, based on which API key is
--- actually set in the environment.
function M.resolve_api()
  for _, api in ipairs(M.apis) do
    local key = vim.env[api.env]
    if key and key ~= "" then
      return api
    end
  end
  return M.apis[1]
end

return M
