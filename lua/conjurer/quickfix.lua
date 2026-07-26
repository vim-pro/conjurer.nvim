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

-- The applied region's current start row (a point extmark anchored at the
-- region start; it tracks edits made above it), or nil if lost.
local function site_row(site)
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
-- casting
-- ---------------------------------------------------------------------------

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
        return { kind = "line", srow = e.lnum - 1, erow = (e.end_lnum ~= 0 and e.end_lnum or e.lnum) }, e.text
      end
      return nil
    end
  end
  return nil
end

-- Kick off one site's cast and, when it settles, invoke `next_fn` to pull the
-- following eligible site off the queue.
local function cast_site(site, intent, next_fn)
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

  handle = operator.conjure_region(site.buf, region, intent, {
    note = note,
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

  local queue = {}
  local accepted = {} -- per-buffer accepted regions, for overlap detection
  for i, entry in ipairs(list.items) do
    if entry.valid ~= 0 and entry.bufnr and entry.bufnr > 0 and entry.lnum and entry.lnum > 0 then
      local s = site_of_entry(entry)
      local castable = not s or s.state == "pending" or s.state == "failed"
      if castable then
        local srow = entry.lnum - 1
        local erow = (entry.end_lnum ~= 0 and entry.end_lnum or entry.lnum)
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
