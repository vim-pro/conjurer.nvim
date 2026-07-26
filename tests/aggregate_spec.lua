-- The aggregate driver: :ConjureAll casts a shared intent over quickfix
-- entries with bounded GLOBAL concurrency and per-buffer serialization
-- (same-file sites run one at a time so one splice can't disturb another's
-- pending region; different files run in parallel up to the cap). Tracks
-- per-site state, detects unchanged/overlapping results, re-runs idempotently,
-- reverts on reject, walks with :ConjureNext. Fake provider, callbacks fired
-- by hand (like cancel_spec / lock_spec).
local H = dofile(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h") .. "/helpers.lua")

local calls = {}
require("conjurer").setup({
  max_concurrent = 2,
  provider = function(req, cb)
    local call = { req = req, cb = cb }
    table.insert(calls, call)
    return {
      cancel = function()
        call.cancelled = true
      end,
    }
  end,
})

local qf = require("conjurer.quickfix")

local function pending_calls()
  local n = 0
  for _, c in ipairs(calls) do
    if not c.done then
      n = n + 1
    end
  end
  return n
end

-- Resolve the oldest un-answered, un-cancelled call with `result` (or error).
local function answer(result, err)
  for _, c in ipairs(calls) do
    if not c.done and not c.cancelled then
      c.done = true
      c.cb(err, result)
      return c
    end
  end
  H.fail("answer(): no pending call")
end

local function buf_with(lines)
  local b = vim.api.nvim_create_buf(false, false)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
  return b
end

-- 1) cross-buffer bounded concurrency: 4 sites in 4 files, k=2 → 2 in flight.
qf._reset()
calls = {}
local b = {}
local items = {}
for i = 1, 4 do
  b[i] = buf_with({ "x" .. i })
  items[i] = { bufnr = b[i], lnum = 1, text = "f" .. i }
end
vim.fn.setqflist({}, " ", { items = items })
qf.all("do it")
H.eq(pending_calls(), 2, "only max_concurrent (2) casts in flight across different buffers")
H.eq(calls[1].req.intent, "do it", "intent threaded into the request")
answer("A")
H.eq(pending_calls(), 2, "answering one launches the next (still 2 in flight)")
answer("B")
answer("C")
answer("D")
H.eq(pending_calls(), 0, "all four resolved")
for i = 1, 4 do
  H.eq(vim.api.nvim_buf_get_lines(b[i], 0, 1, false)[1], ({ "A", "B", "C", "D" })[i], "file " .. i .. " applied")
end

-- 2) same-buffer serialization + correct adjacent splices: 3 sites in ONE
-- file, k=2 → only 1 in flight at a time, and each lands on its own line.
qf._reset()
calls = {}
local one = buf_with({ "l1", "l2", "l3" })
vim.fn.setqflist({}, " ", {
  items = { { bufnr = one, lnum = 1, text = "a" }, { bufnr = one, lnum = 2, text = "b" }, { bufnr = one, lnum = 3, text = "c" } },
})
qf.all("shout")
H.eq(pending_calls(), 1, "same-file sites serialize: only 1 in flight despite k=2")
answer("L1")
H.eq(pending_calls(), 1, "next same-file site launches after the previous settles")
answer("L2")
answer("L3")
H.eq(
  table.concat(vim.api.nvim_buf_get_lines(one, 0, -1, false), ","),
  "L1,L2,L3",
  "each adjacent site landed on its own line (no mark disturbance)"
)

-- user_data stamped each entry with a site id.
local it = vim.fn.getqflist({ items = 1 }).items
local stamp = it[1].user_data and it[1].user_data.conjurer and it[1].user_data.conjurer.site
if not stamp then
  H.fail("entry stamped with a site id")
end

-- 3) idempotent re-run: everything done → nothing casts.
local before = #calls
qf.all("shout")
H.eq(#calls, before, "re-run with everything done casts nothing")

-- 4) a multi-line result shifts later same-file entries; serialization +
-- fresh region lookup keeps the next site correct.
qf._reset()
calls = {}
local grow = buf_with({ "p", "q", "r" })
vim.fn.setqflist({}, " ", { items = { { bufnr = grow, lnum = 1, text = "p" }, { bufnr = grow, lnum = 3, text = "r" } } })
qf.all("expand")
answer("P1\nP2\nP3") -- site 1 grows from 1 line to 3; "r" is now on line 5
H.eq(pending_calls(), 1, "second site launches after the first settles")
answer("R!")
local gl = vim.api.nvim_buf_get_lines(grow, 0, -1, false)
H.eq(table.concat(gl, ","), "P1,P2,P3,q,R!", "second site hit its shifted line, not a stale one")

-- 5) unchanged result → skipped (no spurious change), and settled on re-run.
qf._reset()
calls = {}
local u = buf_with({ "aa", "bb" })
vim.fn.setqflist({}, " ", { items = { { bufnr = u, lnum = 1, text = "a" }, { bufnr = u, lnum = 2, text = "b" } } })
qf.all("maybe")
answer("aa") -- unchanged
answer("XX") -- changed
H.eq(vim.api.nvim_buf_get_lines(u, 0, 1, false)[1], "aa", "unchanged site left as-is")
H.eq(vim.api.nvim_buf_get_lines(u, 1, 2, false)[1], "XX", "changed site applied")
local n5 = #calls
qf.all("maybe")
H.eq(#calls, n5, "skipped and done are both settled — re-run casts nothing")

-- 6) overlap (two entries on the SAME line) → only one casts.
qf._reset()
calls = {}
local o = buf_with({ "p", "q", "r" })
vim.fn.setqflist({}, " ", { items = { { bufnr = o, lnum = 2, text = "a" }, { bufnr = o, lnum = 2, text = "b" } } })
qf.all("touch")
H.eq(#calls, 1, "overlapping second entry skipped, not cast")
answer("Q!")
H.eq(vim.api.nvim_buf_get_lines(o, 1, 2, false)[1], "Q!", "the non-overlapping site applied")

-- 7) failure isolated and re-runnable.
qf._reset()
calls = {}
local f = buf_with({ "m", "n" })
vim.fn.setqflist({}, " ", { items = { { bufnr = f, lnum = 1, text = "a" }, { bufnr = f, lnum = 2, text = "b" } } })
qf.all("do")
answer(nil, "rate limited") -- site 1 fails
answer("N!") -- site 2 succeeds
H.eq(vim.api.nvim_buf_get_lines(f, 1, 2, false)[1], "N!", "second site applied despite first failing")
local n7 = #calls
qf.all("do")
H.eq(#calls, n7 + 1, "re-run retries exactly the one failed site")
answer("M!")
H.eq(vim.api.nvim_buf_get_lines(f, 0, 1, false)[1], "M!", "retried site now applied")

-- 8) reject reverts a site to its snapshot.
qf._reset()
calls = {}
local r = buf_with({ "keep", "orig", "tail" })
vim.api.nvim_set_current_buf(r)
vim.fn.setqflist({}, " ", { items = { { bufnr = r, lnum = 2, text = "a" } } })
qf.all("change")
answer("CHANGED")
H.eq(vim.api.nvim_buf_get_lines(r, 1, 2, false)[1], "CHANGED", "site applied before reject")
vim.cmd("copen")
vim.api.nvim_win_set_cursor(vim.fn.getqflist({ winid = 1 }).winid, { 1, 0 })
qf.reject()
H.eq(vim.api.nvim_buf_get_lines(r, 1, 2, false)[1], "orig", "reject restored the original snapshot")
vim.cmd("cclose")

-- 9) :ConjureNext casts the current entry and advances the idx.
qf._reset()
calls = {}
local n = buf_with({ "x1", "x2", "x3" })
vim.api.nvim_set_current_buf(n)
vim.fn.setqflist({}, " ", { items = { { bufnr = n, lnum = 1, text = "a" }, { bufnr = n, lnum = 2, text = "b" }, { bufnr = n, lnum = 3, text = "c" } } })
vim.fn.setqflist({}, "a", { idx = 1 })
qf.next("shout")
H.eq(#calls, 1, "ConjureNext cast exactly one site")
answer("X1!")
H.eq(vim.api.nvim_buf_get_lines(n, 0, 1, false)[1], "X1!", "current entry conjured")
H.eq(vim.fn.getqflist({ idx = 0 }).idx, 2, "idx advanced to the next entry")

-- 9b) request context: the file path rides along, and the entry's message is
-- forwarded as a note only when it differs from the matched line (a :make
-- diagnostic yes, a grep hit no).
qf._reset()
calls = {}
local ctx = buf_with({ "local x = nil + 1", "print('fine')" })
vim.api.nvim_buf_set_name(ctx, "ctxdemo.lua")
vim.fn.setqflist({}, " ", {
  items = {
    -- diagnostic-style: text is an error message, not the line
    { bufnr = ctx, lnum = 1, text = "E5108: attempt to perform arithmetic on a nil value" },
    -- grep-style: text is the matched line itself
    { bufnr = ctx, lnum = 2, text = "print('fine')" },
  },
})
qf.all("fix it")
H.eq(calls[1].req.path, "ctxdemo.lua", "request carries the file path")
H.eq(
  calls[1].req.note,
  "E5108: attempt to perform arithmetic on a nil value",
  "diagnostic message forwarded as the note"
)
answer("local x = 1")
H.eq(calls[2].req.note, nil, "grep-style entry text (same as the line) is not forwarded")
answer("print('fine')")

-- 9c) retry-with-feedback on a site: the model sees its applied draft (as it
-- currently reads, hand-edits included) plus the feedback; the site reverts
-- while the retry is in flight, and the new draft applies.
qf._reset()
calls = {}
local rt = buf_with({ "keep", "orig", "tail" })
vim.api.nvim_set_current_buf(rt)
vim.fn.setqflist({}, " ", { items = { { bufnr = rt, lnum = 2, text = "site" } } })
qf.all("change it")
answer("DRAFT V1")
H.eq(vim.api.nvim_buf_get_lines(rt, 1, 2, false)[1], "DRAFT V1", "first draft applied")
-- hand-edit the applied draft, then retry with feedback from the qf window
vim.api.nvim_buf_set_lines(rt, 1, 2, false, { "DRAFT V1 TWEAKED" })
vim.cmd("copen")
vim.api.nvim_win_set_cursor(vim.fn.getqflist({ winid = 1 }).winid, { 1, 0 })
local before_retry = #calls
qf.retry_site("shorter please")
H.eq(#calls, before_retry + 1, "retry issued a new provider call")
H.eq(calls[#calls].req.previous_attempt, "DRAFT V1 TWEAKED", "retry sends the LIVE draft, hand-edits included")
H.eq(calls[#calls].req.feedback, "shorter please", "retry sends the feedback")
H.eq(vim.api.nvim_buf_get_lines(rt, 1, 2, false)[1], "orig", "site reverted while the retry is in flight")
answer("V2")
H.eq(vim.api.nvim_buf_get_lines(rt, 1, 2, false)[1], "V2", "revised draft applied")
vim.cmd("cclose")

-- 9d) exemplar: explicit pinning, pilot harvest, precedence, clearing.
qf._reset()
calls = {}
local exb = buf_with({ "vim.notify(msg, vim.log.levels.INFO)", "-- convention line 2" })
vim.api.nvim_set_current_buf(exb)
local t1 = buf_with({ "print('a')", "print('b')" })
-- seed foreign context to prove read-modify-write preserves it
vim.fn.setqflist({}, " ", {
  items = { { bufnr = t1, lnum = 1, text = "a" }, { bufnr = t1, lnum = 2, text = "b" } },
  context = { otherplugin = { keep = 42 } },
})
-- explicit exemplar from the current buffer's lines 1-2
qf.set_exemplar(1, 2, false)
qf.all("convert")
H.eq(
  calls[1].req.shared_context,
  "vim.notify(msg, vim.log.levels.INFO)\n-- convention line 2",
  "explicit exemplar reaches the first site's request"
)
answer("x1")
H.eq(calls[2].req.shared_context, calls[1].req.shared_context, "and every subsequent site's")
answer("x2")
H.eq(vim.fn.getqflist({ context = 1 }).context.otherplugin.keep, 42, "foreign context keys survive our writes")

-- bang clears it
qf.set_exemplar(nil, nil, true)
qf._reset()
calls = {}
local t2 = buf_with({ "one", "two" })
vim.fn.setqflist({}, " ", { items = { { bufnr = t2, lnum = 1, text = "a" } } })
qf.all("go")
H.eq(calls[1].req.shared_context, nil, "cleared exemplar sends nothing")
answer("ONE")

-- 9e) pilot harvest: Next → judge/hand-edit → All infers the exemplar from
-- the pilot's LIVE text; a later improved pilot re-harvests; explicit wins.
qf._reset()
calls = {}
local pb = buf_with({ "p1", "p2", "p3" })
vim.api.nvim_set_current_buf(pb)
vim.fn.setqflist({}, " ", {
  items = {
    { bufnr = pb, lnum = 1, text = "a" },
    { bufnr = pb, lnum = 2, text = "b" },
    { bufnr = pb, lnum = 3, text = "c" },
  },
})
vim.fn.setqflist({}, "a", { idx = 1 })
qf.next("convert")
answer("PILOT DRAFT")
H.eq(vim.api.nvim_buf_get_lines(pb, 0, 1, false)[1], "PILOT DRAFT", "pilot applied")
-- the user judges and hand-fixes the pilot — this is the ratifying act
vim.api.nvim_buf_set_lines(pb, 0, 1, false, { "PILOT EDITED" })
qf.all("convert")
H.eq(calls[#calls].req.shared_context, "PILOT EDITED", "fan-out harvested the pilot's live text, edits included")
answer("P2")
answer("P3")
local ex_now = vim.fn.getqflist({ context = 1 }).context.conjurer.exemplar
H.eq(ex_now.inferred, true, "harvested exemplar is marked inferred")

-- improve the pilot again; a new fan-out re-harvests (inferred tracks truth)
vim.api.nvim_buf_set_lines(pb, 0, 1, false, { "PILOT V2" })
vim.fn.setqflist({}, "a", { items = { { bufnr = pb, lnum = 3, text = "d" } } })
-- (entry 3's site is done; the appended entry is fresh)
local before9e = #calls
qf.all("convert")
H.eq(#calls, before9e + 1, "only the appended entry cast")
H.eq(calls[#calls].req.shared_context, "PILOT V2", "inferred exemplar re-harvested from the improved pilot")
answer("P4")

-- explicit beats inferred: pin one, fan out again with a fresh entry
vim.api.nvim_set_current_buf(pb)
qf.set_exemplar(2, 2, false) -- pin whatever is on line 2 now
local pinned = vim.api.nvim_buf_get_lines(pb, 1, 2, false)[1]
vim.fn.setqflist({}, "a", { items = { { bufnr = pb, lnum = 2, text = "e" } } })
-- line-2 entry overlaps nothing settled? it's fresh; cast it
local before9e2 = #calls
qf.all("convert")
if #calls > before9e2 then
  H.eq(calls[#calls].req.shared_context, pinned, "explicit exemplar beats the inferred one")
  answer(pinned)
end

-- 9f) :ConjureRejectAll unwinds the batch: queued never cast, running
-- killed, applied reverted byte-identical.
qf._reset()
calls = {}
local rb = {}
local ritems = {}
for i = 1, 4 do
  rb[i] = buf_with({ "orig" .. i })
  ritems[i] = { bufnr = rb[i], lnum = 1, text = "r" .. i }
end
vim.fn.setqflist({}, " ", { items = ritems })
qf.all("go") -- k=2: sites 1,2 running; 3,4 queued
H.eq(pending_calls(), 2, "two in flight")
answer("DONE1") -- site1 done; site3 starts
H.eq(#calls, 3, "third site launched")
qf.reject_all()
H.eq(vim.api.nvim_buf_get_lines(rb[1], 0, 1, false)[1], "orig1", "applied site reverted byte-identical")
H.eq(calls[2].cancelled, true, "running site 2's request was killed")
H.eq(calls[3].cancelled, true, "running site 3's request was killed")
H.eq(#calls, 3, "queued site 4 was never cast")
H.eq(vim.api.nvim_buf_get_lines(rb[4], 0, 1, false)[1], "orig4", "queued site's buffer untouched")
-- a re-run after batch reject casts nothing (rejected is settled)
qf.all("go")
H.eq(#calls, 3, "re-run after reject-all casts nothing")

-- ADJACENT-ROW REGRESSION: reverting row N (a same-count line replace)
-- collapses a left-gravity extmark anchored on row N+1 onto row N — so a
-- batch revert of adjacent sites tracked by extmarks writes both snapshots
-- into the same row. Site rows must come from the qf entry's own hidden
-- marks, which survive the replace. (Found by the demo smoke, pinned here.)
qf._reset()
calls = {}
local adj = buf_with({ "head", "alpha", "beta", "tail" })
vim.fn.setqflist({}, " ", {
  items = { { bufnr = adj, lnum = 2, text = "a" }, { bufnr = adj, lnum = 3, text = "b" } },
})
qf.all("go") -- same buffer: serialized
answer("ALPHA")
answer("BETA")
H.eq(table.concat(vim.api.nvim_buf_get_lines(adj, 0, -1, false), ","), "head,ALPHA,BETA,tail", "both applied")
qf.reject_all()
H.eq(
  table.concat(vim.api.nvim_buf_get_lines(adj, 0, -1, false), ","),
  "head,alpha,beta,tail",
  "adjacent sites both reverted to their own rows"
)

-- 9g) treesitter region expansion: a bare entry on a multi-line statement's
-- first line casts the whole statement; explicit ranges and no-parser
-- buffers stay as-is; expansion feeds overlap detection.
qf._reset()
calls = {}
local ts_src = {
  "local M = {}", -- 1
  "function M.fetch(id)", -- 2
  "  local res = http.get(", -- 3
  "    '/users/' .. id,", -- 4
  "    { timeout = 5 }", -- 5
  "  )", -- 6
  "  return res.body", -- 7
  "end", -- 8
}
local tsb = vim.api.nvim_create_buf(false, false)
vim.api.nvim_buf_set_lines(tsb, 0, -1, false, ts_src)
vim.bo[tsb].filetype = "lua"
vim.api.nvim_set_current_buf(tsb)
vim.fn.setqflist({}, " ", { items = { { bufnr = tsb, lnum = 3, text = "call" } } })
qf.all("rewrite")
H.eq(
  calls[#calls].req.text,
  table.concat({ ts_src[3], ts_src[4], ts_src[5], ts_src[6] }, "\n"),
  "bare entry expanded to the whole multi-line call (lines 3-6)"
)
answer("  local res = fetch_users(id)")
H.eq(vim.api.nvim_buf_get_lines(tsb, 2, 3, false)[1], "  local res = fetch_users(id)", "whole call replaced")
H.eq(vim.api.nvim_buf_get_lines(tsb, 3, 4, false)[1], "  return res.body", "following line intact (4 lines became 1)")

-- explicit end_lnum is authoritative (never expanded)
qf._reset()
calls = {}
local tsb2 = vim.api.nvim_create_buf(false, false)
vim.api.nvim_buf_set_lines(tsb2, 0, -1, false, ts_src)
vim.bo[tsb2].filetype = "lua"
vim.fn.setqflist({}, " ", { items = { { bufnr = tsb2, lnum = 3, end_lnum = 4, text = "range" } } })
qf.all("rewrite")
H.eq(calls[#calls].req.text, ts_src[3] .. "\n" .. ts_src[4], "explicit end_lnum used verbatim")
answer(ts_src[3] .. "\n" .. ts_src[4])

-- no parser (no filetype) falls back to the line
qf._reset()
calls = {}
local plain = buf_with({ "just a line", "another" })
vim.fn.setqflist({}, " ", { items = { { bufnr = plain, lnum = 1, text = "x" } } })
qf.all("go")
H.eq(calls[#calls].req.text, "just a line", "no parser: single line")
answer("ok")

-- region_expand = false disables expansion
require("conjurer").setup({ region_expand = false })
qf._reset()
calls = {}
local tsb3 = vim.api.nvim_create_buf(false, false)
vim.api.nvim_buf_set_lines(tsb3, 0, -1, false, ts_src)
vim.bo[tsb3].filetype = "lua"
vim.fn.setqflist({}, " ", { items = { { bufnr = tsb3, lnum = 3, text = "call" } } })
qf.all("rewrite")
H.eq(calls[#calls].req.text, ts_src[3], "region_expand = false: line only")
answer(ts_src[3])
require("conjurer").setup({ region_expand = true })

-- expansion feeds overlap detection: function-line entry swallows the inner
-- call-line entry
qf._reset()
calls = {}
local tsb4 = vim.api.nvim_create_buf(false, false)
vim.api.nvim_buf_set_lines(tsb4, 0, -1, false, ts_src)
vim.bo[tsb4].filetype = "lua"
vim.fn.setqflist({}, " ", {
  items = { { bufnr = tsb4, lnum = 2, text = "fn" }, { bufnr = tsb4, lnum = 3, text = "call" } },
})
qf.all("rewrite")
H.eq(#calls, 1, "inner entry skipped: its expanded region overlaps the function entry's")
answer(table.concat({ "function M.fetch(id)", "end" }, "\n"))

-- 10) review = true does NOT open review tabs for driver-run casts: the
-- driver owns per-site review; N casts must not become N tabpages. (This
-- rule was born in the review+aggregate merge — pin it.)
qf._reset()
calls = {}
require("conjurer").setup({ review = true })
local rv = buf_with({ "r1", "r2" })
vim.api.nvim_set_current_buf(rv)
vim.fn.setqflist({}, " ", { items = { { bufnr = rv, lnum = 1, text = "a" }, { bufnr = rv, lnum = 2, text = "b" } } })
local tabs_before = #vim.api.nvim_list_tabpages()
qf.all("go")
answer("R1!")
answer("R2!")
H.eq(#vim.api.nvim_list_tabpages(), tabs_before, "no review tabs opened for driven casts despite review=true")
H.eq(vim.api.nvim_buf_get_lines(rv, 0, 1, false)[1], "R1!", "driven cast auto-applied under review=true")
require("conjurer").setup({ review = false })

-- 11) integration with quickfix.pro — only when the sibling checkout exists
-- next to this repo. Keeps conjure's own CI green without it.
local repo = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
local sibling = vim.fn.fnamemodify(repo, ":h") .. "/quickfix"
if vim.fn.isdirectory(sibling) == 1 then
  vim.opt.rtp:prepend(sibling)
  vim.cmd("runtime! plugin/quickfix-pro.lua")
  local status_ns = require("quickfix-pro.render").status_ns

  -- status decorations render for the driver's sites.
  qf._reset()
  calls = {}
  local ib = buf_with({ "s1", "s2" })
  vim.api.nvim_set_current_buf(ib)
  vim.fn.setqflist({}, " ", { items = { { bufnr = ib, lnum = 1, text = "a" }, { bufnr = ib, lnum = 2, text = "b" } } })
  vim.cmd("copen")
  local qfbuf = vim.api.nvim_win_get_buf(vim.fn.getqflist({ winid = 1 }).winid)
  qf.all("go")
  vim.wait(1000, function()
    return #vim.api.nvim_buf_get_extmarks(qfbuf, status_ns, 0, -1, {}) >= 1
  end, 5)
  local decorated = #vim.api.nvim_buf_get_extmarks(qfbuf, status_ns, 0, -1, {})
  if decorated < 1 then
    H.fail("quickfix.pro rendered no status decorations for driver sites")
  end

  -- dd on an in-flight row cancels the cast (no edit lands) via on_delete.
  -- Row 1's site is running; delete it before answering.
  vim.api.nvim_set_current_win(vim.fn.getqflist({ winid = 1 }).winid)
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  require("quickfix-pro.actions").delete_current()
  vim.wait(1000, function()
    return #vim.fn.getqflist({ items = 1 }).items == 1
  end, 5)
  H.eq(#vim.fn.getqflist({ items = 1 }).items, 1, "dd removed the in-flight row")
  -- the cancelled cast's provider handle was told to cancel
  local any_cancelled = false
  for _, c in ipairs(calls) do
    if c.cancelled then
      any_cancelled = true
    end
  end
  if not any_cancelled then
    H.fail("dd did not cancel the in-flight cast via on_delete")
  end
  -- answering the surviving site still applies
  answer("S2!")
  H.eq(vim.api.nvim_buf_get_lines(ib, 1, 2, false)[1], "S2!", "surviving site still conjures after the delete")
  H.eq(vim.api.nvim_buf_get_lines(ib, 0, 1, false)[1], "s1", "cancelled site's line is unchanged")
  vim.cmd("cclose")
  print("(quickfix.pro integration checks ran)")
else
  print("(quickfix.pro sibling not found — integration checks skipped)")
end

H.done("aggregate_spec PASS")
