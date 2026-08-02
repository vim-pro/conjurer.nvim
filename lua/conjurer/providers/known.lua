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
      local cmd = { "claude", "-p" }
      -- NO PINNED FALLBACK. `model = nil` is documented as "uses the
      -- resolved provider's own default" and this said otherwise, quietly,
      -- for every user who never set one.
      --
      -- What it cost, measured on one drafting batch — same prompt, same 13
      -- tool calls, same 14 turns: the pinned model took 89.5s to the CLI
      -- default's 55.5s, and streamed ZERO characters of thinking against
      -- 1663. It opens thinking blocks that carry a signature and no text,
      -- so the longest phase of a request had nothing on the wire at all —
      -- a minute of silence that no amount of narration work could have
      -- filled, because there was nothing to narrate.
      --
      -- Pinning one is still a `model` away, and now it is the user saying
      -- so rather than this file.
      if config.model then
        vim.list_extend(cmd, { "--model", config.model })
      end
      vim.list_extend(cmd, {
        "--output-format",
        "stream-json",
        "--include-partial-messages",
        "--verbose",
      })
      return cmd
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
