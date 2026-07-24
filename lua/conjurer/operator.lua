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

--- Remove a cast's decorations and drop it from the registry.
local function retire(cast)
  cast.done = true
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

--- Cancel every in-flight cast in the current buffer.
function M.cancel()
  local buf = vim.api.nvim_get_current_buf()
  local n = 0
  for _, cast in ipairs(casts) do
    if cast.buf == buf and not cast.done then
      if cast.handle and cast.handle.cancel then
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
--- sequence work across many casts.
---@param opts { on_done: fun(err: string?, result: string?) }?
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
    buf = buf,
    kind = region.kind,
    intent = intent,
    snapshot = snapshot,
    narration = {},
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

  cast.handle = require("conjurer").get_provider()(request, function(err, result)
    if cast.done then
      return -- cancelled
    end
    if not vim.api.nvim_buf_is_valid(buf) then
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
    apply(cast, result, config)
    if on_done then
      on_done(nil, result)
    end
  end)

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
