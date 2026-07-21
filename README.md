# conjurer.nvim

[![CI](https://github.com/vim-pro/conjurer.nvim/actions/workflows/ci.yml/badge.svg)](https://github.com/vim-pro/conjurer.nvim/actions/workflows/ci.yml)

**[conjurer.vim.pro](https://conjurer.vim.pro)** · `:h conjurer`

A **conjure verb** for Neovim: `~{motion}` targets some text, prompts you for
an intent, sends the text to your configured LLM, and splices the result back
in place — asynchronously, without blocking the editor. While it works, the
region is locked and the model narrates what it's doing, live, right in the
buffer.

It is a real Vim operator, so it composes with everything you already know:

| Keys | Effect |
| --- | --- |
| `~ip` | conjure over the inner paragraph |
| `~i{` | conjure inside braces |
| `~3j` | conjure over the next 3 lines |
| `~~` | conjure the current line |
| `~` (visual) | conjure the selection |
| `:'<,'>Conjure add error handling` | conjure a range with an inline intent |
| `:ConjureCancel` | abort everything in flight in this buffer |

The motion comes first, then the intent prompt — so `~ip` feels exactly like
`dip` or `g~ip`: pick the target, then cast.

## Why `~`?

Vim itself considers `~` an operator: the builtin `'tildeop'` option exists
solely to turn `~` into `~{motion}`. Its stock behavior (toggle case) is fully
covered by `g~` / `gu` / `gU`, so nothing is lost — conjurer just upgrades the
transformation the key was always meant to carry, from "flip case" to "apply
intent." Transmutation, but bigger.

## Narration and locking

While a conjure is in flight, the target region is dimmed and **locked** —
edits inside it are reverted (everything outside stays editable), and the
model's narration streams into the region as virtual lines:

```
local function fetch_user(id)          ← dimmed, locked
 ✨ conjuring: add error handling
    · wrapping the decode in a pcall
  local res = http.get("/users/" .. id)
  ...
```

Nothing touches the buffer until the final splice, so `:ConjureCancel` always
leaves the file byte-identical — and the finished conjure is still a single
undo step.

## Bottled Vim idioms

Conjurer tries to behave like a native operator in every detail:

- **Counts** scale the motion: `2~j` conjures three lines, `3~~` three lines
  from the cursor — exactly like `2dj` / `3dd`.
- **Registers hold intents**: `"c~ip` reads the intent from register `c` and
  skips the prompt. Load reusable spells once — `:let @r = "add type hints"` —
  then cast `"r~ip` anywhere, including inside macros. Dot-repeat works
  afterwards too.
- **`.` repeats** the last conjure (intent included) over a new target.
- **`'[` and `']`** are set around the conjured text when it lands, so
  `` `[ ``, `` `] ``, and chained operators over the result (`` =`] ``) work.
- **The result flashes** briefly (like the `on_yank` highlight) when the async
  replacement lands — the Vim-native "it finished" signal.
- **`:Conjure` with no argument reuses the last intent** over a range, the way
  `&` reuses the last `:s`.
- **The prompt is `input()`-backed**, so `<Up>` recalls previous intents.
- **Forced motion types** work: `~Vip` forces linewise, like `dVip`.
- **Readonly / nomodifiable buffers** are refused up front, not mid-splice.
- One conjure = one undo step: `u` un-conjures.

## `.` is the point

The intent is captured once, when you invoke the operator. Pressing `.`
replays the operator over a new target **without prompting again** — the
stored intent is reused.

```
~ip           → prompt: "convert to a pure function" → paragraph rewritten
}             → move to the next paragraph
.             → same intent conjured over this paragraph, no prompt
```

## Install

lazy.nvim:

```lua
{
  "vim-pro/conjurer.nvim",
  version = "*", -- pin to tagged releases; omit to track main
  opts = {},
}
```

packer.nvim:

```lua
use({
  "vim-pro/conjurer.nvim",
  config = function() require("conjurer").setup() end,
})
```

vim-plug:

```vim
Plug 'vim-pro/conjurer.nvim'
" after plug#end():
" lua require("conjurer").setup()
```

mini.deps:

```lua
require("mini.deps").add("vim-pro/conjurer.nvim")
require("conjurer").setup()
```

Requires Neovim 0.10+. The default provider prefers the local `claude` CLI
(no API key needed); without it, `curl` plus an API key in
`$ANTHROPIC_API_KEY` (configurable).

After installing: `:h conjurer` for the full manual, `:checkhealth conjurer`
to verify your setup.

## Configuration

Defaults shown:

```lua
require("conjurer").setup({
  provider = "auto",               -- "auto" | "cli" | "anthropic" | function(request, cb)
  model = "claude-opus-4-8",
  cli_cmd = nil,                   -- nil = claude CLI in streaming print mode
  api_key_env = "ANTHROPIC_API_KEY",
  max_tokens = 16000,
  thinking = true,                 -- adaptive thinking (better edits, more latency)
  context_lines = 40,              -- surrounding lines sent for context
  narration = true,                -- stream model narration into the region
  flash_ms = 150,                  -- completion flash; false/0 disables
  flash_hl = "IncSearch",
  keymaps = {
    operator = "~",                -- set false to disable
    line = "~~",
  },
  system_prompt = nil,             -- string to override the built-in prompt
})
```

### Providers

`"auto"` (the default) prefers a **local executable** — the Claude Code CLI in
streaming print mode — and falls back to the Anthropic API when the executable
isn't found. Force one with `provider = "cli"` or `provider = "anthropic"`.

Because the default CLI is Claude Code, it may read project context (e.g.
`CLAUDE.md`) and has a cold-start cost of a few seconds per cast.

`cli_cmd` swaps in any local command; it owns its own flags, conjurer just
pipes the prompt to stdin and reads stdout:

```lua
require("conjurer").setup({
  provider = "cli",
  cli_cmd = { "ollama", "run", "qwen2.5-coder" },
})
```

`provider` can also be a function, so any backend works:

```lua
require("conjurer").setup({
  provider = function(request, callback)
    -- request: { config, intent, filetype, text,
    --            context_before, context_after, on_narrate }
    -- Call callback exactly once (on the main loop):
    callback(nil, transformed_text)  -- or callback("error message")
    -- Optionally return { cancel = function() ... end } for :ConjureCancel.
  end,
})
```

See `:h conjurer-provider-protocol` for the narration protocol built-in
providers use.

## Privacy

Every cast sends the targeted snippet, the surrounding context, the filetype,
and your intent to the configured provider — a local process for `"cli"`,
Anthropic's API for `"anthropic"`, or wherever your custom provider points.
Don't conjure over buffers whose content must not leave your machine unless
your provider is one you control.

## Development

```sh
./scripts/test    # headless test suite
./scripts/site    # serve the website locally
```

## Notes

- Case toggling is still available via `g~{motion}`, `g~~`, and visual `u`/`U`.
- Blockwise (`<C-v>`) selections are not supported.
