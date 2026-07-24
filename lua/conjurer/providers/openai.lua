-- Provider that calls the OpenAI Chat Completions API directly via curl,
-- using SSE streaming so narration arrives live.
local M = {}

local prompt = require("conjurer.prompt")

--- @type conjurer.Provider
function M.request(request, callback)
  local config = request.config
  local api_key = vim.env.OPENAI_API_KEY
  if not api_key or api_key == "" then
    vim.schedule(function()
      callback("OPENAI_API_KEY is not set")
    end)
    return
  end

  local payload = {
    model = config.model or "gpt-5.1",
    stream = true,
    messages = {
      { role = "system", content = prompt.system(config) },
      { role = "user", content = prompt.user(request) },
    },
  }

  local sink = prompt.new_sink(request.on_narrate)
  local raw = {}
  local pending = ""
  local saw_event = false
  local finish_reason = nil
  local api_error = nil

  local function on_line(l)
    local data = l:match("^data:%s*(.+)$")
    if not data or data == "[DONE]" then
      return
    end
    local ok, obj = pcall(vim.json.decode, data)
    if not ok or type(obj) ~= "table" then
      return
    end
    saw_event = true
    if type(obj.error) == "table" then
      api_error = obj.error.message or "unknown stream error"
      return
    end
    local choice = obj.choices and obj.choices[1]
    if type(choice) ~= "table" then
      return
    end
    if type(choice.delta) == "table" and choice.delta.content then
      sink:feed(choice.delta.content)
    end
    if choice.finish_reason then
      finish_reason = choice.finish_reason
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
    "https://api.openai.com/v1/chat/completions",
    "-H", "content-type: application/json",
    "-H", "authorization: Bearer " .. api_key,
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
        if ok and type(decoded) == "table" and type(decoded.error) == "table" then
          callback("API error: " .. (decoded.error.message or "unknown"))
        elseif out.code ~= 0 then
          callback("curl failed: " .. (out.stderr or ("exit " .. out.code)))
        else
          callback("could not parse API response")
        end
        return
      end
      if finish_reason == "content_filter" then
        callback("the model declined this request")
        return
      end
      if finish_reason == "length" then
        callback("response was truncated (max output tokens); try a smaller region")
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
