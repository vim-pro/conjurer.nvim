-- The cli provider: auto-resolution (CLI priority list, then API-key
-- fallback), config.cli/config.cli_cmd resolution, a real async round trip
-- through a protocol-speaking fake CLI, narration extraction, indentation
-- preserved.
local H = dofile(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h") .. "/helpers.lua")

-- Isolate from whatever's actually set in the shell running these tests.
vim.env.ANTHROPIC_API_KEY, vim.env.OPENAI_API_KEY, vim.env.GEMINI_API_KEY = nil, nil, nil

local fake = H.root .. "/tests/fakeclaude"
local conjurer = require("conjurer")
local cli = require("conjurer.providers.cli")
local known = require("conjurer.providers.known")

-- auto-resolution: missing exe -> anthropic, present exe -> cli
conjurer.setup({ provider = "auto", cli_cmd = { H.root .. "/tests/definitely-missing" } })
if conjurer.get_provider() ~= require("conjurer.providers.anthropic").request then
  H.fail("auto should fall back to anthropic")
end
conjurer.setup({ provider = "auto", cli_cmd = { fake } })
if conjurer.get_provider() ~= require("conjurer.providers.cli").request then
  H.fail("auto should pick cli")
end

-- known.resolve_api: priority order among API keys actually set.
vim.env.ANTHROPIC_API_KEY, vim.env.OPENAI_API_KEY, vim.env.GEMINI_API_KEY = nil, nil, nil
H.eq(known.resolve_api().name, "anthropic", "resolve_api: nothing set defaults to anthropic")
vim.env.OPENAI_API_KEY = "sk-fake"
H.eq(known.resolve_api().name, "openai", "resolve_api: only OPENAI_API_KEY set")
vim.env.GEMINI_API_KEY = "g-fake"
H.eq(known.resolve_api().name, "openai", "resolve_api: openai still wins over gemini")
vim.env.ANTHROPIC_API_KEY = "sk-ant-fake"
H.eq(known.resolve_api().name, "anthropic", "resolve_api: anthropic wins over both")
vim.env.ANTHROPIC_API_KEY, vim.env.OPENAI_API_KEY, vim.env.GEMINI_API_KEY = nil, nil, nil

-- cli.command: cli_cmd wins over everything else.
H.eq(
  cli.command({ cli_cmd = { "custom", "cmd" } })[1],
  "custom",
  "cli_cmd wins over config.cli and auto-probing"
)

-- cli.command: config.cli forces a named recipe, model substitution works,
-- and a nil model falls back to claude's own default (not a hole in the
-- table — the exact bug this design guards against).
local claude_cmd = cli.command({ cli = "claude", model = "custom-model" })
if not vim.tbl_contains(claude_cmd, "custom-model") then
  H.fail("config.cli=claude with a model should use it: " .. vim.inspect(claude_cmd))
end
local claude_cmd_default = cli.command({ cli = "claude" })
if not vim.tbl_contains(claude_cmd_default, "claude-opus-4-8") then
  H.fail("config.cli=claude with no model should default to claude-opus-4-8: " .. vim.inspect(claude_cmd_default))
end
H.eq(#claude_cmd_default, 8, "no nil hole in the claude recipe's command array")

-- cli.command: an unknown config.cli errors clearly rather than crashing a
-- caller with a nil-index traceback.
local ok, err = pcall(cli.command, { cli = "nonexistent" })
if ok or not tostring(err):find("unknown cli", 1, true) then
  H.fail("config.cli=nonexistent should error clearly: " .. vim.inspect(err))
end

-- cli.command: with nothing forced, probing picks the first executable
-- candidate in priority order. Monkeypatch vim.fn.executable rather than
-- creating fixture files literally named "codex"/"gemini" on PATH — a real
-- binary with that name could actually exist on a dev machine.
do
  local real_executable = vim.fn.executable
  -- Known bin names (claude/codex/gemini) are fully faked here — a real
  -- claude install on the dev machine running this suite must not leak in
  -- and win regardless of what's being simulated. Anything else (e.g.
  -- "curl") falls through to the real check.
  local known_bins = { claude = true, codex = true, gemini = true }
  local available = {}
  vim.fn.executable = function(name)
    if known_bins[name] then
      return available[name] and 1 or 0
    end
    return real_executable(name)
  end

  available = { codex = true, gemini = true }
  H.eq(cli.command({})[1], "codex", "probing picks the first executable candidate (claude absent)")

  available = { gemini = true }
  H.eq(cli.command({})[1], "gemini", "probing skips codex when only gemini is executable")

  vim.fn.executable = real_executable
end

-- real async round trip; narration line must reach the virt_lines, and the
-- protocol markers must not leak into the buffer
local buf = vim.api.nvim_get_current_buf()
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "  indented line", "keep me" })
vim.cmd("1Conjure shout")

local narrated = false
local ok = vim.wait(5000, function()
  narrated = narrated or H.virt_text(buf):find("planning the transmutation", 1, true) ~= nil
  return H.lines(buf)[1] == "  INDENTED LINE"
end, 20)
if not ok then
  H.fail("cli round trip: " .. vim.inspect(H.lines(buf)))
end
H.eq(H.lines(buf)[2], "keep me", "other lines untouched")
if not narrated then
  H.fail("narration never displayed")
end
for _, l in ipairs(H.lines(buf)) do
  if l:find("RESULT", 1, true) or l:find("planning", 1, true) then
    H.fail("protocol leaked into buffer: " .. l)
  end
end
H.eq(#H.pending_marks(buf), 0, "decorations cleared after cli round trip")

H.done("cli_spec PASS")
