-- Provider that shells out to a local LLM CLI. The default command is the
-- Claude Code CLI in streaming print mode, so narration arrives live. A
-- custom `cli_cmd` owns all of its own flags; conjurer pipes the prompt to
-- stdin and treats stdout as a plain text stream of the narration protocol.
local M = {}

local prompt = require("conjurer.prompt")

function M.command(config)
  return config.cli_cmd
    or {
      "claude",
      "-p",
      "--model",
      config.model,
      "--output-format",
      "stream-json",
      "--include-partial-messages",
      "--verbose",
    }
end

-- Feed one line of claude --output-format stream-json into the sink.
-- Returns the full result text if this line carried the final result event.
local function feed_stream_json(sink, l)
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

  local streaming_json = config.cli_cmd == nil
  local sink = prompt.new_sink(request.on_narrate)
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
        full_result = feed_stream_json(sink, l) or full_result
      end
    else
      sink:feed(data)
    end
  end

  local input = prompt.system(config) .. "\n\n" .. prompt.user(request)

  local proc = vim.system(cmd, {
    stdin = input,
    text = true,
    timeout = 300000,
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
