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


-- A GUARD, NOT A REPRODUCTION — and the difference is stated because a
-- test that cannot fail is worse than no test.
--
-- Reported from a real session: a multi-line draft was in flight, `u` was
-- pressed, and conjurer put `Invalid 'end_col': out of range` on the screen
-- twice with a stack traceback, out of an autocommand. place_mark takes its
-- coordinates from the SNAPSHOT, so they describe the text that was put
-- back rather than the text that is there; during an undo those differ.
--
-- This shrinks the buffer under a live cast and drives the lock's restore
-- path, which is the shape of that failure. It PASSES WITHOUT THE FIX —
-- verified by stashing it — so it does not pin the reported bug. It stands
-- as a regression guard for the class, and the clamp it is meant to protect
-- is unproven against the exact path that produced the traceback.
local held2
require("conjurer").setup({
  provider = function(req, cb)
    held2 = cb
  end,
})
local ub = vim.api.nvim_create_buf(false, true)
vim.api.nvim_win_set_buf(0, ub)
vim.api.nvim_buf_set_lines(ub, 0, -1, false, { "alpha", "beta", "gamma", "delta" })
require("conjurer.operator").conjure_region(ub, { kind = "line", srow = 0, erow = 4 }, "rewrite these")

-- shrink the buffer under the in-flight cast, exactly as an undo of an
-- insertion does, then drive the lock's own restore path
vim.api.nvim_buf_set_lines(ub, 0, -1, false, { "alpha" })
local ok, err = pcall(function()
  vim.api.nvim_exec_autocmds("TextChanged", { buffer = ub })
  vim.wait(200, function()
    return false
  end, 10)
end)
H.eq(ok, true, "shrinking the buffer under a live cast does not throw: " .. tostring(err))
H.eq(vim.api.nvim_buf_is_valid(ub), true, "and the buffer survives")
require("conjurer.operator").cancel()

H.done("lock_spec PASS")
