-- Provider that shells out to a local LLM CLI. Recognizes a handful of
-- popular CLIs out of the box (see providers/known.lua); a custom `cli_cmd`
-- owns all of its own flags. conjurer pipes the prompt to stdin and treats
-- stdout as a stream of the narration protocol where the CLI speaks it,
-- falling back to plain text otherwise.
local M = {}

local prompt = require("conjurer.prompt")
local known = require("conjurer.providers.known")

--- Resolve the command to run: an explicit cli_cmd wins outright; config.cli
--- forces a specific known recipe by name; otherwise the first known CLI
--- whose binary is on PATH wins, falling back to claude's recipe if none
--- are (matching this function's older behavior of always returning
--- something, even when nothing is actually executable — callers check
--- executability themselves).
function M.command(config)
  if config.cli_cmd then
    return config.cli_cmd
  end
  if config.cli then
    for _, recipe in ipairs(known.clis) do
      if recipe.name == config.cli then
        return recipe.command(config)
      end
    end
    error(
      ("[conjurer] unknown cli '%s' — expected one of: %s"):format(
        config.cli,
        table.concat(
          vim.tbl_map(function(r)
            return r.name
          end, known.clis),
          ", "
        )
      )
    )
  end
  for _, recipe in ipairs(known.clis) do
    if vim.fn.executable(recipe.bin) == 1 then
      return recipe.command(config)
    end
  end
  return known.clis[1].command(config)
end

-- Feed one line of claude --output-format stream-json into the sink.
-- Returns the full result text if this line carried the final result event.
-- Thinking arrives as chunks, not lines, and often as one long paragraph
-- with no newline in it at all — so waiting for one means showing nothing
-- until the block closes, which is the silence this is here to fill.
-- Sentences are the unit that actually arrives.
local think_buf = ""
local function flush_thinking(on_narrate, final)
  if not on_narrate then
    think_buf = ""
    return
  end
  while true do
    local at = think_buf:find("[.!?]%s")
    if not at then
      break
    end
    local sentence = vim.trim(think_buf:sub(1, at))
    think_buf = think_buf:sub(at + 1)
    if sentence ~= "" then
      on_narrate(sentence)
    end
  end
  if final then
    local rest = vim.trim(think_buf)
    if rest ~= "" then
      on_narrate(rest)
    end
    think_buf = ""
  end
end

--- Read one line of the CLI's stream-json output. Exposed for specs: the
--- format is the CLI's, not ours, so it is pinned against real bytes.
---@return string? result The final result, on the line that carries it.
local function feed_stream_json(sink, l, on_phase, on_narrate)
  if l == "" then
    return nil
  end
  local ok, obj = pcall(vim.json.decode, l)
  if not ok or type(obj) ~= "table" then
    -- Not JSON — a custom or older CLI printing plain text.
    sink:feed(l .. "\n")
    return nil
  end
  if obj.type == "stream_event" and type(obj.event) == "table" then
    local ev = obj.event
    if ev.type == "content_block_delta" and type(ev.delta) == "table" and ev.delta.type == "text_delta" then
      sink:feed(ev.delta.text or "")
    elseif ev.type == "content_block_delta" and type(ev.delta) == "table" and ev.delta.type == "thinking_delta" then
      -- THINKING IS NARRATION, NEVER RESULT. It goes to on_narrate and not
      -- to the sink: the sink accumulates what will be spliced into your
      -- buffer, and reasoning about the work is not the work.
      --
      -- This was dropped, on the belief that the CLI never sends it. It
      -- does. What it does not do is send it for every model: measured on
      -- one drafting batch, `claude-opus-4-8` streamed thinking blocks with
      -- a signature and zero characters of text, while the CLI's own
      -- default streamed 1663 characters of it over 24 deltas. So the
      -- silence was half a pinned model (fixed in known.lua) and half this
      -- branch not existing.
      flush_thinking(on_narrate)
      think_buf = think_buf .. (ev.delta.thinking or "")
      flush_thinking(on_narrate)
    elseif ev.type == "content_block_stop" then
      flush_thinking(on_narrate, true)
    elseif ev.type == "content_block_start" and type(ev.content_block) == "table" then
      -- WHICH PHASE, from the stream itself. Even when a model streams its
      -- thinking there are gaps in it, and the phase says which kind of
      -- silence you are looking at. It is the difference between a still
      -- screen and one that says what it is doing.
      if on_phase then
        on_phase(ev.content_block.type == "thinking" and "thinking" or "writing")
      end
    end
  elseif obj.type == "result" and type(obj.result) == "string" then
    return obj.result
  end
  return nil
end


--- @type conjurer.Provider
function M.request(request, callback)
  local config = request.config
  local cmd = M.command(config)

  if vim.fn.executable(cmd[1]) ~= 1 then
    vim.schedule(function()
      callback(("'%s' is not executable"):format(cmd[1]))
    end)
    return
  end

  -- Attempted whenever the command wasn't fully custom, including for known
  -- CLIs other than claude (codex, gemini) that don't actually speak this
  -- format: feed_stream_json's non-JSON fallback degrades those to plain
  -- narration-protocol text, so this is safe even though it looks
  -- claude-specific.
  local streaming_json = config.cli_cmd == nil
  local sink = prompt.new_sink(request.on_narrate, request.on_result)
  local jsonbuf = ""
  local full_result = nil

  local function on_stdout(data)
    if streaming_json then
      jsonbuf = jsonbuf .. data
      while true do
        local nl = jsonbuf:find("\n", 1, true)
        if not nl then
          break
        end
        local l = jsonbuf:sub(1, nl - 1)
        jsonbuf = jsonbuf:sub(nl + 1)
        full_result = feed_stream_json(sink, l, request.on_phase, request.on_narrate) or full_result
      end
    else
      sink:feed(data)
    end
  end

  local input = prompt.system(config) .. "\n\n" .. prompt.user(request)

  local proc = vim.system(cmd, {
    stdin = input,
    text = true,
    -- nil inherits nvim's, which is the right default and was the only
    -- behavior: a request whose paths are relative to somewhere else says so.
    cwd = request.cwd,
    -- A caller that knows its request is a big one can say so; the
    -- configured value is the floor for everything else.
    timeout = request.timeout_ms or config.timeout_ms or 300000,
    stdout = function(_, data)
      if data then
        vim.schedule(function()
          on_stdout(data)
        end)
      end
    end,
  }, function(out)
    vim.schedule(function()
      if out.code ~= 0 then
        -- vim.system reports a timeout kill as 124, and "exit 124" tells
        -- you nothing — least of all that the fix is a bigger number. A
        -- large request legitimately runs long: scry's drafting pass sends
        -- a whole worklist and can sit thinking for minutes.
        if out.code == 124 then
          local secs = math.floor((request.timeout_ms or config.timeout_ms or 300000) / 1000)
          callback(
            ("%s timed out after %ds — raise it with setup({ timeout_ms = … }) if the request is a big one"):format(
              cmd[1],
              secs
            )
          )
          return
        end
        local detail = (out.stderr and out.stderr ~= "" and out.stderr) or ("exit " .. out.code)
        callback(cmd[1] .. " failed: " .. vim.trim(detail))
        return
      end
      local result = sink:finish()
      if (result == "" or result == nil) and full_result then
        -- Stream deltas were absent (older CLI); parse the final result event.
        result = prompt.extract_result(full_result)
      end
      if not result or result == "" then
        callback(cmd[1] .. " produced no output")
        return
      end
      callback(nil, result)
    end)
  end)

  return {
    cancel = function()
      proc:kill(15)
    end,
  }
end

M._feed_stream_json = feed_stream_json

return M
