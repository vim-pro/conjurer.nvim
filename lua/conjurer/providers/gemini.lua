-- Provider that calls the Gemini API directly via curl, using SSE streaming
-- so narration arrives live.
local M = {}

local prompt = require("conjurer.prompt")

--- @type conjurer.Provider
function M.request(request, callback)
  local config = request.config
  local api_key = vim.env.GEMINI_API_KEY
  if not api_key or api_key == "" then
    vim.schedule(function()
      callback("GEMINI_API_KEY is not set")
    end)
    return
  end

  local model = config.model or "gemini-pro-latest"
  local payload = {
    contents = { { parts = { { text = prompt.user(request) } } } },
    systemInstruction = { parts = { { text = prompt.system(config, request) } } },
  }

  local sink = prompt.new_sink(request.on_narrate, request.on_result)
  local raw = {}
  local pending = ""
  local saw_event = false
  local finish_reason = nil

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
    local cand = obj.candidates and obj.candidates[1]
    if type(cand) ~= "table" then
      return
    end
    if cand.finishReason then
      finish_reason = cand.finishReason
    end
    local parts = type(cand.content) == "table" and cand.content.parts
    if type(parts) == "table" then
      for _, part in ipairs(parts) do
        if part.text then
          sink:feed(part.text)
        end
      end
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

  local url = ("https://generativelanguage.googleapis.com/v1beta/models/%s:streamGenerateContent?alt=sse"):format(model)

  local proc = vim.system({
    "curl",
    "-sS",
    "--no-buffer",
    "--max-time", "300",
    url,
    "-H", "content-type: application/json",
    "-H", "x-goog-api-key: " .. api_key,
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
      if not saw_event then
        -- Not an SSE stream: either curl failed or the API returned a plain
        -- top-level JSON error body (e.g. a 400/403).
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
      if finish_reason == "SAFETY" or finish_reason == "RECITATION" or finish_reason == "PROHIBITED_CONTENT" then
        callback("the model declined this request")
        return
      end
      if finish_reason == "MAX_TOKENS" then
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
