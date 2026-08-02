local M = {}

---@class conjurer.Request
---@field config conjurer.Config
---@field intent string Natural-language instruction for the transform.
---@field path string Target file path, cwd-relative ("" for unnamed buffers).
---@field filetype string 'filetype' of the target buffer ("" if unset).
---@field text string The snippet to transform.
---@field context_before string Buffer text preceding the snippet.
---@field context_after string Buffer text following the snippet.
---@field note string? Caller-supplied context about this snippet (e.g. the quickfix entry's message for a :make error).
---@field shared_context string? A finished exemplar the result should match in style and conventions (aggregate casts).
---@field on_narrate fun(line: string)? Call with each narration line as it streams (main loop only).
---@field previous_attempt string? The model's previous (rejected) draft; present only on retry.
---@field feedback string? User feedback on the previous draft; present only on retry.

---@class conjurer.Handle
---@field cancel fun() Abort the in-flight request.

---@alias conjurer.Callback fun(err: string?, result: string?) Call exactly once, on the main loop.
---@alias conjurer.Provider fun(request: conjurer.Request, callback: conjurer.Callback): conjurer.Handle?

---@class conjurer.Keymaps
---@field operator string|false Operator key (normal + visual). Default "~".
---@field line string|false Current-line key. Default "~~".

---@class conjurer.Config
---@field provider "auto"|"cli"|"anthropic"|"openai"|"gemini"|string|conjurer.Provider
---@field model string? Nil uses the resolved provider's own default.
---@field cli string? Force a known CLI recipe by name ("claude"|"codex"|"gemini") without hand-writing cli_cmd.
---@field cli_cmd string[]? Full CLI command; nil resolves a known one (see providers/known.lua).
---@field api_key_env string
---@field max_tokens integer
---@field thinking boolean
---@field context_lines integer
---@field max_concurrent integer Sites cast at once by :ConjureAll.
---@field region_expand boolean Expand bare entries to the enclosing multi-line syntax node.
---@field narration boolean
---@field flash_ms integer|false
---@field flash_hl string
---@field keymaps conjurer.Keymaps
---@field system_prompt string?
---@field review boolean Review the result in a diff before applying.

---@type conjurer.Config
M.config = {
  -- "auto" prefers a known local CLI (claude, then codex, then gemini) and
  -- falls back to whichever direct API has a key set (anthropic, then
  -- openai, then gemini). Also accepts "cli", "anthropic", "openai",
  -- "gemini", any module name under lua/conjurer/providers/, or a
  -- function(request, callback).
  provider = "auto",
  -- Nil uses whichever provider resolves its own default model.
  model = nil,
  -- Force a known CLI recipe by name ("claude"|"codex"|"gemini") when using
  -- the "cli" provider, without hand-writing cli_cmd.
  cli = nil,
  -- Local command for the "cli" provider. nil resolves a known CLI (see
  -- lua/conjurer/providers/known.lua) or the one named by `cli` above. A
  -- custom command owns its own flags; conjurer pipes the prompt to stdin
  -- and reads stdout.
  cli_cmd = nil,
  -- Environment variable holding the API key ("anthropic" provider only —
  -- "openai"/"gemini" use their own standard OPENAI_API_KEY/GEMINI_API_KEY).
  api_key_env = "ANTHROPIC_API_KEY",
  max_tokens = 16000,
  -- How long a single request may run before it is killed. Five minutes
  -- suits a region rewrite; a caller that sends a whole worklist — scry's
  -- drafting pass — can need more, and a timeout now says so by name
  -- rather than as "exit 124".
  timeout_ms = 300000,
  -- Adaptive thinking improves transform quality at some latency cost.
  thinking = true,
  -- Lines of surrounding buffer context sent with each request.
  context_lines = 40,
  -- Aggregate conjuring (:ConjureAll): how many sites to cast at once. Higher
  -- finishes sooner but fans out more concurrent provider processes.
  max_concurrent = 4,
  -- Expand a bare quickfix entry to the smallest multi-line syntax node
  -- starting on its line (a grep hit on a multi-line call edits the whole
  -- call). Entries with an explicit end_lnum are never expanded. false =
  -- always whole-line.
  region_expand = true,
  -- Stream the model's narration into the pending region as virtual lines.
  narration = true,
  -- Flash the conjured text when it lands (like the on_yank highlight).
  -- Milliseconds; false or 0 disables.
  flash_ms = 150,
  flash_hl = "IncSearch",
  -- Set any of these to false to skip that mapping.
  keymaps = {
    operator = "~", -- normal: ~{motion}, visual: ~
    line = "~~", -- current line
  },
  -- Override the built-in system prompt (string), or nil for the default.
  system_prompt = nil,
  -- Open a native Vim diff to review the result before it's spliced in,
  -- instead of auto-applying. See |conjurer-review|. Off by default to
  -- preserve the fast auto-apply flow.
  review = false,
}

--- Merge user options into the defaults, define keymaps and commands.
---@param opts conjurer.Config? Partial configuration; omitted keys keep defaults.
function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", M.config, opts or {})

  local operator = require("conjurer.operator")
  local maps = M.config.keymaps or {}

  if maps.operator then
    vim.keymap.set("n", maps.operator, operator.arm(), {
      expr = true,
      desc = "Conjure a change over a motion",
    })
    vim.keymap.set("x", maps.operator, operator.arm(), {
      expr = true,
      desc = "Conjure a change over the selection",
    })
  end
  if maps.line then
    vim.keymap.set("n", maps.line, operator.arm("_"), {
      expr = true,
      desc = "Conjure a change over the current line",
    })
  end

  vim.api.nvim_create_user_command("Conjure", function(cmd)
    operator.run_range(cmd.line1, cmd.line2, cmd.args)
  end, {
    nargs = "*",
    range = true,
    desc = "Conjure a change over a range (no argument reuses the last intent)",
  })

  vim.api.nvim_create_user_command("ConjureCancel", function()
    operator.cancel()
  end, {
    desc = "Cancel all in-flight conjures in this buffer",
  })

  vim.api.nvim_create_user_command("ConjureAccept", function()
    operator.accept()
  end, {
    desc = "Apply the reviewed result and close the diff",
  })

  vim.api.nvim_create_user_command("ConjureReject", function()
    operator.reject()
  end, {
    desc = "Discard the reviewed result and close the diff",
  })

  vim.api.nvim_create_user_command("ConjureRetry", function(cmd)
    operator.retry(cmd.args)
  end, {
    nargs = "*",
    desc = "Re-conjure the reviewed region with feedback (prompts if omitted)",
  })

  -- Aggregate conjuring over the quickfix list. Populate the list however you
  -- like (:grep, LSP references, :cexpr), then cast a shared intent over it.
  vim.api.nvim_create_user_command("ConjureAll", function(cmd)
    require("conjurer.quickfix").all(cmd.args)
  end, {
    nargs = "*",
    desc = "Conjure an intent over every entry in the quickfix list",
  })

  vim.api.nvim_create_user_command("ConjureNext", function(cmd)
    require("conjurer.quickfix").next(cmd.args)
  end, {
    nargs = "*",
    desc = "Conjure the current quickfix entry and advance (reuses the last intent)",
  })

  vim.api.nvim_create_user_command("ConjureRejectSite", function()
    require("conjurer.quickfix").reject()
  end, {
    desc = "Revert the conjured quickfix site under the cursor",
  })

  vim.api.nvim_create_user_command("ConjureRetrySite", function(cmd)
    require("conjurer.quickfix").retry_site(cmd.args)
  end, {
    nargs = "*",
    desc = "Re-conjure the site under the cursor with feedback (prompts if omitted)",
  })

  vim.api.nvim_create_user_command("ConjureRejectAll", function()
    require("conjurer.quickfix").reject_all()
  end, {
    desc = "Unwind the whole batch: drop queued, cancel running, revert applied sites",
  })

  vim.api.nvim_create_user_command("ConjureExemplar", function(cmd)
    require("conjurer.quickfix").set_exemplar(
      cmd.range > 0 and cmd.line1 or nil,
      cmd.range > 0 and cmd.line2 or nil,
      cmd.bang
    )
  end, {
    range = true,
    bang = true,
    desc = "Pin the range as this list's exemplar (! clears, bare shows)",
  })
end

--- Resolve the configured provider to a request function.
---@return conjurer.Provider
function M.get_provider()
  local provider = M.config.provider
  if type(provider) == "function" then
    return provider
  end
  if provider == "auto" then
    local exe = require("conjurer.providers.cli").command(M.config)[1]
    provider = vim.fn.executable(exe) == 1 and "cli" or require("conjurer.providers.known").resolve_api().name
  end
  return require("conjurer.providers." .. provider).request
end

return M
