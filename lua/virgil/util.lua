local M = {}

M.NS = vim.api.nvim_create_namespace('virgil')

---@param msg string
---@param level integer|nil
function M.notify(msg, level)
  vim.schedule(function()
    vim.notify(msg, level or vim.log.levels.INFO, { title = 'virgil' })
  end)
end

function M.warn(msg)
  M.notify(msg, vim.log.levels.WARN)
end

function M.err(msg)
  M.notify(msg, vim.log.levels.ERROR)
end

--- UTC timestamp, the only time format that goes to disk.
function M.now()
  return os.date('!%Y-%m-%dT%H:%M:%SZ')
end

--- Parse an ISO-8601 UTC timestamp back into epoch seconds.
---@param ts string|nil
---@return integer|nil
function M.parse_time(ts)
  if type(ts) ~= 'string' then
    return nil
  end
  local y, mo, d, h, mi, s = ts:match('^(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)Z?$')
  if not y then
    return nil
  end
  local t = os.time({
    year = tonumber(y) or 1970,
    month = tonumber(mo) or 1,
    day = tonumber(d) or 1,
    hour = tonumber(h) or 0,
    min = tonumber(mi) or 0,
    sec = tonumber(s) or 0,
  })
  -- os.time reads the table as local time; shift it back to UTC
  local utc = os.date('!*t', t) --[[@as table]]
  local offset = os.difftime(t, os.time(utc))
  return t + offset
end

local seeded = false
local counter = 0

--- Short, collision-resistant note id.
function M.uid()
  if not seeded then
    math.randomseed(os.time() + vim.uv.os_getpid())
    seeded = true
  end
  counter = counter + 1
  return ('n-%x%04x%x'):format(os.time() % 0xffffff, math.random(0, 0xffff), counter % 0xf)
end

--- Exact bytes the buffer would be written as, so `git hash-object` agrees with git.
---@param buf integer
---@return string
function M.buf_text(buf)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local ff = vim.bo[buf].fileformat
  local sep = ff == 'dos' and '\r\n' or (ff == 'mac' and '\r' or '\n')
  local text = table.concat(lines, sep)
  if vim.bo[buf].endofline and not (#lines == 1 and lines[1] == '' and vim.bo[buf].buftype ~= '') then
    text = text .. sep
  end
  return text
end

---@param buf integer
---@return string[]
function M.buf_lines(buf)
  return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
end

--- Split raw file bytes into lines the way a buffer would hold them.
---@param text string
---@return string[]
function M.text_lines(text)
  text = text:gsub('\r\n', '\n')
  local lines = vim.split(text, '\n', { plain = true })
  if #lines > 0 and lines[#lines] == '' then
    table.remove(lines)
  end
  return lines
end

---@param lines string[]
---@return string
function M.lines_text(lines)
  if #lines == 0 then
    return ''
  end
  return table.concat(lines, '\n') .. '\n'
end

--- Wrap `text` to `width` display cells, keeping each paragraph's indent.
---@param text string
---@param width integer
---@return string[]
function M.wrap(text, width)
  width = math.max(width, 20)
  local out = {}
  for _, para in ipairs(vim.split(text or '', '\n', { plain = true })) do
    local indent = para:match('^%s*') or ''
    local body = para:sub(#indent + 1)
    if body == '' then
      table.insert(out, '')
    else
      local line = nil
      for word in body:gmatch('%S+') do
        if not line then
          line = indent .. word
        elseif vim.fn.strdisplaywidth(line .. ' ' .. word) <= width then
          line = line .. ' ' .. word
        else
          table.insert(out, line)
          line = indent .. word
        end
      end
      if line then
        table.insert(out, line)
      end
    end
  end
  if #out == 0 then
    out = { '' }
  end
  return out
end

--- Per-key debouncer. Returns a function `(key, fn)`.
---@param ms integer
function M.debouncer(ms)
  local timers = {}
  return function(key, fn)
    local t = timers[key]
    if t then
      t:stop()
      t:close()
    end
    t = vim.uv.new_timer()
    timers[key] = t
    t:start(ms, 0, function()
      t:stop()
      t:close()
      timers[key] = nil
      vim.schedule(fn)
    end)
  end
end

--- Buffers currently displayed in some window.
---@return integer[]
function M.visible_buffers()
  local seen, out = {}, {}
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local buf = vim.api.nvim_win_get_buf(win)
    if not seen[buf] then
      seen[buf] = true
      table.insert(out, buf)
    end
  end
  return out
end

--- Width available for note text in `buf`.
---
--- Extmarks are per buffer, but the same buffer can be on screen in several
--- windows at once — a review tab's narrow diff half and a full-width window in
--- another tab, say. The narrowest one wins, so what is drawn fits everywhere.
---@param buf integer
---@return integer
function M.buf_width(buf)
  local width
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(win) == buf then
      local info = vim.fn.getwininfo(win)[1]
      if info then
        local usable = info.width - (info.textoff or 0)
        width = math.min(width or usable, usable)
      end
    end
  end
  return math.max(width or 80, 20)
end

return M
