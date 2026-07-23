local M = {}

local ns = vim.api.nvim_create_namespace("conjurer")
local flash_ns = vim.api.nvim_create_namespace("conjurer.flash")

vim.api.nvim_set_hl(0, "ConjurerPending", { link = "Comment", default = true })
vim.api.nvim_set_hl(0, "ConjurerNarration", { link = "DiagnosticVirtualTextInfo", default = true })

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

local function narration_virt(cast)
  if cast.state == "reviewing" then
    return { { { " 👀 reviewing: " .. cast.intent, "ConjurerNarration" } } }
  end
  local lines = {
    { { " ✨ conjuring: " .. cast.intent, "ConjurerNarration" } },
  }
  local n = #cast.narration
  for i = math.max(1, n - NARRATION_LINES + 1), n do
    table.insert(lines, { { "    · " .. cast.narration[i], "ConjurerNarration" } })
  end
  return lines
end

--- (Re)place the cast's region extmark. Rows/cols 0-based, end exclusive.
local function place_mark(cast, srow, scol, erow, ecol)
  cast.mark = vim.api.nvim_buf_set_extmark(cast.buf, ns, srow, scol, {
    id = cast.mark,
    end_row = erow,
    end_col = ecol,
    hl_group = "ConjurerPending",
    virt_lines = narration_virt(cast),
    right_gravity = false,
    end_right_gravity = true,
  })
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

--- Where the snapshot ends if placed back at (srow, scol).
local function snapshot_extent(cast, srow, scol)
  local snap = cast.snapshot
  local erow = srow + #snap - 1
  local ecol
  if cast.kind == "line" then
    scol = 0
    ecol = #snap[#snap]
  else
    ecol = #snap == 1 and scol + #snap[1] or #snap[#snap]
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

--- Put the snapshot back and re-anchor the mark: the region is not editable
--- while a conjure is in flight.
local function restore(cast)
  local srow, scol, erow, ecol = bounds(cast)
  if not srow then
    return
  end
  local ok
  if cast.kind == "line" then
    ok = pcall(vim.api.nvim_buf_set_lines, cast.buf, srow, erow + 1, false, cast.snapshot)
  else
    ok = pcall(vim.api.nvim_buf_set_text, cast.buf, srow, scol, erow, ecol, cast.snapshot)
  end
  if not ok then
    return
  end
  place_mark(cast, snapshot_extent(cast, srow, scol))
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
          if cast.buf == buf and not cast.done and region_changed(cast) then
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

--- Remove a cast's decorations and drop it from the registry.
local function retire(cast)
  cast.done = true
  if cast.review then
    close_review(cast)
  end
  if vim.api.nvim_buf_is_valid(cast.buf) then
    pcall(vim.api.nvim_buf_del_extmark, cast.buf, ns, cast.mark)
  end
  prune()
end

local function narrate(cast, line)
  if cast.done then
    return
  end
  table.insert(cast.narration, line)
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

--- Resolve "the cast under review" from the current buffer's diff-side
--- marker. Notifies and returns nil if the current buffer isn't one.
local function current_review_cast()
  local id = vim.b.conjurer_cast
  if not id then
    vim.notify("[conjurer] not a conjurer review buffer", vim.log.levels.ERROR)
    return nil
  end
  local cast = find_cast(id)
  if not cast or cast.state ~= "reviewing" then
    vim.notify("[conjurer] this review is no longer active", vim.log.levels.WARN)
    return nil
  end
  return cast
end

close_review = function(cast)
  local r = cast.review
  if not r then
    return
  end
  r.closing = true
  for _, w in ipairs({ r.before_win, r.after_win }) do
    if vim.api.nvim_win_is_valid(w) then
      pcall(vim.api.nvim_win_close, w, true)
    end
  end
  for _, b in ipairs({ r.before_buf, r.after_buf }) do
    if vim.api.nvim_buf_is_valid(b) then
      pcall(vim.api.nvim_buf_delete, b, { force = true })
    end
  end
  cast.review = nil
end

--- Open a native diff (new tabpage, two scratch buffers) showing the
--- proposed result against the locked snippet, and mark the cast as
--- awaiting a decision.
local function begin_review(cast, result, config)
  cast.state = "reviewing"
  cast.result = result

  local srow, scol, erow, ecol = bounds(cast)
  if srow then
    place_mark(cast, srow, scol, erow, ecol)
  end

  local filetype = vim.bo[cast.buf].filetype
  local before_buf = vim.api.nvim_create_buf(false, true)
  local after_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(before_buf, 0, -1, false, cast.snapshot)
  vim.api.nvim_buf_set_lines(after_buf, 0, -1, false, vim.split(result, "\n", { plain = true }))
  for _, b in ipairs({ before_buf, after_buf }) do
    vim.bo[b].buftype = "nofile"
    vim.bo[b].bufhidden = "wipe"
    vim.bo[b].swapfile = false
    vim.bo[b].filetype = filetype
    vim.bo[b].modified = false
  end
  pcall(vim.api.nvim_buf_set_name, before_buf, ("conjurer://%d/before"):format(cast.id))
  pcall(vim.api.nvim_buf_set_name, after_buf, ("conjurer://%d/after"):format(cast.id))

  vim.cmd("tabnew")
  local before_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(before_win, before_buf)
  vim.cmd("belowright vsplit")
  local after_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(after_win, after_buf)
  vim.api.nvim_win_call(before_win, function()
    vim.cmd("diffthis")
  end)
  vim.api.nvim_win_call(after_win, function()
    vim.cmd("diffthis")
  end)
  vim.api.nvim_set_current_win(after_win)

  cast.review = {
    before_buf = before_buf,
    after_buf = after_buf,
    before_win = before_win,
    after_win = after_win,
    closing = false,
  }
  vim.b[before_buf].conjurer_cast = cast.id
  vim.b[after_buf].conjurer_cast = cast.id

  for _, b in ipairs({ before_buf, after_buf }) do
    vim.api.nvim_create_autocmd("BufWipeout", {
      buffer = b,
      once = true,
      callback = function()
        if cast.review and not cast.review.closing then
          vim.notify(
            "[conjurer] review closed without a decision — treated as reject, buffer unchanged",
            vim.log.levels.WARN
          )
          -- Deferred: this fires mid-teardown of a buffer/window Neovim is
          -- still closing natively; tearing down the rest synchronously
          -- from in here (close_review's own buffer deletes) is unsafe.
          vim.schedule(function()
            if cast.review and not cast.review.closing then
              retire(cast)
            end
          end)
        end
      end,
    })
  end
end

--- Cancel every in-flight cast in the current buffer — or, if run from
--- inside a review's diff buffer, cancel just that cast.
function M.cancel()
  local buf = vim.api.nvim_get_current_buf()
  local review_id = vim.b[buf].conjurer_cast
  if review_id then
    local cast = find_cast(review_id)
    if cast and cast.state == "reviewing" then
      retire(cast)
      vim.notify("[conjurer] cancelled 1 conjure (review discarded)")
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
      end
      retire(cast)
      n = n + 1
    end
  end
  if n > 0 then
    vim.notify(("[conjurer] cancelled %d conjure%s"):format(n, n == 1 and "" or "s"))
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

local function apply(cast, result, config)
  local srow, scol, erow, ecol = bounds(cast)
  retire(cast)
  if not srow then
    vim.notify("[conjurer] region was lost before the response arrived", vim.log.levels.WARN)
    return
  end

  local lines = vim.split(result, "\n", { plain = true })
  if cast.kind == "line" then
    -- Drop a trailing blank line so linewise replacements don't grow.
    if lines[#lines] == "" then
      table.remove(lines)
    end
    local ok, err = pcall(vim.api.nvim_buf_set_lines, cast.buf, srow, erow + 1, false, lines)
    if not ok then
      vim.notify("[conjurer] failed to apply result: " .. err, vim.log.levels.ERROR)
      return
    end
    if #lines > 0 then
      mark_and_flash(cast.buf, srow, 0, srow + #lines - 1, #lines[#lines], config)
    end
  else
    local ok, err = pcall(vim.api.nvim_buf_set_text, cast.buf, srow, scol, erow, ecol, lines)
    if not ok then
      vim.notify("[conjurer] failed to apply result: " .. err, vim.log.levels.ERROR)
      return
    end
    local frow = srow + #lines - 1
    local fcol = #lines == 1 and scol + #lines[1] or #lines[#lines]
    mark_and_flash(cast.buf, srow, scol, frow, fcol, config)
  end
end

--- Call the configured provider for `request`, wiring its completion into
--- either apply() or begin_review() depending on config.review. Shared by
--- the initial cast and by retries (which re-dispatch on the same cast).
local function invoke_provider(cast, request, config)
  local fired = false
  cast.handle = require("conjurer").get_provider()(request, function(err, result)
    if fired or cast.done then
      return -- stale/duplicate callback for a request that already resolved
    end
    fired = true
    if not vim.api.nvim_buf_is_valid(cast.buf) then
      retire(cast)
      return
    end
    if err then
      retire(cast)
      vim.notify("[conjurer] " .. err, vim.log.levels.ERROR)
      return
    end
    if config.review then
      begin_review(cast, result, config)
    else
      apply(cast, result, config)
    end
  end)
end

--- Re-cast the same locked region, giving the model its rejected draft and
--- the user's feedback so it revises rather than starting over.
local function do_retry(cast, feedback)
  local previous_attempt =
    table.concat(vim.api.nvim_buf_get_lines(cast.review.after_buf, 0, -1, false), "\n")
  close_review(cast)
  cast.state = "generating"
  cast.narration = {}

  local srow, scol, erow, ecol = bounds(cast)
  if not srow then
    vim.notify("[conjurer] region was lost before the retry could start", vim.log.levels.WARN)
    retire(cast)
    return
  end
  place_mark(cast, srow, scol, erow, ecol)

  local config = require("conjurer").config
  local region = cast.kind == "line" and { kind = "line", srow = srow, erow = erow + 1 }
    or { kind = "char", srow = srow, scol = scol, erow = erow, ecol = ecol }
  local before, after = get_context(cast.buf, region, config.context_lines)

  local request = {
    config = config,
    intent = cast.intent,
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
  end
  invoke_provider(cast, request, config)
end

--- Apply the currently-displayed proposed result (not the frozen original
--- draft — do/dp in the diff may have hand-adjusted it) and close the diff.
function M.accept()
  local cast = current_review_cast()
  if not cast then
    return
  end
  local text = table.concat(vim.api.nvim_buf_get_lines(cast.review.after_buf, 0, -1, false), "\n")
  apply(cast, text, require("conjurer").config)
end

--- Discard the reviewed result and close the diff; the buffer is left
--- exactly as it was.
function M.reject()
  local cast = current_review_cast()
  if not cast then
    return
  end
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

--- Kick off an async conjure over a region: lock it, stream narration into
--- it, splice the result when it lands.
function M.conjure_region(buf, region, intent)
  local config = require("conjurer").config

  if not vim.bo[buf].modifiable or vim.bo[buf].readonly then
    vim.notify("[conjurer] buffer is not modifiable", vim.log.levels.ERROR)
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
  ensure_lock(buf)

  local request = {
    config = config,
    intent = intent,
    filetype = vim.bo[buf].filetype,
    text = table.concat(snapshot, "\n"),
    context_before = before,
    context_after = after,
  }
  if config.narration then
    request.on_narrate = function(line)
      narrate(cast, line)
    end
  end

  invoke_provider(cast, request, config)
end

return M
