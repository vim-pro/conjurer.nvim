-- review = true: the model's result lands directly in the REAL buffer the
-- moment a draft exists, diffed in a new tabpage against a frozen whole-file
-- "before" snapshot. The region is unlocked from that point on — that's the
-- whole point, so the diff's real-buffer side is freely editable/navigable.
-- Accept/reject/retry/cancel decide whether the splice stays or reverts.
local H = dofile(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h") .. "/helpers.lua")

local calls = {}
require("conjurer").setup({
  review = true,
  provider = function(req, cb)
    local call = { req = req, cb = cb, canceled = false }
    table.insert(calls, call)
    return {
      cancel = function()
        call.canceled = true
      end,
    }
  end,
})

local buf = vim.api.nvim_get_current_buf()
local origin_win = vim.api.nvim_get_current_win()

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

local orig_notify = vim.notify

-- 1) region stays locked while generating, same as the non-review path.
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "alpha one", "beta two", "gamma three" })
vim.cmd("2Conjure transmute")
H.eq(#calls, 1, "provider called once")
vim.api.nvim_win_set_cursor(0, { 2, 0 })
H.feed("x")
settle("beta two", "locked while generating")

-- 2) resolving the provider splices into the REAL buffer immediately and
-- opens a diff against a frozen whole-file snapshot.
calls[#calls].cb(nil, "BETA TWO\nSECOND LINE")
H.eq(H.lines(buf)[2], "BETA TWO", "buffer is patched the moment review opens")
H.eq(H.lines(buf)[3], "SECOND LINE", "multi-line result lands fully")
H.eq(#vim.api.nvim_list_tabpages(), base_tabs + 1, "review opened a new tabpage")
goto_last_tab()

local before_win, after_win = diff_wins()
H.eq(vim.wo[before_win].diff, true, "before window is in diff mode")
H.eq(vim.wo[after_win].diff, true, "after window is in diff mode")
H.eq(vim.api.nvim_win_get_buf(after_win), buf, "after_win shows the REAL source buffer, not a copy")
local before_buf = vim.api.nvim_win_get_buf(before_win)
H.eq(
  table.concat(H.lines(before_buf), "\n"),
  "alpha one\nbeta two\ngamma three",
  "before buffer holds the WHOLE pre-patch file, not just the snippet"
)
H.eq(vim.api.nvim_get_current_win(), after_win, "cursor lands on the real buffer side")
if not H.virt_text(buf):find("reviewing: transmute", 1, true) then
  H.fail("reviewing header missing: " .. H.virt_text(buf))
end

-- 3) freely editable while reviewing — inverse of the generating-phase lock.
vim.api.nvim_set_current_win(after_win)
vim.api.nvim_win_set_cursor(0, { 2, 0 })
H.feed("x")
H.eq(H.lines(buf)[2], "ETA TWO", "region is freely editable while reviewing")
vim.api.nvim_buf_set_lines(buf, 1, 2, false, { "BETA TWO" })

-- 4) accept keeps whatever's live in the real buffer (hand-edited or not).
vim.api.nvim_set_current_win(after_win)
vim.api.nvim_buf_set_text(buf, 1, 0, 1, #"BETA TWO", { "HAND EDITED" })
vim.cmd("ConjureAccept")
H.eq(H.lines(buf)[2], "HAND EDITED", "accept keeps the live hand-edited buffer content")
H.eq(H.lines(buf)[3], "SECOND LINE", "accept doesn't touch the rest of the result")
H.eq(#vim.api.nvim_list_tabpages(), base_tabs, "accept closed the review tab")
H.eq(H.virt_text(buf), "", "narration cleared after accept")
vim.api.nvim_win_set_cursor(0, { 2, 0 })
H.feed("x")
H.eq(H.lines(buf)[2], "AND EDITED", "region editable after accept")

-- 5) reject undoes the draft AND any further hand-edits, back to the exact
-- pre-conjure text.
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "alpha one", "beta two", "gamma three" })
vim.cmd("2Conjure transmute")
calls[#calls].cb(nil, "REJECTED DRAFT")
H.eq(H.lines(buf)[2], "REJECTED DRAFT", "draft is live before reject — something to actually revert")
goto_last_tab()
do
  local _, aw = diff_wins()
  vim.api.nvim_set_current_win(aw)
end
vim.api.nvim_buf_set_lines(buf, 1, 2, false, { "HAND EDITED TOO" })
vim.cmd("ConjureReject")
H.eq(H.lines(buf)[2], "beta two", "reject restores the exact original text")
H.eq(#vim.api.nvim_list_tabpages(), base_tabs, "reject closed the review tab")

-- 6) retry reads the LIVE (possibly hand-edited) draft, reverts the buffer
-- immediately, and the narration banner flips back to "generating" for the
-- duration of the regenerate — not stuck on "reviewing".
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "alpha one", "beta two", "gamma three" })
vim.cmd("2Conjure transmute")
calls[#calls].cb(nil, "FIRST DRAFT")
goto_last_tab()
do
  local _, aw = diff_wins()
  vim.api.nvim_set_current_win(aw)
end
vim.api.nvim_buf_set_text(buf, 1, 0, 1, #"FIRST DRAFT", { "FIRST DRAFT TWEAKED" })
local before_retry_calls = #calls
vim.cmd("ConjureRetry make it louder")
H.eq(#calls, before_retry_calls + 1, "retry issued a second provider call")
H.eq(calls[#calls].req.previous_attempt, "FIRST DRAFT TWEAKED", "retry reads the LIVE hand-edited draft")
H.eq(calls[#calls].req.feedback, "make it louder", "retry sends the feedback")
H.eq(#vim.api.nvim_list_tabpages(), base_tabs, "old diff closed before the retry lands")
H.eq(H.lines(buf)[2], "beta two", "buffer reverted to original immediately when retry starts")
if not H.virt_text(buf):find("conjuring: transmute", 1, true) then
  H.fail("narration banner should read 'generating' during retry, got: " .. H.virt_text(buf))
end
if H.virt_text(buf):find("reviewing", 1, true) then
  H.fail("narration banner incorrectly stuck on 'reviewing' during retry regeneration")
end

calls[#calls].cb(nil, "SECOND DRAFT")
H.eq(#vim.api.nvim_list_tabpages(), base_tabs + 1, "retry result opens exactly one new diff")
goto_last_tab()
H.eq(H.lines(buf)[2], "SECOND DRAFT", "retry diff shows the new draft live in the real buffer")
do
  local _, aw = diff_wins()
  vim.api.nvim_set_current_win(aw)
end
vim.cmd("ConjureReject")
H.eq(#vim.api.nvim_list_tabpages(), base_tabs, "retry diff closed on reject")

-- 7) retry with no argument prompts for feedback.
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "alpha one", "beta two", "gamma three" })
vim.cmd("2Conjure transmute")
calls[#calls].cb(nil, "DRAFT")
goto_last_tab()
do
  local _, aw = diff_wins()
  vim.api.nvim_set_current_win(aw)
end
local prompted = false
vim.ui.input = function(_, cb)
  prompted = true
  cb("shorter please")
end
local before_prompt_calls = #calls
vim.cmd("ConjureRetry")
H.eq(prompted, true, "retry with no args prompts")
H.eq(#calls, before_prompt_calls + 1, "prompted retry issued a provider call")
H.eq(calls[#calls].req.feedback, "shorter please", "prompted feedback forwarded")
calls[#calls].cb(nil, "FINAL")
goto_last_tab()
do
  local _, aw = diff_wins()
  vim.api.nvim_set_current_win(aw)
end
vim.cmd("ConjureReject")

-- 8) cancelling from the SOURCE buffer/tab while reviewing must revert the
-- draft — under this design the real buffer WAS mutated, so "cancel leaves
-- the buffer unchanged" now requires an active revert, not a no-op.
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "alpha one", "beta two", "gamma three" })
vim.cmd("2Conjure transmute")
calls[#calls].cb(nil, "DRAFT")
H.eq(H.lines(buf)[2], "DRAFT", "draft is live before cancelling from the source tab")
H.eq(#vim.api.nvim_list_tabpages(), base_tabs + 1, "review open before source-side cancel")
vim.api.nvim_set_current_win(origin_win)
vim.cmd("ConjureCancel")
H.eq(calls[#calls].canceled, false, "cancel does not touch a finished provider handle")
H.eq(#vim.api.nvim_list_tabpages(), base_tabs, "source-side cancel closed the review")
H.eq(H.lines(buf)[2], "beta two", "source-side cancel REVERTS the draft, not keeps it")

-- 9) cancelling from INSIDE the review tab resolves via vim.t.conjurer_cast.
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "alpha one", "beta two", "gamma three" })
vim.cmd("2Conjure transmute")
calls[#calls].cb(nil, "DRAFT")
H.eq(H.lines(buf)[2], "DRAFT", "draft is live before review-side cancel")
goto_last_tab()
vim.cmd("ConjureCancel")
H.eq(#vim.api.nvim_list_tabpages(), base_tabs, "review-side cancel closed the review")
H.eq(H.lines(buf)[2], "beta two", "review-side cancel reverted the buffer")

-- 10) closing ONE side of the diff manually (no command) is an implicit
-- reject: draft reverted, warning fires exactly once.
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "alpha one", "beta two", "gamma three" })
vim.cmd("2Conjure transmute")
calls[#calls].cb(nil, "DRAFT")
goto_last_tab()
local warned, warn_count = nil, 0
vim.notify = function(msg, level)
  if level == vim.log.levels.WARN then
    warned = msg
    warn_count = warn_count + 1
  end
end
do
  local _, aw = diff_wins()
  vim.api.nvim_win_close(aw, true)
end
-- Wait on the ACTUAL deferred effect (the revert), not tab count: closing a
-- single window doesn't drop the tab count to base_tabs by itself (the
-- OTHER review window is still open), so this condition can't spuriously
-- pass before the scheduled cleanup has actually run.
vim.wait(500, function()
  return H.lines(buf)[2] == "beta two"
end, 10)
vim.notify = orig_notify
H.eq(#vim.api.nvim_list_tabpages(), base_tabs, "closing one window closes the whole review")
H.eq(warn_count, 1, "exactly one warning fired")
if not warned or not warned:find("treated as reject", 1, true) then
  H.fail("manual close did not warn correctly: " .. tostring(warned))
end
H.eq(H.lines(buf)[2], "beta two", "manual close reverted the buffer")

-- 11) :tabclose (both windows in a single batched close) must not
-- double-fire the warning or error.
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "alpha one", "beta two", "gamma three" })
vim.cmd("2Conjure transmute")
calls[#calls].cb(nil, "DRAFT")
goto_last_tab()
local warn_count11 = 0
vim.notify = function(msg, level)
  if level == vim.log.levels.WARN then
    warn_count11 = warn_count11 + 1
  end
end
local tabclose_ok = pcall(vim.cmd, "tabclose")
-- :tabclose itself closes both windows natively and synchronously — the tab
-- count already reads base_tabs before our WinClosed callback's deferred
-- cleanup has even run, so waiting on tab count here would pass instantly
-- without ever giving the scheduler a chance to run the revert. Wait on the
-- actual deferred effect instead.
vim.wait(500, function()
  return H.lines(buf)[2] == "beta two"
end, 10)
vim.notify = orig_notify
H.eq(tabclose_ok, true, ":tabclose did not error")
H.eq(#vim.api.nvim_list_tabpages(), base_tabs, ":tabclose closed the review")
H.eq(warn_count11, 1, ":tabclose fires the warning exactly once, not twice")
H.eq(H.lines(buf)[2], "beta two", ":tabclose reverted the buffer")

-- 12) accept/reject/retry from a tab with no conjurer_cast var: ERROR, no-op.
vim.api.nvim_set_current_win(origin_win)
local errored
vim.notify = function(msg, level)
  if level == vim.log.levels.ERROR then
    errored = msg
  end
end
vim.cmd("ConjureAccept")
if not errored or not errored:find("not a conjurer review tab", 1, true) then
  H.fail("ConjureAccept from a plain tab should error: " .. tostring(errored))
end
errored = nil
vim.cmd("ConjureReject")
if not errored then
  H.fail("ConjureReject from a plain tab should error")
end
errored = nil
vim.cmd("ConjureRetry")
if not errored then
  H.fail("ConjureRetry from a plain tab should error")
end
vim.notify = orig_notify

-- 13) line-kind full-region-deletion regression: reverting after the whole
-- patched region was deleted must not clobber adjacent real content (a
-- pre-existing extmark-collapse bug, previously untested anywhere).
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "one", "two", "three", "four", "five" })
vim.cmd("3,4Conjure transmute")
calls[#calls].cb(nil, "THREE\nFOUR")
H.eq(table.concat(H.lines(buf), "\n"), "one\ntwo\nTHREE\nFOUR\nfive", "collapse test: draft landed")
vim.api.nvim_buf_set_lines(buf, 2, 4, false, {})
H.eq(table.concat(H.lines(buf), "\n"), "one\ntwo\nfive", "collapse test: region fully deleted")
goto_last_tab()
do
  local _, aw = diff_wins()
  vim.api.nvim_set_current_win(aw)
end
vim.cmd("ConjureReject")
H.eq(
  table.concat(H.lines(buf), "\n"),
  "one\ntwo\nthree\nfour\nfive",
  "reject restores the original region without clobbering the adjacent 'five' line"
)

-- 14) grow/shrink arithmetic: reject must land exactly regardless of whether
-- the result has more or fewer lines/chars than the original snippet.

-- line-kind grow: 1 original line -> 3-line result.
vim.api.nvim_set_current_win(origin_win)
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "before", "middle", "after" })
vim.cmd("2Conjure transmute")
calls[#calls].cb(nil, "one\ntwo\nthree")
H.eq(table.concat(H.lines(buf), "\n"), "before\none\ntwo\nthree\nafter", "grow: draft landed")
goto_last_tab()
do
  local _, aw = diff_wins()
  vim.api.nvim_set_current_win(aw)
end
vim.cmd("ConjureReject")
H.eq(table.concat(H.lines(buf), "\n"), "before\nmiddle\nafter", "grow: reject restores exactly")

-- line-kind shrink: 3 original lines -> 1-line result.
vim.api.nvim_set_current_win(origin_win)
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "before", "one", "two", "three", "after" })
vim.cmd("2,4Conjure transmute")
calls[#calls].cb(nil, "middle")
H.eq(table.concat(H.lines(buf), "\n"), "before\nmiddle\nafter", "shrink: draft landed")
goto_last_tab()
do
  local _, aw = diff_wins()
  vim.api.nvim_set_current_win(aw)
end
vim.cmd("ConjureReject")
H.eq(table.concat(H.lines(buf), "\n"), "before\none\ntwo\nthree\nafter", "shrink: reject restores exactly")

-- char-kind grow: "cat" -> "elephant".
vim.api.nvim_set_current_win(origin_win)
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "the cat sat" })
vim.api.nvim_win_set_cursor(0, { 1, 4 })
vim.ui.input = function(_, cb)
  cb("transmute")
end
local before_grow_calls = #calls
H.feed("~iw")
H.eq(#calls, before_grow_calls + 1, "char-kind grow cast made")
calls[#calls].cb(nil, "elephant")
H.eq(H.lines(buf)[1], "the elephant sat", "char grow: draft landed")
goto_last_tab()
do
  local _, aw = diff_wins()
  vim.api.nvim_set_current_win(aw)
end
vim.cmd("ConjureReject")
H.eq(H.lines(buf)[1], "the cat sat", "char grow: reject restores exactly")

-- char-kind shrink: "elephant" -> "cat".
vim.api.nvim_set_current_win(origin_win)
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "the elephant sat" })
vim.api.nvim_win_set_cursor(0, { 1, 4 })
local before_shrink_calls = #calls
H.feed("~iw")
H.eq(#calls, before_shrink_calls + 1, "char-kind shrink cast made")
calls[#calls].cb(nil, "cat")
H.eq(H.lines(buf)[1], "the cat sat", "char shrink: draft landed")
goto_last_tab()
do
  local _, aw = diff_wins()
  vim.api.nvim_set_current_win(aw)
end
vim.cmd("ConjureReject")
H.eq(H.lines(buf)[1], "the elephant sat", "char shrink: reject restores exactly")

H.done(("review_spec PASS (%d provider calls)"):format(#calls))
