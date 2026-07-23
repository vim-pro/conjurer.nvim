-- review = true: results land in a native diff instead of auto-applying;
-- accept/reject/retry drive it, cancel and manual close both resolve it.
local H = dofile(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h") .. "/helpers.lua")

-- Each provider call is recorded as {req = ..., cb = ..., cancelled = false}.
local calls = {}
require("conjurer").setup({
  review = true,
  provider = function(req, cb)
    local call = { req = req, cb = cb, cancelled = false }
    table.insert(calls, call)
    return {
      cancel = function()
        call.cancelled = true
      end,
    }
  end,
})

local buf = vim.api.nvim_get_current_buf()
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "alpha one", "beta two", "gamma three" })

local function settle(want, what)
  vim.wait(1000, function()
    return H.lines(buf)[2] == want
  end, 10)
  H.eq(H.lines(buf)[2], want, what)
end

local base_tabs = #vim.api.nvim_list_tabpages()

local function goto_last_tab()
  local tabs = vim.api.nvim_list_tabpages()
  vim.api.nvim_set_current_tabpage(tabs[#tabs])
end

local function diff_wins()
  local wins = vim.api.nvim_tabpage_list_wins(0)
  if #wins ~= 2 then
    H.fail(("expected 2 windows in the review tab, got %d"):format(#wins))
  end
  return wins[1], wins[2]
end

-- 1) region stays locked while generating, same as the non-review path.
vim.cmd("2Conjure transmute")
H.eq(#calls, 1, "provider called once")
vim.api.nvim_win_set_cursor(0, { 2, 0 })
H.feed("x")
settle("beta two", "locked while generating")

-- 2) resolving the provider opens a diff instead of splicing.
calls[1].cb(nil, "BETA TWO\nSECOND LINE")
H.eq(H.lines(buf)[2], "beta two", "buffer unchanged once review opens")
H.eq(#vim.api.nvim_list_tabpages(), base_tabs + 1, "review opened a new tabpage")
goto_last_tab()

local before_win, after_win = diff_wins()
H.eq(vim.wo[before_win].diff, true, "before window is in diff mode")
H.eq(vim.wo[after_win].diff, true, "after window is in diff mode")
local before_buf = vim.api.nvim_win_get_buf(before_win)
local after_buf = vim.api.nvim_win_get_buf(after_win)
H.eq(table.concat(H.lines(before_buf), "\n"), "beta two", "before buffer holds the snapshot")
H.eq(table.concat(H.lines(after_buf), "\n"), "BETA TWO\nSECOND LINE", "after buffer holds the result")
H.eq(vim.api.nvim_get_current_win(), after_win, "cursor lands on the proposed side")

-- narration header switches to "reviewing"
if not H.virt_text(buf):find("reviewing: transmute", 1, true) then
  H.fail("reviewing header missing: " .. H.virt_text(buf))
end

-- region is still locked in the source buffer while reviewing
for _, w in ipairs(vim.api.nvim_list_wins()) do
  if vim.api.nvim_win_get_buf(w) == buf then
    vim.api.nvim_set_current_win(w)
    break
  end
end
vim.api.nvim_win_set_cursor(0, { 2, 0 })
H.feed("x")
settle("beta two", "locked while reviewing")

-- 3) accept reads the LIVE after_buf (simulating a hand-edited hunk), not
-- the frozen draft, and closes the diff.
vim.api.nvim_buf_set_lines(after_buf, 0, 1, false, { "HAND EDITED" })
vim.api.nvim_set_current_win(after_win)
vim.cmd("ConjureAccept")
H.eq(H.lines(buf)[2], "HAND EDITED", "accept applies the live after_buf")
H.eq(H.lines(buf)[3], "SECOND LINE", "accept applies every after_buf line")
H.eq(#vim.api.nvim_list_tabpages(), base_tabs, "accept closed the review tab")
H.eq(H.virt_text(buf), "", "narration cleared after accept")
vim.api.nvim_win_set_cursor(0, { 2, 0 })
H.feed("x")
H.eq(H.lines(buf)[2], "AND EDITED", "region editable after accept")

-- 4) reject discards and leaves the buffer byte-identical.
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "alpha one", "beta two", "gamma three" })
vim.cmd("2Conjure transmute")
calls[2].cb(nil, "REJECTED DRAFT")
H.eq(#vim.api.nvim_list_tabpages(), base_tabs + 1, "second review opened")
goto_last_tab()
vim.cmd("ConjureReject")
H.eq(H.lines(buf)[2], "beta two", "reject leaves buffer untouched")
H.eq(#vim.api.nvim_list_tabpages(), base_tabs, "reject closed the review tab")

-- 5) retry: feeds previous_attempt/feedback, closes the old diff before the
-- new provider call, and the new result opens exactly one fresh diff.
vim.cmd("2Conjure transmute")
calls[3].cb(nil, "FIRST DRAFT")
goto_last_tab()
local _, aw = diff_wins()
vim.api.nvim_set_current_win(aw)
vim.cmd("ConjureRetry make it louder")
H.eq(#calls, 4, "retry issued a second provider call")
H.eq(calls[4].req.previous_attempt, "FIRST DRAFT", "retry sends the rejected draft")
H.eq(calls[4].req.feedback, "make it louder", "retry sends the feedback")
H.eq(#vim.api.nvim_list_tabpages(), base_tabs, "old diff closed before the retry lands")

calls[4].cb(nil, "SECOND DRAFT")
H.eq(#vim.api.nvim_list_tabpages(), base_tabs + 1, "retry result opens exactly one new diff")
goto_last_tab()
local _, aw2 = diff_wins()
H.eq(table.concat(H.lines(vim.api.nvim_win_get_buf(aw2)), "\n"), "SECOND DRAFT", "retry diff shows the new draft")
vim.cmd("ConjureReject")
H.eq(#vim.api.nvim_list_tabpages(), base_tabs, "retry diff closed on reject")

-- 5b) retry with no argument prompts for feedback.
vim.cmd("2Conjure transmute")
calls[5].cb(nil, "DRAFT")
goto_last_tab()
local _, aw3 = diff_wins()
vim.api.nvim_set_current_win(aw3)
local prompted = false
vim.ui.input = function(_, cb)
  prompted = true
  cb("shorter please")
end
vim.cmd("ConjureRetry")
H.eq(prompted, true, "retry with no args prompts")
H.eq(#calls, 6, "prompted retry issued a provider call")
H.eq(calls[6].req.feedback, "shorter please", "prompted feedback forwarded")
calls[6].cb(nil, "FINAL")
goto_last_tab()
vim.cmd("ConjureReject")

-- 6) cancelling from the SOURCE buffer while reviewing: no live handle to
-- kill, the diff just closes.
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "alpha one", "beta two", "gamma three" })
vim.cmd("2Conjure transmute")
calls[7].cb(nil, "DRAFT")
H.eq(#vim.api.nvim_list_tabpages(), base_tabs + 1, "review open before source-side cancel")
for _, w in ipairs(vim.api.nvim_list_wins()) do
  if vim.api.nvim_win_get_buf(w) == buf then
    vim.api.nvim_set_current_win(w)
    break
  end
end
vim.cmd("ConjureCancel")
H.eq(calls[7].cancelled, false, "cancel does not touch a finished provider handle")
H.eq(#vim.api.nvim_list_tabpages(), base_tabs, "source-side cancel closed the review")
vim.api.nvim_win_set_cursor(0, { 2, 0 })
H.feed("x")
H.eq(H.lines(buf)[2], "eta two", "region unlocked after source-side cancel")

-- 7) cancelling from INSIDE the review buffer resolves via vim.b.conjurer_cast.
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "alpha one", "beta two", "gamma three" })
vim.cmd("2Conjure transmute")
calls[8].cb(nil, "DRAFT")
goto_last_tab()
local _, aw4 = diff_wins()
vim.api.nvim_set_current_win(aw4)
vim.cmd("ConjureCancel")
H.eq(#vim.api.nvim_list_tabpages(), base_tabs, "review-side cancel closed the review")
H.eq(H.lines(buf)[2], "beta two", "review-side cancel left buffer untouched")

-- 8) closing one side of the diff manually (no command) is an implicit
-- reject: unchanged buffer, unlocked, a WARN notification.
vim.cmd("2Conjure transmute")
calls[9].cb(nil, "DRAFT")
goto_last_tab()
local bw5, aw5 = diff_wins()
local warned
local orig_notify = vim.notify
vim.notify = function(msg, level)
  if level == vim.log.levels.WARN then
    warned = msg
  end
end
vim.api.nvim_win_close(aw5, true)
vim.api.nvim_win_close(bw5, true)
vim.notify = orig_notify
H.eq(#vim.api.nvim_list_tabpages(), base_tabs, "manual close removed the review tab")
if not warned or not warned:find("treated as reject", 1, true) then
  H.fail("manual close did not warn: " .. tostring(warned))
end
vim.api.nvim_win_set_cursor(0, { 2, 0 })
H.feed("x")
H.eq(H.lines(buf)[2], "eta two", "region unlocked after manual close")
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "alpha one", "beta two", "gamma three" })

-- 9) accept/reject/retry from a buffer with no conjurer_cast var: ERROR, no-op.
local errored
vim.notify = function(msg, level)
  if level == vim.log.levels.ERROR then
    errored = msg
  end
end
vim.cmd("ConjureAccept")
if not errored or not errored:find("not a conjurer review buffer", 1, true) then
  H.fail("ConjureAccept from a plain buffer should error: " .. tostring(errored))
end
errored = nil
vim.cmd("ConjureReject")
if not errored then
  H.fail("ConjureReject from a plain buffer should error")
end
errored = nil
vim.cmd("ConjureRetry")
if not errored then
  H.fail("ConjureRetry from a plain buffer should error")
end
vim.notify = orig_notify

H.done(("review_spec PASS (%d provider calls)"):format(#calls))
