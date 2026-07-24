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

-- Resolve the oldest un-answered call with `result` (or an error).
local function answer(result, err)
  for _, c in ipairs(calls) do
    if not c.done then
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

H.done("aggregate_spec PASS")
