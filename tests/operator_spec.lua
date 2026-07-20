-- The operator grammar: motions, doubling, visual, dot-repeat, :Conjure,
-- multibyte boundaries, and that builtin g~ survives.
local H = dofile(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h") .. "/helpers.lua")

local calls, prompts = 0, 0
require("conjurer").setup({
  provider = function(req, cb)
    calls = calls + 1
    cb(nil, req.text:upper())
  end,
})
vim.ui.input = function(_, cb)
  prompts = prompts + 1
  cb("shout")
end

local buf = vim.api.nvim_get_current_buf()

-- 1) ~ip typed at full speed (motion first, then prompt)
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "one two", "", "second para" })
vim.api.nvim_win_set_cursor(0, { 1, 0 })
H.feed("~ip")
H.eq(H.lines()[1], "ONE TWO", "~ip")
H.eq(prompts, 1, "prompt count after ~ip")

-- 2) dot-repeat on the other paragraph: must not prompt
vim.ui.input = function()
  H.fail("dot-repeat prompted")
end
vim.api.nvim_win_set_cursor(0, { 3, 0 })
H.feed(".")
H.eq(H.lines()[3], "SECOND PARA", "dot-repeat")

-- 3) ~~ line variant
vim.ui.input = function(_, cb)
  prompts = prompts + 1
  cb("shout")
end
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "line a", "line b" })
vim.api.nvim_win_set_cursor(0, { 2, 0 })
H.feed("~~")
H.eq(H.lines()[2], "LINE B", "~~")
H.eq(H.lines()[1], "line a", "~~ neighbor untouched")

-- 4) visual selection
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "alpha beta gamma" })
vim.api.nvim_win_set_cursor(0, { 1, 6 })
H.feed("viw~")
H.eq(H.lines()[1], "alpha BETA gamma", "visual ~")

-- 5) dot-repeat after visual (same-size region from cursor)
vim.ui.input = function()
  H.fail("visual dot-repeat prompted")
end
vim.api.nvim_win_set_cursor(0, { 1, 11 })
H.feed(".")
if not H.lines()[1]:find("GAMM") then
  H.fail("visual dot-repeat")
end

-- 6) :Conjure command with a range and inline intent
vim.ui.input = function(_, cb)
  cb("shout")
end
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "aaa", "bbb", "ccc" })
vim.cmd("1,2Conjure loud")
H.eq(H.lines()[1], "AAA", ":Conjure line 1")
H.eq(H.lines()[2], "BBB", ":Conjure line 2")
H.eq(H.lines()[3], "ccc", ":Conjure line 3 untouched")

-- 7) multibyte charwise boundary
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "say héllo now" })
vim.api.nvim_win_set_cursor(0, { 1, 4 })
H.feed("~iw")
-- Lua's :upper() is ASCII-only; the point is the full multibyte word moved.
H.eq(H.lines()[1], "say HéLLO now", "multibyte ~iw")

-- 8) builtin case-toggling still reachable via g~
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "abc" })
vim.api.nvim_win_set_cursor(0, { 1, 0 })
H.feed("g~iw")
H.eq(H.lines()[1], "ABC", "g~ intact")

H.done(("operator_spec PASS (%d provider calls, %d prompts)"):format(calls, prompts))
