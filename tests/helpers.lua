-- Shared helpers for headless specs. Load with:
--   local H = dofile(vim.fn.fnamemodify(<spec path>, ":h") .. "/helpers.lua")
local H = {}

H.root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h")
vim.opt.rtp:prepend(H.root)

H.ns = vim.api.nvim_create_namespace("conjurer")
H.flash_ns = vim.api.nvim_create_namespace("conjurer.flash")

function H.feed(keys)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "mx", false)
  vim.api.nvim_feedkeys("", "x", false)
end

function H.lines(buf)
  return vim.api.nvim_buf_get_lines(buf or 0, 0, -1, false)
end

-- Raise, do not exit. os.exit(1) killed the whole Neovim on the first failed
-- assertion, so every later check in the file went unrun and unreported — and
-- from outside, a real failure was indistinguishable from a crash. An error is
-- something a test runner can catch, attribute and carry on from.
function H.fail(msg)
  error(msg .. "\n" .. vim.inspect(H.lines()), 0)
end

function H.eq(got, want, what)
  if got ~= want then
    H.fail(("%s: got %s, want %s"):format(what, vim.inspect(got), vim.inspect(want)))
  end
end

--- All narration/pending virt_lines text currently displayed, joined.
function H.virt_text(buf)
  local out = {}
  local marks = vim.api.nvim_buf_get_extmarks(buf or 0, H.ns, 0, -1, { details = true })
  for _, m in ipairs(marks) do
    for _, vline in ipairs(m[4].virt_lines or {}) do
      for _, chunk in ipairs(vline) do
        table.insert(out, chunk[1])
      end
    end
  end
  return table.concat(out, "\n")
end

function H.pending_marks(buf)
  return vim.api.nvim_buf_get_extmarks(buf or 0, H.ns, 0, -1, {})
end

-- Kept so no spec needs editing, but it no longer exits: reaching the end of a
-- spec IS the pass, and the runner is what says so.
function H.done(msg)
  return msg
end

return H
