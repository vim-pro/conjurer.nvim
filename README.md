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
| `:ConjureAccept` | keep the reviewed result and close the diff |
| `:ConjureReject` | revert the reviewed result and close the diff |
| `:ConjureRetry {feedback}` | revert, then re-conjure the region with feedback |
| `:ConjureAll {intent}` | conjure the intent over every quickfix entry |
| `:ConjureNext` | conjure the current quickfix entry and advance |
| `:ConjureRejectSite` | revert the conjured site under the cursor |

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

## Reviewing before applying

Set `review = true` and a finished conjure lands in the buffer right away,
then opens a native two-way diff in a new tabpage: a frozen snapshot of the
whole file on the left, your real, already-patched buffer on the right —
`]c`/`[c`/`do`/`dp` all work natively. The right side isn't a copy, so the
region is no longer locked once a draft exists — scroll anywhere in the file
for context, or edit the draft directly, while you decide:

```
:ConjureAccept              keep whatever's in the buffer, close the diff
:ConjureReject               revert to the exact pre-conjure text
:ConjureRetry fix the edge case   revert, then send the draft + feedback
                             back to the model, which revises rather than
                             starting over
```

Closing the diff yourself without running one of those (`:tabclose`, etc.) is
treated as a reject — the draft is reverted, not left in place.

## Aggregate conjuring

One intent, many sites. Populate the quickfix list however you like —
`:grep`, `:vimgrep`, LSP references, `:cexpr` — prune it, then:

```vim
:vimgrep /print(/j lua/**/*.lua
:ConjureAll convert these prints to structured logging
```

Casts run with bounded concurrency (`max_concurrent`), same-file sites
serialize so splices never collide, and each site tracks its own state:
pending → running → done / skipped / failed. A model that returns a site
unchanged marks it skipped — false positives in the list are tolerated for
free. Re-running `:ConjureAll` is idempotent (only pending and failed sites
cast), so `:grepadd` + re-run grows the job naturally.

Review happens in place: walk with `:cnext` (entries auto-track the edits),
judge each site in its real surroundings, `:ConjureRejectSite` any you don't
want. `:ConjureNext` casts one entry at a time for careful passes — and the
aggregate intent feeds `~`/`.`, so spot-repairing a site the search missed is
one motion away.

With [quickfix.pro](https://github.com/vim-pro/quickfix.pro) installed, the
list shows live per-site status signs, `<Tab>` expands a site into its
before/after diff, and `dd` on a running site cancels its request.

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

vim.pack (Neovim 0.12+'s built-in manager, no plugin manager needed):

```lua
vim.pack.add({ "https://github.com/vim-pro/conjurer.nvim" })
require("conjurer").setup()
```

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

Requires Neovim 0.10+ (0.12+ for vim.pack itself). The default provider
prefers a local CLI (`claude`, `codex`, or `gemini` — no API key needed);
without one, `curl` plus a key in `$ANTHROPIC_API_KEY`, `$OPENAI_API_KEY`,
or `$GEMINI_API_KEY`. See [Providers](#providers) below.

After installing: `:h conjurer` for the full manual, `:checkhealth conjurer`
to verify your setup.

## Configuration

Defaults shown:

```lua
require("conjurer").setup({
  provider = "auto",               -- "auto" | "cli" | "anthropic" | "openai" | "gemini" | function(request, cb)
  model = nil,                     -- nil = the resolved provider's own default
  cli = nil,                       -- force a known cli recipe: "claude" | "codex" | "gemini"
  cli_cmd = nil,                   -- nil = resolve a known CLI (see cli above), or fully custom
  api_key_env = "ANTHROPIC_API_KEY", -- "anthropic" only; openai/gemini use their own env vars
  max_tokens = 16000,
  thinking = true,                 -- adaptive thinking (better edits, more latency)
  context_lines = 40,              -- surrounding lines sent for context
  max_concurrent = 4,              -- :ConjureAll sites cast at once
  narration = true,                -- stream model narration into the region
  flash_ms = 150,                  -- completion flash; false/0 disables
  flash_hl = "IncSearch",
  keymaps = {
    operator = "~",                -- set false to disable
    line = "~~",
  },
  system_prompt = nil,             -- string to override the built-in prompt
  review = false,                  -- review results in a diff before applying
})
```

### Providers

`"auto"` (the default) tries, in order: the **`claude`, `codex`, then
`gemini` CLIs** (first one found on `$PATH` wins) — and if none are
installed, whichever of `ANTHROPIC_API_KEY` / `OPENAI_API_KEY` /
`GEMINI_API_KEY` is actually set (same order), defaulting to Anthropic if
none are. Force one with `provider = "cli"` (plus `cli = "codex"` etc. to
pick a specific known CLI), or `"anthropic"` / `"openai"` / `"gemini"` to go
straight to an API.

The default CLI, Claude Code, may read project context (e.g. `CLAUDE.md`)
and has a cold-start cost of a few seconds per cast. `codex`/`gemini` run
non-interactively and print only the final result — no live narration from
those two, everything else works the same.

`cli_cmd` swaps in any local command — ollama, opencode, aider, lm-studio,
anything with a non-interactive mode — it owns its own flags, conjurer just
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
