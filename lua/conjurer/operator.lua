local M = {}

local ns = vim.api.nvim_create_namespace("conjurer")
local flash_ns = vim.api.nvim_create_namespace("conjurer.flash")

vim.api.nvim_set_hl(0, "ConjurerPending", { link = "Comment", default = true })
vim.api.nvim_set_hl(0, "ConjurerNarration", { link = "DiagnosticVirtualTextInfo", default = true })
-- The result as it streams, distinct from the narration above it: one is
-- the model talking about the work and the other is the work.
vim.api.nvim_set_hl(0, "ConjurerPreview", { link = "Comment", default = true })

-- The intent survives between invocations so that `.` (which re-runs the
-- operatorfunc without going through the mapping) reuses it instead of
-- prompting again. :Conjure with no arguments reuses it too.
local current_intent = nil

-- Set by the mappings, cleared by opfunc. Distinguishes a fresh invocation
-- (get a new intent, after the motion is known) from a dot-repeat (reuse the
-- stored intent silently).
local fresh_invocation = false

-- Named register given before the operator ("c~ip): its contents become the
-- intent and no prompt is shown. Captured in arm(), consumed by opfunc.
local pending_register = nil

-- In-flight casts. Each owns one extmark spanning its region (which also
-- carries the pending highlight and the narration virtual lines) and holds a
-- snapshot of the region text for lock enforcement.
---@type table[]
local casts = {}

local next_cast_id = 0
local function new_id()
  next_cast_id = next_cast_id + 1
  return next_cast_id
end

local NARRATION_LINES = 4
-- How much of the streamed result to keep on screen. A window at the tail,
-- because the point is to watch it being written, not to read the whole
-- thing twice — it lands in the buffer the moment it is done.
local PREVIEW_LINES = 8

--- Returns an expr-mapping callback that arms the operator. `followup` is
--- appended to g@ (e.g. "_" for the current-line variant).
function M.arm(followup)
  return function()
    fresh_invocation = true
    local reg = vim.v.register
    pending_register = reg ~= '"' and reg or nil
    vim.o.operatorfunc = "v:lua.require'conjurer.operator'.opfunc"
    return "g@" .. (followup or "")
  end
end

--- :Conjure entry point (linewise, not dot-repeatable). An empty intent
--- reuses the last one, like & reuses the last :s.
function M.run_range(line1, line2, intent)
  if intent == nil or intent == "" then
    intent = current_intent
    if not intent then
      vim.notify("[conjurer] no previous intent to reuse", vim.log.levels.WARN)
      return
    end
  else
    current_intent = intent
  end
  local buf = vim.api.nvim_get_current_buf()
  M.conjure_region(buf, {
    kind = "line",
    srow = line1 - 1,
    erow = line2, -- exclusive
  }, intent)
end

-- Byte length of the UTF-8 character starting at 0-based byte column `col`.
local function char_len_at(line, col)
  local tail = line:sub(col + 1)
  local ch = tail:match("^[%z\1-\127\194-\244][\128-\191]*")
  return ch and #ch or 0
end

--- operatorfunc target; motion_type is "line", "char" or "block".
function M.opfunc(motion_type)
  local was_fresh = fresh_invocation
  fresh_invocation = false
  local reg = pending_register
  pending_register = nil

  if motion_type == "block" then
    vim.notify("[conjurer] blockwise selections are not supported", vim.log.levels.WARN)
    return
  end

  local buf = vim.api.nvim_get_current_buf()
  local smark = vim.api.nvim_buf_get_mark(buf, "[") -- {1-based row, 0-based col}
  local emark = vim.api.nvim_buf_get_mark(buf, "]")

  local region
  if motion_type == "line" then
    region = { kind = "line", srow = smark[1] - 1, erow = emark[1] }
  else
    local start_line = vim.api.nvim_buf_get_lines(buf, smark[1] - 1, smark[1], false)[1] or ""
    local end_line = vim.api.nvim_buf_get_lines(buf, emark[1] - 1, emark[1], false)[1] or ""
    -- '] points at the first byte of the last character; make the col exclusive.
    local ecol = math.min(emark[2] + char_len_at(end_line, emark[2]), #end_line)
    region = {
      kind = "char",
      srow = smark[1] - 1,
      scol = math.min(smark[2], #start_line),
      erow = emark[1] - 1,
      ecol = ecol,
    }
  end

  if not was_fresh then
    -- Dot-repeat: reuse the stored intent, no prompt.
    if current_intent then
      M.conjure_region(buf, region, current_intent)
    end
    return
  end

  if reg then
    -- "c~ip — the register's contents are the intent.
    local intent = (vim.fn.getreg(reg) or ""):gsub("\n+$", "")
    if intent == "" then
      vim.notify(('[conjurer] register "%s is empty'):format(reg), vim.log.levels.WARN)
      return
    end
    current_intent = intent
    M.conjure_region(buf, region, intent)
    return
  end

  -- The motion is known; now ask what to conjure over it. input()'s history
  -- means <Up> recalls previous intents.
  vim.ui.input({ prompt = "Conjure: " }, function(intent)
    if not intent or intent == "" then
      return
    end
    current_intent = intent
    M.conjure_region(buf, region, intent)
  end)
end

local function get_region_text(buf, region)
  if region.kind == "line" then
    return vim.api.nvim_buf_get_lines(buf, region.srow, region.erow, false)
  end
  return vim.api.nvim_buf_get_text(buf, region.srow, region.scol, region.erow, region.ecol, {})
end

-- The buffer's cwd-relative path, for the model's benefit ("" if unnamed).
local function buf_path(buf)
  local name = vim.api.nvim_buf_get_name(buf)
  if name == "" then
    return ""
  end
  return vim.fn.fnamemodify(name, ":.")
end

--- Surrounding context so the model understands the boundary — including,
--- for charwise regions, the partial start/end lines outside the snippet.
local function get_context(buf, region, n)
  local last = vim.api.nvim_buf_line_count(buf)
  local before, after

  if region.kind == "line" then
    before = vim.api.nvim_buf_get_lines(buf, math.max(0, region.srow - n), region.srow, false)
    after = vim.api.nvim_buf_get_lines(buf, region.erow, math.min(last, region.erow + n), false)
  else
    before = vim.api.nvim_buf_get_lines(buf, math.max(0, region.srow - n), region.srow, false)
    local start_line = vim.api.nvim_buf_get_lines(buf, region.srow, region.srow + 1, false)[1] or ""
    table.insert(before, start_line:sub(1, region.scol))

    local end_line = vim.api.nvim_buf_get_lines(buf, region.erow, region.erow + 1, false)[1] or ""
    after = { end_line:sub(region.ecol + 1) }
    vim.list_extend(after, vim.api.nvim_buf_get_lines(buf, region.erow + 1, math.min(last, region.erow + 1 + n), false))
  end

  return table.concat(before, "\n"), table.concat(after, "\n")
end

-- ---------------------------------------------------------------------------
-- Cast lifecycle: one extmark tracks the region and renders the pending
-- highlight plus the narration virtual lines; a buffer-local autocmd keeps
-- the region non-editable by restoring the snapshot whenever it changes.
-- ---------------------------------------------------------------------------

-- What the reader sees of an intent.
--
-- An intent is arbitrary text. Typed at the prompt it is a short phrase, but
-- a caller driving conjurer programmatically can send a great deal more —
-- scry's drafting pass hands over a whole grammar specification, newlines
-- and all. virt_text is ONE line: an embedded newline renders as `^@` and
-- the remainder runs off the right of the window, so a multi-line intent
-- turned the narration into a wall of control characters.
--
-- So the narration shows the intent's FIRST line, with its internal runs of
-- whitespace collapsed, clipped to something that fits. The model still
-- receives the intent whole — this trims what is displayed, never what is
-- sent.
local HEADLINE_MAX = 68
local function headline(intent)
  local first = tostring(intent or ""):match("^[^\r\n]*") or ""
  first = first:gsub("%s+", " "):gsub("^%s", ""):gsub("%s$", "")
  local multiline = tostring(intent or ""):find("[\r\n]") ~= nil
  if vim.fn.strdisplaywidth(first) > HEADLINE_MAX then
    return vim.fn.strcharpart(first, 0, HEADLINE_MAX - 1) .. "…"
  end
  -- A clipped first line already reads as "there is more"; an intent whose
  -- first line fits but has more lines behind it needs to say so itself.
  return multiline and (first .. " …") or first
end

local function narration_virt(cast)
  if cast.state == "reviewing" then
    return { { { " 👀 reviewing: " .. headline(cast.intent), "ConjurerNarration" } } }
  end
  -- ELAPSED, because most of a long cast is silence. Measured against the
  -- real CLI: a request produces nothing for its first few seconds and a
  -- big one for minutes — the model is thinking before it writes a word —
  -- and with nothing moving on screen that is indistinguishable from a
  -- hang. The result does stream once it starts; this is about the part
  -- before it starts.
  local waited = cast.started and math.floor((vim.uv.hrtime() - cast.started) / 1e9) or 0
  local clock = waited > 0 and ("  %d:%02d"):format(math.floor(waited / 60), waited % 60) or ""
  if cast.phase then
    clock = clock .. "  " .. cast.phase .. "…"
  end
  local lines = {
    { { " ✨ conjuring: " .. headline(cast.intent), "ConjurerNarration" }, { clock, "ConjurerPreview" } },
  }
  local n = #cast.narration
  for i = math.max(1, n - NARRATION_LINES + 1), n do
    table.insert(lines, { { "    · " .. cast.narration[i], "ConjurerNarration" } })
  end
  -- The result so far, under the narration. Bounded to a window at the tail
  -- so a long answer scrolls rather than growing without limit — a preview
  -- that fills the screen is the wait it was meant to replace.
  local p = cast.preview and #cast.preview or 0
  for i = math.max(1, p - PREVIEW_LINES + 1), p do
    table.insert(lines, { { "    " .. cast.preview[i], "ConjurerPreview" } })
  end
  return lines
end

--- (Re)place the cast's region extmark. Rows/cols 0-based, end exclusive.
---
--- CLAMPED TO WHAT THE BUFFER ACTUALLY HOLDS, and never fatal. The
--- coordinates come from replaced_extent, which measures the SNAPSHOT — so
--- they describe the text that was put back, not necessarily the text that
--- is there. Undo makes the two disagree: `u` on a locked region fires
--- TextChanged, restore() writes the snapshot and re-anchors, and the
--- buffer is mid-change underneath. That threw `Invalid 'end_col': out of
--- range` out of an autocommand, twice, over a plain undo.
---
--- A region highlight is decoration. Failing to place it must never take
--- down the edit it was decorating, so the clamp is followed by a pcall
--- rather than trusted to be sufficient.
local function place_mark(cast, srow, scol, erow, ecol)
  if not vim.api.nvim_buf_is_valid(cast.buf) then
    return
  end
  local last = vim.api.nvim_buf_line_count(cast.buf) - 1
  srow = math.max(0, math.min(srow, last))
  erow = math.max(srow, math.min(erow, last))
  local function width(row)
    local l = vim.api.nvim_buf_get_lines(cast.buf, row, row + 1, false)[1]
    return #(l or "")
  end
  scol = math.max(0, math.min(scol, width(srow)))
  ecol = math.max(0, math.min(ecol, width(erow)))
  local ok, id = pcall(vim.api.nvim_buf_set_extmark, cast.buf, ns, srow, scol, {
    id = cast.mark,
    end_row = erow,
    end_col = ecol,
    hl_group = "ConjurerPending",
    virt_lines = narration_virt(cast),
    right_gravity = false,
    end_right_gravity = true,
  })
  if ok then
    cast.mark = id
  end
end

--- Current extent of the cast's region: srow, scol, erow, ecol (0-based,
--- end exclusive), or nil if the mark is gone.
local function bounds(cast)
  local m = vim.api.nvim_buf_get_extmark_by_id(cast.buf, ns, cast.mark, { details = true })
  if not m or not m[1] or not m[3] then
    return nil
  end
  return m[1], m[2], m[3].end_row, m[3].end_col
end

--- Where `lines` would end if placed back at (srow, scol), for this cast's kind.
local function replaced_extent(cast, srow, scol, lines)
  local erow = srow + #lines - 1
  local ecol
  if cast.kind == "line" then
    scol = 0
    ecol = #lines[#lines]
  else
    ecol = #lines == 1 and scol + #lines[1] or #lines[#lines]
  end
  return srow, scol, erow, ecol
end

local function region_changed(cast)
  local srow, scol, erow, ecol = bounds(cast)
  if not srow then
    return true
  end
  local ok, lines
  if cast.kind == "line" then
    ok, lines = pcall(vim.api.nvim_buf_get_lines, cast.buf, srow, erow + 1, false)
  else
    ok, lines = pcall(vim.api.nvim_buf_get_text, cast.buf, srow, scol, erow, ecol, {})
  end
  if not ok then
    return true
  end
  return table.concat(lines, "\n") ~= table.concat(cast.snapshot, "\n")
end

--- Put cast.snapshot back at the mark's current bounds and re-anchor it.
--- Returns true on success.
local function revert_to_snapshot(cast)
  local srow, scol, erow, ecol = bounds(cast)
  if not srow then
    return false
  end
  local ok
  if cast.kind == "line" then
    if srow == erow and scol == ecol then
      -- Fully collapsed (the whole region was deleted): insert, don't replace
      -- whatever real line slid into this slot.
      ok = pcall(vim.api.nvim_buf_set_lines, cast.buf, srow, srow, false, cast.snapshot)
    else
      ok = pcall(vim.api.nvim_buf_set_lines, cast.buf, srow, erow + 1, false, cast.snapshot)
    end
  else
    ok = pcall(vim.api.nvim_buf_set_text, cast.buf, srow, scol, erow, ecol, cast.snapshot)
  end
  if not ok then
    return false
  end
  place_mark(cast, replaced_extent(cast, srow, scol, cast.snapshot))
  return true
end

--- Put the snapshot back and re-anchor the mark: the region is not editable
--- while a conjure is in flight.
local function restore(cast)
  if not revert_to_snapshot(cast) then
    return
  end
  if not cast.scolded then
    cast.scolded = true
    vim.notify("[conjurer] region is locked while conjuring (:ConjureCancel to abort)", vim.log.levels.WARN)
  end
end

local function prune()
  for i = #casts, 1, -1 do
    if casts[i].done then
      table.remove(casts, i)
    end
  end
end

local function active_in(buf)
  for _, cast in ipairs(casts) do
    if cast.buf == buf and not cast.done then
      return true
    end
  end
  return false
end

-- Buffers currently watched for edits inside locked regions. on_bytes fires
-- synchronously on every change (unlike TextChanged), but buffer edits are
-- not allowed from inside it — so the actual restore is scheduled.
local watched = {}

local function ensure_lock(buf)
  if watched[buf] then
    return
  end
  watched[buf] = true
  local scheduled = false
  vim.api.nvim_buf_attach(buf, false, {
    on_bytes = function()
      if not active_in(buf) then
        watched[buf] = nil
        return true -- detach
      end
      if scheduled then
        return
      end
      scheduled = true
      vim.schedule(function()
        scheduled = false
        if not vim.api.nvim_buf_is_valid(buf) then
          return
        end
        for _, cast in ipairs(casts) do
          if cast.buf == buf and not cast.done and cast.state == "generating" and region_changed(cast) then
            restore(cast)
          end
        end
      end)
    end,
    on_detach = function()
      watched[buf] = nil
    end,
  })
end

-- retire() needs to tear down an open review, but the review machinery is
-- defined further down alongside the rest of accept/reject/retry.
local close_review

-- begin_review() needs to splice into the real buffer, but splice() is
-- defined further down alongside apply() (its other caller).
local splice

--- Remove a cast's decorations and drop it from the registry.
local function retire(cast)
  cast.done = true
  -- The clock describes a cast in flight; a retired cast is not in flight.
  -- A libuv timer outliving the thing it ticks for is a leak that fires
  -- forever on a buffer nobody is looking at.
  if cast.clock then
    pcall(function()
      cast.clock:stop()
      cast.clock:close()
    end)
    cast.clock = nil
  end
  if cast.review then
    close_review(cast)
  end
  if vim.api.nvim_buf_is_valid(cast.buf) then
    pcall(vim.api.nvim_buf_del_extmark, cast.buf, ns, cast.mark)
  end
  prune()
end

--- A result line, as it arrives. Kept apart from narration: narration is
--- the model talking about the work, and this IS the work — someone
--- watching a page of features get written wants to see the features.
local function preview(cast, line)
  if cast.done then
    return
  end
  cast.preview = cast.preview or {}
  table.insert(cast.preview, (tostring(line):gsub("[\r\n]+", " ")))
  local srow, scol, erow, ecol = bounds(cast)
  if srow then
    place_mark(cast, srow, scol, erow, ecol)
  end
end

local function narrate(cast, line)
  if cast.done then
    return
  end
  -- Same one-line rule as the headline above: a provider chunk carrying a
  -- newline would render as ^@ and drag the rest of the narration off the
  -- window, so it is flattened on the way in.
  table.insert(cast.narration, (tostring(line):gsub("[\r\n]+", " ")))
  local srow, scol, erow, ecol = bounds(cast)
  if srow then
    place_mark(cast, srow, scol, erow, ecol)
  end
end

local function find_cast(id)
  for _, cast in ipairs(casts) do
    if cast.id == id then
      return cast
    end
  end
end

--- Resolve "the cast under review" from the current tabpage's diff marker.
--- Notifies and returns nil if the current tabpage isn't a review tab.
local function current_review_cast()
  local id = vim.t.conjurer_cast
  if not id then
    vim.notify("[conjurer] not a conjurer review tab", vim.log.levels.ERROR)
    return nil
  end
  local cast = find_cast(id)
  if not cast or cast.state ~= "reviewing" then
    vim.notify("[conjurer] this review is no longer active", vim.log.levels.WARN)
    return nil
  end
  return cast
end

-- Never delete cast.buf here — after_win shows the real source buffer, only
-- before_buf is ours to tear down.
close_review = function(cast)
  local r = cast.review
  if not r then
    return
  end
  r.closing = true
  if vim.api.nvim_win_is_valid(r.after_win) then
    pcall(vim.api.nvim_win_close, r.after_win, true)
  end
  if vim.api.nvim_win_is_valid(r.before_win) then
    pcall(vim.api.nvim_win_close, r.before_win, true)
  end
  if vim.api.nvim_buf_is_valid(r.before_buf) then
    pcall(vim.api.nvim_buf_delete, r.before_buf, { force = true })
  end
  cast.review = nil
end

--- Splice `result` into the real buffer right away and open a native diff
--- (new tabpage) comparing a frozen whole-file "before" snapshot against the
--- real, now-patched, freely editable buffer — so the region is no longer
--- locked and the user can look around actual surrounding context while
--- deciding. Reject/retry/cancel undo the splice; accept just stops tracking it.
local function begin_review(cast, result, config)
  local srow, scol, erow, ecol = bounds(cast)
  if not srow then
    vim.notify("[conjurer] region was lost before the response arrived", vim.log.levels.WARN)
    retire(cast)
    return
  end

  local full_before = vim.api.nvim_buf_get_lines(cast.buf, 0, -1, false)

  local ok, fsrow, fscol, ferow, fecol = splice(cast, srow, scol, erow, ecol, result)
  if not ok then
    vim.notify("[conjurer] failed to apply result: " .. fsrow, vim.log.levels.ERROR)
    retire(cast)
    return
  end

  cast.state = "reviewing"
  place_mark(cast, fsrow, fscol, ferow, fecol)

  local filetype = vim.bo[cast.buf].filetype
  local before_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(before_buf, 0, -1, false, full_before)
  vim.bo[before_buf].buftype = "nofile"
  vim.bo[before_buf].bufhidden = "wipe"
  vim.bo[before_buf].swapfile = false
  vim.bo[before_buf].filetype = filetype
  vim.bo[before_buf].modified = false
  pcall(vim.api.nvim_buf_set_name, before_buf, ("conjurer://%d/before"):format(cast.id))

  vim.cmd("tabnew")
  local tabpage = vim.api.nvim_get_current_tabpage()
  local before_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(before_win, before_buf)
  vim.cmd("belowright vsplit")
  local after_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(after_win, cast.buf) -- the REAL buffer, not a copy
  vim.api.nvim_win_set_cursor(after_win, { fsrow + 1, fscol })
  vim.api.nvim_win_call(before_win, function()
    vim.cmd("diffthis")
  end)
  vim.api.nvim_win_call(after_win, function()
    vim.cmd("diffthis")
  end)
  vim.api.nvim_set_current_win(after_win)

  cast.review = {
    before_buf = before_buf,
    before_win = before_win,
    after_win = after_win,
    closing = false,
  }
  vim.t[tabpage].conjurer_cast = cast.id

  vim.api.nvim_create_autocmd("WinClosed", {
    pattern = tostring(before_win) .. "," .. tostring(after_win),
    once = true,
    callback = function()
      -- A single :tabclose can fire this for both windows in one batch,
      -- before either scheduled body below has run — guard synchronously
      -- rather than relying on `once` to dedupe across that batch.
      if not cast.review or cast.review.closing then
        return
      end
      cast.review.closing = true
      vim.notify(
        "[conjurer] review closed without a decision — treated as reject, buffer reverted",
        vim.log.levels.WARN
      )
      -- Deferred: this fires mid-teardown of a window Neovim is still
      -- closing natively; mutating further synchronously from in here is unsafe.
      vim.schedule(function()
        close_review(cast)
        revert_to_snapshot(cast)
        retire(cast)
      end)
    end,
  })
end

--- Cancel every in-flight cast in the current buffer — or, if run from
--- inside a review's diff tab, cancel just that cast.
function M.cancel()
  local buf = vim.api.nvim_get_current_buf()
  local review_id = vim.t.conjurer_cast
  if review_id then
    local cast = find_cast(review_id)
    if cast and cast.state == "reviewing" then
      revert_to_snapshot(cast)
      retire(cast)
      vim.notify("[conjurer] canceled 1 conjure (review discarded)")
    else
      vim.notify("[conjurer] nothing to cancel")
    end
    return
  end

  local n = 0
  for _, cast in ipairs(casts) do
    if cast.buf == buf and not cast.done then
      if cast.state == "generating" and cast.handle and cast.handle.cancel then
        pcall(cast.handle.cancel)
      elseif cast.state == "reviewing" then
        revert_to_snapshot(cast)
      end
      retire(cast)
      n = n + 1
    end
  end
  if n > 0 then
    vim.notify(("[conjurer] canceled %d conjure%s"):format(n, n == 1 and "" or "s"))
  else
    vim.notify("[conjurer] nothing to cancel")
  end
end

--- Set the changed-text marks and flash the new text, mirroring what native
--- operators (and on_yank) do. srow/scol are 0-based; erow/ecol exclusive.
local function mark_and_flash(buf, srow, scol, erow, ecol, config)
  vim.api.nvim_buf_set_mark(buf, "[", srow + 1, scol, {})
  vim.api.nvim_buf_set_mark(buf, "]", erow + 1, math.max(ecol - 1, 0), {})

  local ms = config.flash_ms
  if not ms or ms <= 0 then
    return
  end
  local hl_range = (vim.hl or vim.highlight).range
  hl_range(buf, flash_ns, config.flash_hl or "IncSearch", { srow, scol }, { erow, ecol })
  vim.defer_fn(function()
    if vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_clear_namespace(buf, flash_ns, 0, -1)
    end
  end, ms)
end

--- Splice `result` into cast.buf at (srow,scol)-(erow,ecol) (0-based, end
--- exclusive). Returns ok, and on success the final srow/scol/erow/ecol (or
--- ok=false and an error message).
splice = function(cast, srow, scol, erow, ecol, result)
  local lines = vim.split(result, "\n", { plain = true })
  if cast.kind == "line" then
    -- Drop a trailing blank line so linewise replacements don't grow.
    if lines[#lines] == "" then
      table.remove(lines)
    end
    local ok, err = pcall(vim.api.nvim_buf_set_lines, cast.buf, srow, erow + 1, false, lines)
    if not ok then
      return false, err
    end
    return true, srow, 0, srow + #lines - 1, #(lines[#lines] or "")
  end
  local ok, err = pcall(vim.api.nvim_buf_set_text, cast.buf, srow, scol, erow, ecol, lines)
  if not ok then
    return false, err
  end
  local frow = srow + #lines - 1
  local fcol = #lines == 1 and scol + #lines[1] or #lines[#lines]
  return true, srow, scol, frow, fcol
end

local function apply(cast, result, config)
  local srow, scol, erow, ecol = bounds(cast)
  retire(cast)
  if not srow then
    vim.notify("[conjurer] region was lost before the response arrived", vim.log.levels.WARN)
    return
  end
  local ok, fsrow, fscol, ferow, fecol = splice(cast, srow, scol, erow, ecol, result)
  if not ok then
    vim.notify("[conjurer] failed to apply result: " .. fsrow, vim.log.levels.ERROR)
    return
  end
  mark_and_flash(cast.buf, fsrow, fscol, ferow, fecol, config)
end

--- Call the configured provider for `request`, wiring its completion into
--- either apply() or begin_review() depending on config.review. Shared by
--- the initial cast and by retries (which re-dispatch on the same cast).
--- `on_done(err, result)` (optional) fires once the cast resolves, for
--- callers that sequence work across many casts. A driven cast (on_done
--- present) never opens the review tab: the driver owns per-site review
--- (status decorations + :ConjureRejectSite), and N casts resolving into N
--- tabpages is exactly the failure the aggregate design ruled out.
local function invoke_provider(cast, request, config, on_done)
  local fired = false
  cast.handle = require("conjurer").get_provider()(request, function(err, result)
    if fired or cast.done then
      return -- stale/duplicate callback for a request that already resolved
    end
    fired = true
    if not vim.api.nvim_buf_is_valid(cast.buf) then
      retire(cast)
      if on_done then
        on_done("buffer was closed before the response arrived")
      end
      return
    end
    if err then
      retire(cast)
      vim.notify("[conjurer] " .. err, vim.log.levels.ERROR)
      if on_done then
        on_done(err)
      end
      return
    end
    if config.review and not on_done then
      begin_review(cast, result, config)
    else
      apply(cast, result, config)
      if on_done then
        on_done(nil, result)
      end
    end
  end)
end

--- Re-cast the same region, giving the model its rejected draft (read live,
--- since the user may have hand-adjusted it directly) and the user's
--- feedback so it revises rather than starting over.
local function do_retry(cast, feedback)
  local srow, scol, erow, ecol = bounds(cast)
  local previous_attempt = ""
  if srow then
    local ok, lines
    if cast.kind == "line" then
      ok, lines = pcall(vim.api.nvim_buf_get_lines, cast.buf, srow, erow + 1, false)
    else
      ok, lines = pcall(vim.api.nvim_buf_get_text, cast.buf, srow, scol, erow, ecol, {})
    end
    if ok then
      previous_attempt = table.concat(lines, "\n")
    end
  end

  close_review(cast)
  -- Flip state/narration before reverting: revert_to_snapshot re-places the
  -- mark, and its virt_lines depend on cast.state — flipping after would
  -- leave a stale "reviewing" header for the whole retry generation.
  cast.state = "generating"
  cast.narration = {}
  revert_to_snapshot(cast)

  local rsrow, rscol, rerow, recol = bounds(cast)
  if not rsrow then
    vim.notify("[conjurer] region was lost before the retry could start", vim.log.levels.WARN)
    retire(cast)
    return
  end

  local config = require("conjurer").config
  local region = cast.kind == "line" and { kind = "line", srow = rsrow, erow = rerow + 1 }
    or { kind = "char", srow = rsrow, scol = rscol, erow = rerow, ecol = recol }
  local before, after = get_context(cast.buf, region, config.context_lines)

  local request = {
    config = config,
    intent = cast.intent,
    path = buf_path(cast.buf),
    filetype = vim.bo[cast.buf].filetype,
    text = table.concat(cast.snapshot, "\n"),
    context_before = before,
    context_after = after,
    previous_attempt = previous_attempt,
    feedback = feedback,
  }
  if config.narration then
    request.on_narrate = function(line)
      narrate(cast, line)
    end
    request.on_result = function(line)
      preview(cast, line)
    end
  end
  invoke_provider(cast, request, config)
end

--- Stop reviewing and keep whatever's currently in the buffer (the model's
--- draft, possibly hand-adjusted via do/dp or a direct edit) — nothing left
--- to splice, the real buffer already has it.
function M.accept()
  local cast = current_review_cast()
  if not cast then
    return
  end
  local srow, scol, erow, ecol = bounds(cast)
  retire(cast)
  if srow then
    mark_and_flash(cast.buf, srow, scol, erow, ecol, require("conjurer").config)
  end
end

--- Undo the draft (and any further hand-edits) back to the pre-conjure text.
function M.reject()
  local cast = current_review_cast()
  if not cast then
    return
  end
  revert_to_snapshot(cast)
  retire(cast)
  vim.notify("[conjurer] rejected — buffer unchanged")
end

--- Re-conjure the reviewed region with feedback. With no feedback, prompts
--- for it (history-backed, like the initial intent prompt).
function M.retry(feedback)
  local cast = current_review_cast()
  if not cast then
    return
  end
  if feedback == nil or feedback == "" then
    vim.ui.input({ prompt = "Feedback: " }, function(fb)
      if fb and fb ~= "" then
        do_retry(cast, fb)
      end
    end)
  else
    do_retry(cast, feedback)
  end
end

--- Reuse `intent` as the last-cast intent, so `.` and a bare `~` on a
--- nearby site pick it up. Casts driven directly (e.g. the aggregate driver)
--- call this since they bypass the operator's own intent capture.
---@param intent string
function M.remember_intent(intent)
  current_intent = intent
end

--- Kick off an async conjure over a region: lock it, stream narration into
--- it, splice the result when it lands. `opts.on_done(err, result)` (optional)
--- fires once the cast resolves — after the splice on success, or with an
--- error string on failure — for callers (like the aggregate driver) that
--- sequence work across many casts. `opts.note` (optional) is caller
--- context about the snippet (e.g. the quickfix entry's diagnostic),
--- forwarded to the model. `opts.previous_attempt`/`opts.feedback`
--- (optional, set together) make this cast an iterative refinement: the
--- model sees its rejected draft and the user's feedback.
--- `opts.shared_context` (optional) is a finished exemplar the result
--- should match in style and conventions.
---@param opts { on_done: fun(err: string?, result: string?)?, note: string?, previous_attempt: string?, feedback: string?, shared_context: string? }?
function M.conjure_region(buf, region, intent, opts)
  local config = require("conjurer").config
  local on_done = opts and opts.on_done

  if not vim.bo[buf].modifiable or vim.bo[buf].readonly then
    vim.notify("[conjurer] buffer is not modifiable", vim.log.levels.ERROR)
    if on_done then
      on_done("buffer is not modifiable")
    end
    return
  end

  local snapshot = get_region_text(buf, region)
  local before, after = get_context(buf, region, config.context_lines)

  local cast = {
    id = new_id(),
    buf = buf,
    kind = region.kind,
    intent = intent,
    snapshot = snapshot,
    narration = {},
    state = "generating",
  }

  if region.kind == "line" then
    place_mark(cast, region.srow, 0, region.erow - 1, #(snapshot[#snapshot] or ""))
  else
    place_mark(cast, region.srow, region.scol, region.erow, region.ecol)
  end
  table.insert(casts, cast)
  -- A second-hand for the wait. Cheap, and stopped the moment the cast
  -- settles: nothing here should outlive what it is describing.
  cast.started = vim.uv.hrtime()
  cast.clock = vim.uv.new_timer()
  cast.clock:start(
    1000,
    1000,
    vim.schedule_wrap(function()
      if cast.done or not vim.api.nvim_buf_is_valid(cast.buf) then
        return
      end
      local srow, scol, erow, ecol = bounds(cast)
      if srow then
        place_mark(cast, srow, scol, erow, ecol)
      end
    end)
  )
  ensure_lock(buf)

  local request = {
    config = config,
    intent = intent,
    path = buf_path(buf),
    filetype = vim.bo[buf].filetype,
    text = table.concat(snapshot, "\n"),
    context_before = before,
    context_after = after,
    -- Where the request is ABOUT, when that is not where nvim happens to be
    -- sitting. A caller that names files by repo-relative path (scry drafts a
    -- whole project's worth) is describing them relative to a root, and a
    -- provider that can read files must be standing in the same place or it
    -- reads none of them and answers about nothing.
    cwd = opts and opts.cwd or nil,
    note = opts and opts.note or nil,
    shared_context = opts and opts.shared_context or nil,
    previous_attempt = opts and opts.previous_attempt or nil,
    feedback = opts and opts.feedback or nil,
  }
  if config.narration then
    request.on_narrate = function(line)
      narrate(cast, line)
    end
    request.on_result = function(line)
      preview(cast, line)
    end
    request.on_phase = function(phase)
      cast.phase = phase
      local srow, scol, erow, ecol = bounds(cast)
      if srow then
        place_mark(cast, srow, scol, erow, ecol)
      end
    end
  end

  invoke_provider(cast, request, config, on_done)

  -- A handle so a driver can abort this specific cast: kill the provider and
  -- retire it, so no result is spliced and on_done never fires.
  return {
    cancel = function()
      if cast.done then
        return
      end
      if cast.handle and cast.handle.cancel then
        pcall(cast.handle.cancel)
      end
      retire(cast)
    end,
  }
end

return M
