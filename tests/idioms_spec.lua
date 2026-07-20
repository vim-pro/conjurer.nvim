-- The bottled Vim idioms: counts, registers as intents, '[ '] marks, the
-- completion flash, :Conjure reuse, and the readonly guard.
local H = dofile(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h") .. "/helpers.lua")

require("conjurer").setup({
  provider = function(req, cb)
    cb(nil, req.text:upper())
  end,
})
vim.ui.input = function(_, cb)
  cb("shout")
end

local buf = vim.api.nvim_get_current_buf()

-- counts: 2~j = 3 lines (motion j with count 2)
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "a1", "a2", "a3", "a4" })
vim.api.nvim_win_set_cursor(0, { 1, 0 })
H.feed("2~j")
H.eq(H.lines()[1], "A1", "count 2~j first")
H.eq(H.lines()[3], "A3", "count 2~j third")
H.eq(H.lines()[4], "a4", "count 2~j untouched")

-- counts on the line variant: 3~~ = 3 lines
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "b1", "b2", "b3", "b4" })
vim.api.nvim_win_set_cursor(0, { 1, 0 })
H.feed("3~~")
H.eq(H.lines()[3], "B3", "count 3~~")
H.eq(H.lines()[4], "b4", "count 3~~ untouched")

-- register as intent: "c~ip must not prompt
vim.fn.setreg("c", "shout it")
vim.ui.input = function()
  H.fail("register intent prompted")
end
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "reg test" })
vim.api.nvim_win_set_cursor(0, { 1, 0 })
H.feed('"c~ip')
H.eq(H.lines()[1], "REG TEST", "register intent")

-- ...and dot-repeat after a register invocation reuses that intent
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "dot after reg" })
vim.api.nvim_win_set_cursor(0, { 1, 0 })
H.feed(".")
H.eq(H.lines()[1], "DOT AFTER REG", "dot after register")

-- '[ and '] marks land on the conjured text
vim.ui.input = function(_, cb)
  cb("shout")
end
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "one", "mark me", "three" })
vim.api.nvim_win_set_cursor(0, { 2, 0 })
H.feed("~~")
local m1 = vim.api.nvim_buf_get_mark(buf, "[")
local m2 = vim.api.nvim_buf_get_mark(buf, "]")
H.eq(m1[1], 2, "'[ row")
H.eq(m2[1], 2, "'] row")
H.eq(m2[2], #"MARK ME" - 1, "'] col")

-- flash: highlight extmarks exist right after apply, gone after flash_ms
local flashes = vim.api.nvim_buf_get_extmarks(buf, H.flash_ns, 0, -1, {})
if #flashes == 0 then
  H.fail("no flash highlight")
end
vim.wait(500, function()
  return #vim.api.nvim_buf_get_extmarks(buf, H.flash_ns, 0, -1, {}) == 0
end, 20)
H.eq(#vim.api.nvim_buf_get_extmarks(buf, H.flash_ns, 0, -1, {}), 0, "flash cleared")

-- :Conjure with no args reuses the last intent
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "reuse me" })
vim.cmd("1Conjure")
H.eq(H.lines()[1], "REUSE ME", ":Conjure reuse")

-- readonly guard: no change, no crash
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "locked" })
vim.bo[buf].readonly = true
pcall(vim.cmd, "1Conjure anything")
H.eq(H.lines()[1], "locked", "readonly guard")
vim.bo[buf].readonly = false

H.done("idioms_spec PASS")
