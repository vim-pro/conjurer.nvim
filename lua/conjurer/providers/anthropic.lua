-- Provider that calls the Anthropic Messages API directly via curl, using
-- SSE streaming so narration arrives live.
local M = {}

local prompt = require("conjurer.prompt")

--- @type conjurer.Provider
function M.request(request, callback)
  local config = request.config
  local api_key = vim.env[config.api_key_env]
  if not api_key or api_key == "" then
    vim.schedule(function()
      callback(config.api_key_env .. " is not set")
    end)
    return
  end

  local payload = {
    model = config.model,
    max_tokens = config.max_tokens,
    stream = true,
    system = prompt.system(config, request),
    messages = {
      { role = "user", content = prompt.user(request) },
    },
  }
  if config.thinking then
    payload.thinking = { type = "adaptive" }
  end

  local sink = prompt.new_sink(request.on_narrate, request.on_result)
  local raw = {}
  local pending = ""
  local saw_event = false
  local stop_reason = nil
  local api_error = nil

  local function on_line(l)
    local data = l:match("^data:%s*(.+)$")
    if not data then
      return
    end
    local ok, obj = pcall(vim.json.decode, data)
    if not ok or type(obj) ~= "table" then
      return
    end
    saw_event = true
    if obj.type == "content_block_delta" and type(obj.delta) == "table" and obj.delta.type == "text_delta" then
      sink:feed(obj.delta.text or "")
    elseif obj.type == "message_delta" and type(obj.delta) == "table" then
      stop_reason = obj.delta.stop_reason or stop_reason
    elseif obj.type == "error" and type(obj.error) == "table" then
      api_error = obj.error.message or "unknown stream error"
    end
  end

  local function on_stdout(data)
    table.insert(raw, data)
    pending = pending .. data
    while true do
      local nl = pending:find("\n", 1, true)
      if not nl then
        break
      end
      local l = pending:sub(1, nl - 1)
      pending = pending:sub(nl + 1)
      on_line(l)
    end
  end

  local proc = vim.system({
    "curl",
    "-sS",
    "--no-buffer",
    "--max-time", "300",
    "https://api.anthropic.com/v1/messages",
    "-H", "content-type: application/json",
    "-H", "x-api-key: " .. api_key,
    "-H", "anthropic-version: 2023-06-01",
    "--data-binary", "@-",
  }, {
    stdin = vim.json.encode(payload),
    text = true,
    stdout = function(_, data)
      if data then
        vim.schedule(function()
          on_stdout(data)
        end)
      end
    end,
  }, function(out)
    vim.schedule(function()
      if api_error then
        callback("API error: " .. api_error)
        return
      end
      if not saw_event then
        -- Not an SSE stream: either curl failed or the API returned a plain
        -- JSON error body (e.g. a 400).
        local body = table.concat(raw, "")
        local ok, decoded = pcall(vim.json.decode, body)
        if ok and type(decoded) == "table" and decoded.type == "error" then
          callback("API error: " .. (decoded.error and decoded.error.message or "unknown"))
        elseif out.code ~= 0 then
          callback("curl failed: " .. (out.stderr or ("exit " .. out.code)))
        else
          callback("could not parse API response")
        end
        return
      end
      if stop_reason == "refusal" then
        callback("the model declined this request")
        return
      end
      if stop_reason == "max_tokens" then
        callback("response was truncated (max_tokens); raise config.max_tokens")
        return
      end
      local result = sink:finish()
      if not result or result == "" then
        callback("API response contained no text")
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
