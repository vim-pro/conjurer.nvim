-- The editor the tests run in: this plugin, mini.test, and nothing else.
--
-- `-u NONE` on its own cannot do this, because mini.test has to be found before
-- MiniTest.run() exists to be called. Everything here is runtimepath plumbing;
-- the specs themselves still start from a clean editor, because each one is
-- executed in its own child Neovim (see tests/runner.lua).
local here = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':h')
local root = vim.fn.fnamemodify(here, ':h')

vim.opt.rtp:prepend(root)
vim.opt.rtp:prepend(vim.env.MINI_NVIM or (here .. '/.deps/mini.nvim'))

-- One file collects the cases, so mini.test's own file-discovery (which looks
-- for tests/**/test_*.lua) is pointed straight at it. Renaming 47 specs to suit
-- a collector's default would be the tail wagging the dog.
require('mini.test').setup({
  collect = { find_files = function() return { here .. '/runner.lua' } end },
})
