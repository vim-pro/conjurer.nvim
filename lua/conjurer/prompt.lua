-- Prompt construction and stream parsing shared by all providers.
local M = {}

M.DEFAULT_SYSTEM_PROMPT = [[
You are Conjure, a text transformation engine embedded in a code editor.
You receive a snippet from a file, the surrounding context, and an intent.
Rewrite ONLY the snippet according to the intent.

Respond in exactly this shape:
1. First, narrate your plan: one to three short lines, present tense, each
   under 60 characters (e.g. "wrapping the decode in a pcall"). These are
   shown live in the editor while you work.
2. Then a line containing exactly:  <<<RESULT
3. Then the replacement text for the snippet.
4. Then a final line containing exactly:  RESULT

Rules for the replacement:
- It is spliced into the file exactly where the snippet was, so match its
  indentation and boundaries. If the snippet starts or ends mid-line, your
  replacement must too.
- No explanations and no markdown code fences inside the RESULT block.
- Never include the surrounding context.
- If the intent cannot be applied to this snippet, return the snippet
  unchanged inside the RESULT block.
]]

function M.system(config)
  return config.system_prompt or M.DEFAULT_SYSTEM_PROMPT
end

---@param request conjurer.Request
function M.user(request)
  return table.concat({
    "Filetype: " .. (request.filetype ~= "" and request.filetype or "unknown"),
    "",
    "Context before the snippet:",
    "<<<CONTEXT_BEFORE",
    request.context_before,
    "CONTEXT_BEFORE",
    "",
    "Context after the snippet:",
    "<<<CONTEXT_AFTER",
    request.context_after,
    "CONTEXT_AFTER",
    "",
    "Snippet to transform:",
    "<<<SNIPPET",
    request.text,
    "SNIPPET",
    "",
    "Intent: " .. request.intent,
  }, "\n")
end

-- Models sometimes fence output despite instructions; strip a single
-- surrounding fence if present.
function M.strip_fences(text)
  local body = text:match("^```[%w_%-]*\n(.-)\n?```%s*$")
  return body or text
end

--- Incremental parser for the narration protocol. Feed it stdout chunks;
--- lines before <<<RESULT go to `on_narrate`, lines between the markers
--- accumulate as the result. If the markers never appear (a model or custom
--- provider ignoring the protocol), the whole output is the result.
---@param on_narrate fun(line: string)?
function M.new_sink(on_narrate)
  local sink = {
    pending = "",
    mode = "narrate",
    result = {},
    raw = {},
  }

  local function line(l)
    if sink.mode == "narrate" then
      if l:match("^<<<RESULT%s*$") then
        sink.mode = "result"
      elseif l ~= "" and on_narrate then
        on_narrate(l)
      end
    elseif sink.mode == "result" then
      if l:match("^RESULT%s*$") then
        sink.mode = "done"
      else
        table.insert(sink.result, l)
      end
    end
  end

  function sink:feed(chunk)
    table.insert(self.raw, chunk)
    self.pending = self.pending .. chunk
    while true do
      local nl = self.pending:find("\n", 1, true)
      if not nl then
        break
      end
      local l = self.pending:sub(1, nl - 1)
      self.pending = self.pending:sub(nl + 1)
      line(l)
    end
  end

  --- Flush and return the final result text (may be "").
  function sink:finish()
    if self.pending ~= "" then
      line(self.pending)
      self.pending = ""
    end
    if self.mode == "narrate" then
      -- Protocol not followed: treat the entire output as the result.
      local whole = table.concat(self.raw, ""):gsub("\n+$", "")
      return M.strip_fences(whole)
    end
    return M.strip_fences(table.concat(self.result, "\n"))
  end

  return sink
end

--- Extract the result from a complete (non-streamed) protocol response.
function M.extract_result(text)
  local sink = M.new_sink(nil)
  sink:feed(text .. "\n")
  return sink:finish()
end

return M
