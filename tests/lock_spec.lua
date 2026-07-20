-- The pending region is locked (edits are reverted) and displays streamed
-- narration; completion unlocks and splices.
local H = dofile(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h") .. "/helpers.lua")

local pending_cb, narrate
require("conjurer").setup({
  provider = function(req, cb)
    pending_cb = cb
    narrate = req.on_narrate
    return { cancel = function() end }
  end,
})

local buf = vim.api.nvim_get_current_buf()
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "alpha one", "beta two", "gamma three" })

vim.cmd("2Conjure transmute")
if not pending_cb then
  H.fail("provider not called")
end

-- narration header appears immediately
if not H.virt_text(buf):find("conjuring: transmute", 1, true) then
  H.fail("narration header missing: " .. H.virt_text(buf))
end

-- streamed narration lines render in the region
narrate("inspecting beta two")
narrate("rewriting in place")
local vt = H.virt_text(buf)
if not vt:find("inspecting beta two", 1, true) or not vt:find("rewriting in place", 1, true) then
  H.fail("narration lines missing: " .. vt)
end

-- editing inside the locked region is reverted (restore is scheduled, so
-- pump the loop until it lands)
local function settle(want, what)
  vim.wait(1000, function()
    return H.lines()[2] == want
  end, 10)
  H.eq(H.lines()[2], want, what)
end

vim.api.nvim_win_set_cursor(0, { 2, 0 })
H.feed("x")
settle("beta two", "locked region restored after x")

vim.api.nvim_win_set_cursor(0, { 2, 0 })
H.feed("ciwCHANGED")
H.feed("<Esc>")
settle("beta two", "locked region restored after ciw")

-- editing outside the region is untouched by the lock
vim.api.nvim_win_set_cursor(0, { 3, 0 })
H.feed("x")
H.eq(H.lines()[3], "amma three", "edit outside region persists")

-- completion splices, clears narration, unlocks
pending_cb(nil, "BETA TWO")
H.eq(H.lines()[2], "BETA TWO", "splice applied")
H.eq(H.virt_text(buf), "", "narration cleared")
H.eq(#H.pending_marks(buf), 0, "region mark cleared")

vim.api.nvim_win_set_cursor(0, { 2, 0 })
H.feed("x")
H.eq(H.lines()[2], "ETA TWO", "region editable after completion")

H.done("lock_spec PASS")
