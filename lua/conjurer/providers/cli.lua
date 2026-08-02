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
local function feed_stream_json(sink, l, on_phase)
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
    elseif ev.type == "content_block_start" and type(ev.content_block) == "table" then
      -- WHICH PHASE, from the stream itself. A big request spends most of
      -- its life in a thinking block and the CLI sends no thinking_delta
      -- for it — measured: a thinking block opens, a signature arrives at
      -- the end, and not one character in between. So there is no text to
      -- show, and the only honest thing to report is which of the two
      -- blocks is open. It is the difference between a still screen and
      -- one that says what it is doing.
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
        full_result = feed_stream_json(sink, l, request.on_phase) or full_result
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
    timeout = config.timeout_ms or 300000,
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
          local secs = math.floor((config.timeout_ms or 300000) / 1000)
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

return M
