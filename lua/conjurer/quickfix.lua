-- Aggregate conjuring: cast a shared intent over every site in the quickfix
-- list. The native list stays the store; each entry carries only a site id in
-- user_data, and the live per-site state (in flight, applied, ...) lives in a
-- driver-side table so status changes never have to write the list. When
-- quickfix.pro is installed those states render as row decorations; without
-- it, everything still works — the edits just land unadorned.
local M = {}

local operator = require("conjurer.operator")

local ns = vim.api.nvim_create_namespace("conjurer.aggregate")

-- sites[id] = { id, buf, kind, region, snapshot(str[]), state, err, extmark,
--               cancel, intent }
-- state: "pending" | "running" | "done" | "failed" | "skipped" | "rejected"
local sites = {}
local next_id = 0
local last_intent = nil

-- The stamped-entry marker: entry.user_data = { conjurer = { site = <id> } }.
local function site_of_entry(entry)
  local ud = entry.user_data
  local id = type(ud) == "table" and type(ud.conjurer) == "table" and ud.conjurer.site
  return id and sites[id] or nil
end

-- ---------------------------------------------------------------------------
-- quickfix.pro integration (optional both ways)
-- ---------------------------------------------------------------------------

-- A skipped site gets the conjure key itself, in warning yellow: the cast ran
-- (or was never worth running) and deliberately left the text alone — worth
-- noticing, unlike a plain no-op, but not a failure.
local ICON =
  { pending = "·", running = "…", done = "✓", failed = "✗", skipped = "~", rejected = "⊘" }
local HL = {
  pending = "Comment",
  running = "DiagnosticInfo",
  done = "DiagnosticOk",
  failed = "DiagnosticError",
  skipped = "DiagnosticWarn",
  rejected = "DiagnosticWarn",
}

local registered = false

-- The applied region's current start row (0-based). The quickfix list's own
-- hidden marks are the robust tracker: a same-count line REPLACE (what a
-- revert of the row above does) collapses an adjacent left-gravity extmark
-- onto the replaced row, but the entry's lnum tracks it correctly — verified
-- empirically. So the entry is the primary source; the site's extmark is
-- only the fallback for a site whose entry has left the list.
local function site_row(site)
  if site.qf_id then
    local list = vim.fn.getqflist({ id = site.qf_id, items = 1 })
    for _, e in ipairs(list.items) do
      local ud = e.user_data
      if type(ud) == "table" and type(ud.conjurer) == "table" and ud.conjurer.site == site.id then
        if e.lnum and e.lnum > 0 then
          return e.lnum - 1
        end
        break
      end
    end
  end
  if not site.extmark or not vim.api.nvim_buf_is_valid(site.buf) then
    return nil
  end
  local m = vim.api.nvim_buf_get_extmark_by_id(site.buf, ns, site.extmark, {})
  return m and m[1] or nil
end

-- Current text of a site's applied region (start row + applied line count).
local function current_text(site)
  local row = site_row(site)
  if not row then
    return nil
  end
  local n = site.applied_count or #site.snapshot
  local ok, lines = pcall(vim.api.nvim_buf_get_lines, site.buf, row, row + n, false)
  return ok and lines or nil
end

local function ensure_registered()
  if registered then
    return
  end
  local ok, qfpro = pcall(require, "quickfix-pro")
  if not ok then
    return
  end
  registered = true
  qfpro.register("conjurer", {
    status = function(entry)
      local s = site_of_entry(entry)
      if not s then
        return nil
      end
      return {
        icon = ICON[s.state],
        hl = HL[s.state],
        eol = s.state == "failed" and s.err or nil,
      }
    end,
    expand = function(entry)
      local s = site_of_entry(entry)
      if not s or s.state == "pending" or s.state == "running" then
        return nil
      end
      local chunks = {}
      for _, line in ipairs(s.snapshot) do
        chunks[#chunks + 1] = { { "- " .. line, "DiffDelete" } }
      end
      for _, line in ipairs(current_text(s) or {}) do
        chunks[#chunks + 1] = { { "+ " .. line, "DiffAdd" } }
      end
      return chunks
    end,
    on_delete = function(entries)
      for _, e in ipairs(entries) do
        local s = site_of_entry(e)
        if s and s.cancel then
          s.cancel()
        end
      end
      return true
    end,
  })
end

local function refresh()
  local ok, qfpro = pcall(require, "quickfix-pro")
  if ok then
    qfpro.refresh()
  end
end

-- ---------------------------------------------------------------------------
-- list context: the exemplar lives with the list it applies to
-- ---------------------------------------------------------------------------

-- The quickfix list context is shared state (other plugins may keep their own
-- keys in it), so every write is a read-modify-write that touches only
-- context.conjurer.
local function update_conjurer_context(qf_id, fn)
  local ctx = vim.fn.getqflist({ id = qf_id, context = 1 }).context
  if type(ctx) ~= "table" then
    ctx = {}
  end
  ctx.conjurer = type(ctx.conjurer) == "table" and ctx.conjurer or {}
  fn(ctx.conjurer)
  vim.fn.setqflist({}, "a", { id = qf_id, context = ctx })
end

-- The list's exemplar: { text, inferred }, or nil.
local function get_exemplar(qf_id)
  local ctx = vim.fn.getqflist({ id = qf_id, context = 1 }).context
  local ex = type(ctx) == "table" and type(ctx.conjurer) == "table" and ctx.conjurer.exemplar
  if type(ex) == "table" and type(ex.text) == "string" then
    return ex
  end
  return nil
end

--- :ConjureExemplar — pin, clear, or show the current list's exemplar. With
--- a range, the range's lines (from the current buffer) become the explicit
--- exemplar: a finished example every site's cast is asked to match. With
--- !, clear it (explicit or inferred). Bare, echo what's in effect.
---@param first integer? 1-based range start (nil = no range given)
---@param last integer?
---@param bang boolean
function M.set_exemplar(first, last, bang)
  local list = vim.fn.getqflist({ id = 0 })
  if bang then
    update_conjurer_context(list.id, function(c)
      c.exemplar = nil
    end)
    refresh()
    vim.notify("[conjurer] exemplar cleared")
    return
  end
  if first then
    local lines = vim.api.nvim_buf_get_lines(0, first - 1, last, false)
    update_conjurer_context(list.id, function(c)
      c.exemplar = { text = table.concat(lines, "\n"), inferred = false }
    end)
    vim.notify(("[conjurer] exemplar set (%d line%s)"):format(#lines, #lines == 1 and "" or "s"))
    return
  end
  local ex = get_exemplar(list.id)
  if not ex then
    vim.notify("[conjurer] no exemplar (pin one with :{range}ConjureExemplar, or cast a pilot site)")
  else
    vim.notify(("[conjurer] exemplar (%s):\n%s"):format(ex.inferred and "inferred from pilot site" or "explicit", ex.text))
  end
end

-- ---------------------------------------------------------------------------
-- casting
-- ---------------------------------------------------------------------------

-- Grep gives a match POINT; the edit unit is usually the enclosing
-- multi-line structure. Expand a bare entry line to the smallest named
-- treesitter node that STARTS on that line and spans multiple lines — the
-- multi-line call gets fully edited, while the rule stays conservative:
-- a mid-expression line (where nothing starts) stays a single line, and
-- "smallest" never swallows an enclosing block. Returns 1-based inclusive
-- first/last lines; falls back to the line itself without a parser.
local function expand_region(buf, lnum)
  if require("conjurer").config.region_expand == false then
    return lnum, lnum
  end
  if not vim.api.nvim_buf_is_loaded(buf) then
    return lnum, lnum
  end
  local ok, parser = pcall(vim.treesitter.get_parser, buf)
  if not ok or not parser then
    return lnum, lnum
  end
  local ok2, trees = pcall(function()
    return parser:parse()
  end)
  if not ok2 or not trees or not trees[1] then
    return lnum, lnum
  end

  local srow = lnum - 1
  local best_end -- 0-based inclusive end row of the smallest multi-line node
  local function walk(node)
    for child in node:iter_children() do
      local sr, _, er, ec = child:range()
      if sr > srow then
        break -- siblings are ordered; nothing later can start on our line
      end
      local endr = (ec == 0 and er - 1 or er)
      if child:named() and sr == srow and endr > sr then
        if not best_end or endr < best_end then
          best_end = endr
        end
      end
      if endr >= srow then
        walk(child)
      end
    end
  end
  walk(trees[1]:root())

  if best_end then
    return lnum, best_end + 1
  end
  return lnum, lnum
end

-- Normalize a result the way apply() does (trailing blank line dropped) so a
-- model that returns the snippet unchanged is detected as a no-op.
local function normalize(result)
  local lines = vim.split(result, "\n", { plain = true })
  if lines[#lines] == "" then
    table.remove(lines)
  end
  return table.concat(lines, "\n")
end

-- The current linewise region for a site, from its (auto-adjusted) quickfix
-- entry — recomputed at launch time so a prior cast in the same file that
-- changed line counts doesn't leave this site's region stale. Also returns
-- the entry's text: for :make/diagnostic lists that's the message that
-- flagged the site, which the model should see.
local function region_for_site(site)
  local list = vim.fn.getqflist({ id = site.qf_id, items = 1 })
  for _, e in ipairs(list.items) do
    local ud = e.user_data
    if type(ud) == "table" and type(ud.conjurer) == "table" and ud.conjurer.site == site.id then
      if e.bufnr and e.bufnr > 0 and e.lnum and e.lnum > 0 then
        local erow
        if e.end_lnum ~= 0 then
          erow = e.end_lnum -- an explicit range (:QfAdd, range-aware tools) is authoritative
        else
          local _, last = expand_region(e.bufnr, e.lnum)
          erow = last
        end
        return { kind = "line", srow = e.lnum - 1, erow = erow }, e.text
      end
      return nil
    end
  end
  return nil
end

-- Kick off one site's cast and, when it settles, invoke `next_fn` to pull the
-- following eligible site off the queue.
local function cast_site(site, intent, next_fn)
  -- A site that settled (or was rejected) while queued must not cast — this
  -- is what makes :ConjureRejectAll safe mid-batch.
  if site.state ~= "pending" then
    return next_fn()
  end
  if not vim.api.nvim_buf_is_valid(site.buf) then
    site.state = "failed"
    site.err = "buffer gone"
    refresh()
    return next_fn()
  end
  if not vim.api.nvim_buf_is_loaded(site.buf) then
    pcall(vim.fn.bufload, site.buf)
  end

  local region, entry_text = region_for_site(site)
  if not region then
    site.state = "failed"
    site.err = "entry lost from the list"
    refresh()
    return next_fn()
  end
  site.region = region

  -- Anchor the region start so reject/expand can find the applied text later
  -- even if a subsequent same-file cast shifts lines above it. The extent is
  -- the applied line count (set in on_done), not a growing end mark — an
  -- end-of-line end mark would absorb later edits and drift.
  if site.extmark then
    pcall(vim.api.nvim_buf_del_extmark, site.buf, ns, site.extmark) -- re-cast: drop the stale anchor
  end
  site.extmark = vim.api.nvim_buf_set_extmark(site.buf, ns, region.srow, 0, { right_gravity = false })
  site.snapshot = vim.api.nvim_buf_get_lines(site.buf, region.srow, region.erow, false)
  site.applied_count = #site.snapshot

  site.state = "running"
  refresh()

  local settled = false
  local handle
  site.cancel = function()
    if settled or site.state ~= "running" then
      return
    end
    settled = true
    if handle then
      handle.cancel() -- abort the operator cast: no splice, no on_done
    end
    site.state = "skipped"
    refresh()
    next_fn()
  end

  -- Pass the entry's message to the model only when it says something the
  -- snippet doesn't: for grep-style lists the text IS the matched line
  -- (redundant), for :make/diagnostic lists it's the error that flagged
  -- the site (essential).
  local note
  if entry_text and vim.trim(entry_text) ~= vim.trim(site.snapshot[1] or "") then
    note = entry_text
  end

  -- A one-shot retry payload (set by retry_site): the model revises its own
  -- rejected draft instead of starting over.
  local retry = site.retry
  site.retry = nil

  -- The list's exemplar, read fresh each cast so :ConjureAll, :ConjureNext
  -- and :ConjureRetrySite all pick it up uniformly.
  local exemplar = get_exemplar(site.qf_id)

  handle = operator.conjure_region(site.buf, region, intent, {
    note = note,
    shared_context = exemplar and exemplar.text or nil,
    previous_attempt = retry and retry.previous_attempt or nil,
    feedback = retry and retry.feedback or nil,
    on_done = function(err, result)
      if settled then
        return
      end
      settled = true
      if err then
        site.state = "failed"
        site.err = err
      elseif result and normalize(result) == table.concat(site.snapshot, "\n") then
        site.state = "skipped"
      else
        site.state = "done"
        site.applied_count = #vim.split(normalize(result), "\n", { plain = true })
      end
      refresh()
      next_fn()
    end,
  })
end

-- Drain the worklist with at most `k` casts in flight GLOBALLY and at most one
-- per buffer. Same-file sites serialize (so one cast's splice can't disturb
-- another's still-pending region mark); sites in different files run in
-- parallel up to the cap.
local function run_queue(queue, intent, k)
  local running = 0
  local busy = {} -- busy[buf] = true while a cast in that buffer is in flight
  local function pump()
    while running < k do
      local picked
      for _, s in ipairs(queue) do
        if not s.started and not busy[s.buf] then
          picked = s
          break
        end
      end
      if not picked then
        return
      end
      picked.started = true
      busy[picked.buf] = true
      running = running + 1
      cast_site(picked, intent, function()
        running = running - 1
        busy[picked.buf] = nil
        pump()
      end)
    end
  end
  pump()
end

-- Two linewise regions in the same buffer overlap?
local function overlaps(a, b)
  return a.srow < b.erow and b.srow < a.erow
end

-- ---------------------------------------------------------------------------
-- public entry points
-- ---------------------------------------------------------------------------

--- Conjure `intent` over every eligible entry in the current quickfix list.
--- Idempotent: only entries with no site yet, or a pending/failed one, are
--- cast (a re-run picks up newly added or previously failed sites).
---@param intent string
function M.all(intent)
  if not intent or intent == "" then
    intent = last_intent
    if not intent then
      vim.notify("[conjurer] no previous intent to reuse", vim.log.levels.WARN)
      return
    end
  end
  last_intent = intent
  operator.remember_intent(intent)
  ensure_registered()

  local list = vim.fn.getqflist({ id = 0, items = 1 })
  if #list.items == 0 then
    vim.notify("[conjurer] quickfix list is empty", vim.log.levels.WARN)
    return
  end

  -- Exemplar harvest: an explicit exemplar stays pinned, but otherwise the
  -- first settled pilot site's LIVE text (hand-edits included) becomes the
  -- exemplar for this fan-out. The pilot workflow is :ConjureNext → judge,
  -- fix → :ConjureAll; running the fan-out is the confirmation act. The
  -- model's first draft alone never seeds the convention — the text has to
  -- have passed through the user's hands-on-the-list review to get here.
  local ex = get_exemplar(list.id)
  if not ex or ex.inferred then
    for _, entry in ipairs(list.items) do
      local s = site_of_entry(entry)
      if s and s.state == "done" then
        local row = site_row(s)
        if row then
          local ok, cur = pcall(vim.api.nvim_buf_get_lines, s.buf, row, row + (s.applied_count or #s.snapshot), false)
          if ok then
            update_conjurer_context(list.id, function(c)
              c.exemplar = { text = table.concat(cur, "\n"), inferred = true }
            end)
          end
        end
        break
      end
    end
  end

  local queue = {}
  local accepted = {} -- per-buffer accepted regions, for overlap detection
  for i, entry in ipairs(list.items) do
    if entry.valid ~= 0 and entry.bufnr and entry.bufnr > 0 and entry.lnum and entry.lnum > 0 then
      local s = site_of_entry(entry)
      local castable = not s or s.state == "pending" or s.state == "failed"
      if castable then
        -- Every eligible buffer is about to be edited anyway; loading it now
        -- lets region expansion (and overlap detection over the expanded
        -- regions) see real syntax instead of a bare line.
        if not vim.api.nvim_buf_is_loaded(entry.bufnr) then
          pcall(vim.fn.bufload, entry.bufnr)
        end
        local srow = entry.lnum - 1
        local erow
        if entry.end_lnum ~= 0 then
          erow = entry.end_lnum -- explicit ranges are authoritative, never expanded
        else
          local _, last = expand_region(entry.bufnr, entry.lnum)
          erow = last
        end
        local region = { kind = "line", srow = srow, erow = erow }

        accepted[entry.bufnr] = accepted[entry.bufnr] or {}
        local clash = false
        for _, r in ipairs(accepted[entry.bufnr]) do
          if overlaps(region, r) then
            clash = true
            break
          end
        end

        if not s then
          next_id = next_id + 1
          s = { id = next_id, intent = intent }
          sites[next_id] = s
          entry.user_data = entry.user_data or {}
          entry.user_data.conjurer = { site = next_id }
        end
        s.buf, s.kind, s.qf_id, s.started = entry.bufnr, "line", list.id, false

        if clash then
          s.state = "skipped"
          s.err = "overlaps another site"
        else
          s.state = "pending"
          table.insert(accepted[entry.bufnr], region)
          table.insert(queue, s)
        end
      end
    end
  end

  -- Persist the site stamps (the one and only list write).
  vim.fn.setqflist({}, "r", { id = list.id, items = list.items })
  refresh()

  if #queue == 0 then
    vim.notify("[conjurer] nothing to conjure (all sites settled or skipped)")
    return
  end
  local k = require("conjurer").config.max_concurrent or 4
  run_queue(queue, intent, k)
end

-- Resolve the site for the entry under the cursor (in a qf window) or the
-- current quickfix entry otherwise.
local function site_under_cursor()
  local win = vim.api.nvim_get_current_win()
  local info = vim.fn.getwininfo(win)[1]
  local list = vim.fn.getqflist({ id = 0, items = 1, idx = 0 })
  local row = (info and info.quickfix == 1) and vim.api.nvim_win_get_cursor(win)[1] or list.idx
  local entry = list.items[row]
  return entry and site_of_entry(entry) or nil, list.id
end

--- Conjure just the current quickfix entry, then advance to the next.
---@param intent string?
function M.next(intent)
  if not intent or intent == "" then
    intent = last_intent
    if not intent then
      vim.notify("[conjurer] no intent — run :ConjureAll first or pass one", vim.log.levels.WARN)
      return
    end
  end
  last_intent = intent
  operator.remember_intent(intent)
  ensure_registered()

  local win = vim.api.nvim_get_current_win()
  local info = vim.fn.getwininfo(win)[1]
  local list = vim.fn.getqflist({ id = 0, items = 1, idx = 0 })
  local row = (info and info.quickfix == 1) and vim.api.nvim_win_get_cursor(win)[1] or list.idx
  local entry = list.items[row]
  if not entry or entry.valid == 0 or not entry.bufnr or entry.bufnr == 0 then
    vim.notify("[conjurer] no castable entry here", vim.log.levels.WARN)
    return
  end

  local s = site_of_entry(entry)
  if not s then
    next_id = next_id + 1
    s = { id = next_id, intent = intent }
    sites[next_id] = s
    entry.user_data = entry.user_data or {}
    entry.user_data.conjurer = { site = next_id }
    vim.fn.setqflist({}, "r", { id = list.id, items = list.items })
  end
  s.buf = entry.bufnr
  s.kind = "line"
  s.qf_id = list.id
  s.state = "pending"

  cast_site(s, intent, function() end)

  -- Advance the current entry so a repeated :ConjureNext walks the list.
  local nextrow = math.min(row + 1, #list.items)
  vim.fn.setqflist({}, "a", { idx = nextrow })
  refresh()
end

-- Put a site's original snapshot back at its tracked position. Returns true
-- on success.
local function revert_site(s)
  local row = site_row(s)
  if not row then
    return false
  end
  local n = s.applied_count or #s.snapshot
  local ok = pcall(vim.api.nvim_buf_set_lines, s.buf, row, row + n, false, s.snapshot)
  if ok then
    s.applied_count = #s.snapshot
  end
  return ok
end

--- Revert the site under the cursor back to its pre-conjure snapshot.
function M.reject()
  local s = site_under_cursor()
  if not s then
    vim.notify("[conjurer] no conjured site here", vim.log.levels.WARN)
    return
  end
  if s.state == "running" and s.cancel then
    s.cancel()
    return
  end
  if not revert_site(s) then
    vim.notify("[conjurer] nothing to revert", vim.log.levels.WARN)
    return
  end
  s.state = "rejected"
  refresh()
end

--- Re-conjure the site under the cursor: the model sees its own applied
--- draft (as it currently reads, hand-edits included) plus your feedback,
--- and revises rather than starting over. The site reverts to its original
--- text while the retry is in flight.
---@param feedback string?
function M.retry_site(feedback)
  local s = site_under_cursor()
  if not s then
    vim.notify("[conjurer] no conjured site here", vim.log.levels.WARN)
    return
  end
  if s.state ~= "done" then
    vim.notify(
      "[conjurer] only an applied (done) site can be retried — re-run :ConjureAll for failed ones",
      vim.log.levels.WARN
    )
    return
  end

  local function go(fb)
    local row = site_row(s)
    if not row then
      vim.notify("[conjurer] site was lost", vim.log.levels.WARN)
      return
    end
    local n = s.applied_count or #s.snapshot
    local ok, current = pcall(vim.api.nvim_buf_get_lines, s.buf, row, row + n, false)
    if not ok then
      vim.notify("[conjurer] site was lost", vim.log.levels.WARN)
      return
    end
    local previous_attempt = table.concat(current, "\n")
    if not revert_site(s) then
      vim.notify("[conjurer] could not revert the site for retry", vim.log.levels.WARN)
      return
    end
    s.retry = { previous_attempt = previous_attempt, feedback = fb }
    s.state = "pending"
    refresh()
    cast_site(s, s.intent or last_intent, function() end)
  end

  if feedback == nil or feedback == "" then
    vim.ui.input({ prompt = "Feedback: " }, function(fb)
      if fb and fb ~= "" then
        go(fb)
      end
    end)
  else
    go(feedback)
  end
end

--- The batch undo: unwind every site. Queued sites are dropped before
--- running ones are cancelled (so the freed slots can't start them), running
--- requests are actually killed, and applied sites revert to their exact
--- pre-conjure text. Failed/skipped/already-rejected sites are left alone.
function M.reject_all()
  local dropped, cancelled, reverted = 0, 0, 0
  -- Pass 1: drop everything still queued, so cancellations below can't pump
  -- the queue into starting them.
  for _, s in pairs(sites) do
    if s.state == "pending" then
      s.state = "rejected"
      dropped = dropped + 1
    end
  end
  -- Pass 2: kill in-flight requests.
  for _, s in pairs(sites) do
    if s.state == "running" and s.cancel then
      s.cancel()
      cancelled = cancelled + 1
    end
  end
  -- Pass 3: revert what already landed.
  for _, s in pairs(sites) do
    if s.state == "done" and revert_site(s) then
      s.state = "rejected"
      reverted = reverted + 1
    end
  end
  refresh()
  if dropped + cancelled + reverted == 0 then
    vim.notify("[conjurer] nothing to reject")
  else
    vim.notify(
      ("[conjurer] batch rejected — %d reverted, %d cancelled, %d never cast"):format(reverted, cancelled, dropped)
    )
  end
end

--- Summary notification (used when quickfix.pro isn't installed to surface
--- progress, and any time the user wants a count).
function M.status()
  local counts = {}
  for _, s in pairs(sites) do
    counts[s.state] = (counts[s.state] or 0) + 1
  end
  local parts = {}
  for _, state in ipairs({ "running", "done", "failed", "skipped", "rejected", "pending" }) do
    if counts[state] then
      parts[#parts + 1] = ("%d %s"):format(counts[state], state)
    end
  end
  vim.notify("[conjurer] " .. (#parts > 0 and table.concat(parts, ", ") or "no sites"))
end

-- Test/reset helper.
function M._reset()
  for id, s in pairs(sites) do
    if s.extmark and vim.api.nvim_buf_is_valid(s.buf) then
      pcall(vim.api.nvim_buf_del_extmark, s.buf, ns, s.extmark)
    end
    sites[id] = nil
  end
  next_id = 0
  last_intent = nil
end

return M
