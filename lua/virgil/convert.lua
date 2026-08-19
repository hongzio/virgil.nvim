--- Note <-> external format conversion.
---
--- `agent-context` mirrors hunk's `--agent-context` sidecar:
--- `files[].annotations[]` with a `newRange`, a summary and a rationale.
local git = require('virgil.git')
local store = require('virgil.store')
local util = require('virgil.util')

local M = {}

---@param notes table[]
---@return table
function M.to_agent_context(notes)
  local by_path, order = {}, {}
  for _, note in ipairs(notes) do
    local path = note.anchor.path or ''
    if not by_path[path] then
      by_path[path] = {}
      table.insert(order, path)
    end
    local replies
    for _, reply in ipairs(note.replies or {}) do
      replies = replies or {}
      table.insert(replies, {
        id = reply.id,
        author = reply.author ~= '' and reply.author or nil,
        body = reply.body,
        created_at = reply.created_at,
      })
    end
    table.insert(by_path[path], {
      newRange = { start = note.anchor.line, ['end'] = note.anchor.end_line or note.anchor.line },
      summary = note.summary,
      rationale = note.rationale ~= '' and note.rationale or nil,
      author = note.author ~= '' and note.author or nil,
      status = note.status,
      id = note.id,
      replies = replies,
    })
  end
  table.sort(order)
  local files = {}
  for _, path in ipairs(order) do
    table.sort(by_path[path], function(a, b)
      return a.newRange.start < b.newRange.start
    end)
    table.insert(files, { path = path, annotations = by_path[path] })
  end
  return { version = 1, generator = 'virgil.nvim', files = files }
end

---@param notes table[]
---@return string
function M.to_markdown(notes)
  local out = {}
  local current
  table.sort(notes, function(a, b)
    if a.anchor.path == b.anchor.path then
      return a.anchor.line < b.anchor.line
    end
    return (a.anchor.path or '') < (b.anchor.path or '')
  end)
  for _, note in ipairs(notes) do
    if note.anchor.path ~= current then
      current = note.anchor.path
      table.insert(out, ('\n## %s\n'):format(current))
    end
    local span = note.anchor.end_line ~= note.anchor.line and ('%d-%d'):format(note.anchor.line, note.anchor.end_line) or tostring(note.anchor.line)
    table.insert(out, ('- **L%s** %s  `%s`'):format(span, note.summary, note.status))
    if note.rationale ~= '' then
      for _, l in ipairs(vim.split(note.rationale, '\n', { plain = true })) do
        table.insert(out, '  ' .. l)
      end
    end
    -- nested under the note, which is what a reply is
    for _, reply in ipairs(note.replies or {}) do
      local lines = vim.split(reply.body, '\n', { plain = true })
      table.insert(out, ('  - **%s** %s'):format(reply.author ~= '' and reply.author or '?', lines[1] or ''))
      for i = 2, #lines do
        table.insert(out, '    ' .. lines[i])
      end
    end
  end
  return table.concat(out, '\n') .. '\n'
end

--- Write notes out.
---@param notes table[]
---@param opts table `{ format, out }`
---@return string|nil path_or_payload
function M.export(notes, opts)
  opts = opts or {}
  local format = opts.format or 'agent-context'
  local payload
  if format == 'agent-context' then
    payload = vim.json.encode(M.to_agent_context(notes))
  elseif format == 'json' then
    payload = vim.json.encode({ version = store.VERSION, notes = notes })
  elseif format == 'markdown' then
    payload = M.to_markdown(notes)
  else
    util.err('unknown export format: ' .. tostring(format))
    return nil
  end

  local out = opts.out
  if not out then
    return payload
  end
  out = vim.fs.normalize(vim.fn.fnamemodify(out, ':p'))
  vim.fn.mkdir(vim.fs.dirname(out), 'p')
  local fd = io.open(out, 'w')
  if not fd then
    util.err('cannot write ' .. out)
    return nil
  end
  fd:write(payload)
  fd:close()
  return out
end

--- Read notes from an external file and anchor them to current content.
---@param repo table
---@param opts table `{ file, format, author, changeset }`
---@return integer imported
function M.import(repo, opts)
  opts = opts or {}
  local file = opts.file and vim.fs.normalize(vim.fn.fnamemodify(opts.file, ':p'))
  if not file then
    util.err('import needs a file')
    return 0
  end
  local fd = io.open(file, 'r')
  if not fd then
    util.err('cannot read ' .. file)
    return 0
  end
  local content = fd:read('*a')
  fd:close()
  local ok, data = pcall(vim.json.decode, content, { luanil = { object = true, array = true } })
  if not ok or type(data) ~= 'table' then
    util.err('not valid JSON: ' .. file)
    return 0
  end

  local anchor = require('virgil.anchor')
  local count = 0

  --- Anchor into the current content of `path`, loading it if needed.
  local function view_for(path)
    local abs = git.abs(repo, path)
    if not vim.uv.fs_stat(abs) then
      return nil
    end
    local buf = vim.fn.bufadd(abs)
    vim.fn.bufload(buf)
    return anchor.view(buf)
  end

  if type(data.notes) == 'table' and data.version then
    -- native export: keep the anchors as they are
    for _, note in ipairs(data.notes) do
      if type(note) == 'table' and note.anchor then
        note.id = nil
        store.add(repo, note)
        count = count + 1
      end
    end
    return count
  end

  for _, f in ipairs(data.files or {}) do
    local view = view_for(f.path)
    for _, ann in ipairs((f.annotations or {})) do
      local range = ann.newRange or ann.range or {}
      local line = tonumber(range.start or range[1]) or 1
      local endl = tonumber(range['end'] or range[2]) or line
      local a
      if view then
        a = anchor.make(view, line, endl)
      else
        a = { kind = 'worktree', path = f.path, line = line, end_line = endl, text = '', before = {}, after = {} }
      end
      -- ids are not carried over: they are this repository's to hand out, and
      -- the store fills in whatever is missing
      local replies = {}
      for _, reply in ipairs(ann.replies or {}) do
        if type(reply) == 'table' then
          table.insert(replies, {
            author = reply.author or '',
            body = reply.body or reply.text or '',
            created_at = reply.created_at,
          })
        end
      end
      store.add(repo, {
        anchor = a,
        author = ann.author or opts.author or 'import',
        summary = ann.summary or ann.title or '',
        rationale = ann.rationale or ann.body or '',
        status = ann.status or 'open',
        created_at = util.now(),
        context = opts.changeset and { changeset = opts.changeset } or nil,
        replies = replies,
      })
      count = count + 1
    end
  end
  return count
end

return M
