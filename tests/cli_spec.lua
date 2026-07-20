-- The cli provider: auto-resolution, a real async round trip through a
-- protocol-speaking fake CLI, narration extraction, indentation preserved.
local H = dofile(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h") .. "/helpers.lua")

local fake = H.root .. "/tests/fakeclaude"
local conjurer = require("conjurer")

-- auto-resolution: missing exe -> anthropic, present exe -> cli
conjurer.setup({ provider = "auto", cli_cmd = { H.root .. "/tests/definitely-missing" } })
if conjurer.get_provider() ~= require("conjurer.providers.anthropic").request then
  H.fail("auto should fall back to anthropic")
end
conjurer.setup({ provider = "auto", cli_cmd = { fake } })
if conjurer.get_provider() ~= require("conjurer.providers.cli").request then
  H.fail("auto should pick cli")
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
