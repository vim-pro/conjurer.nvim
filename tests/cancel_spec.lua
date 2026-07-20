-- :ConjureCancel kills the in-flight request, restores decorations, and a
-- late provider callback is ignored.
local H = dofile(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h") .. "/helpers.lua")

local pending_cb, cancelled
require("conjurer").setup({
  provider = function(_, cb)
    pending_cb = cb
    return {
      cancel = function()
        cancelled = true
      end,
    }
  end,
})

local buf = vim.api.nvim_get_current_buf()
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "hold the line" })

vim.cmd("1Conjure anything")
if #H.pending_marks(buf) == 0 then
  H.fail("no pending mark after cast")
end

vim.cmd("ConjureCancel")
H.eq(cancelled, true, "provider handle.cancel called")
H.eq(#H.pending_marks(buf), 0, "decorations cleared on cancel")
H.eq(H.lines()[1], "hold the line", "buffer untouched on cancel")

-- the buffer is editable again immediately
vim.api.nvim_win_set_cursor(0, { 1, 0 })
H.feed("x")
H.eq(H.lines()[1], "old the line", "editable after cancel")

-- a late callback from the killed request must be ignored
pending_cb(nil, "SHOULD NOT APPEAR")
H.eq(H.lines()[1], "old the line", "late callback ignored")

-- cancelling with nothing in flight must not error
vim.cmd("ConjureCancel")

H.done("cancel_spec PASS")
