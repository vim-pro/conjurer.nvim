-- Every *_spec.lua, as one mini.test case each, run in its own Neovim.
--
-- The specs are unchanged: each is still a straight-line script that sets up an
-- editor state and asserts against it, and each still gets a clean editor —
-- which it must, because they create buffers, quickfix lists and autocommands
-- and would otherwise read each other's leavings. What used to provide that
-- isolation was a shell loop starting `nvim` per file; a child Neovim does the
-- same thing, and reports back instead of just setting an exit code.
--
-- What changes is what happens when one FAILS. The old helpers called
-- os.exit(1) on the first bad assertion, which killed the editor: the rest of
-- that file went unrun, and from the outside a failure looked exactly like a
-- crash. Now the assertion raises, the child carries it to the parent, and the
-- remaining specs still run — so one broken thing reports one broken thing.
local T = MiniTest.new_set()

local here = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':h')
local child = MiniTest.new_child_neovim()

-- `scripts/test [pattern]` filters by substring, as it always has.
local pattern = vim.env.SPEC_PATTERN
if pattern == '' then pattern = nil end

for _, spec in ipairs(vim.fn.glob(here .. '/*_spec.lua', false, true)) do
  local name = vim.fn.fnamemodify(spec, ':t:r')
  if not pattern or name:find(pattern, 1, true) then
    T[name] = function()
      -- `-u NONE`: the spec's own helpers put the plugin on the runtimepath,
      -- exactly as they did under the old runner. Nothing else is loaded.
      child.restart({ '-u', 'NONE', '--headless' })
      child.lua('dofile(...)', { spec })
      child.stop()
    end
  end
end

return T
