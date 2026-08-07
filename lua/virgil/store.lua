--- Note persistence. Disk is the source of truth:
--- one `<git-common-dir>/virgil/notes.json` per repository.
local util = require('virgil.util')

local M = {}

M.VERSION = 1

local states = {} ---@type table<string, table>

---@param repo table
---@return string
function M.path(repo)
  return vim.fs.joinpath(repo.common, 'virgil', 'notes.json')
end

local function mtime_of(file)
  local st = vim.uv.fs_stat(file)
  return st and (st.mtime.sec * 1e9 + st.mtime.nsec) or 0
end

local function read_file(file)
  local fd = io.open(file, 'r')
  if not fd then
    return nil
  end
  local content = fd:read('*a')
  fd:close()
  return content
end

local function decode(content)
  if not content or vim.trim(content) == '' then
    return nil
  end
  local ok, data = pcall(vim.json.decode, content, { luanil = { object = true, array = true } })
  if not ok or type(data) ~= 'table' then
    return nil
  end
  return data
end

--- Normalize a decoded note so the rest of the code never guards for missing fields.
local function normalize(note)
  if type(note) ~= 'table' or type(note.anchor) ~= 'table' or type(note.id) ~= 'string' then
    return nil
  end
  local a = note.anchor
  a.kind = a.kind == 'worktree' and 'worktree' or 'blob'
  a.line = tonumber(a.line) or 1
  a.end_line = tonumber(a.end_line) or a.line
  a.before = type(a.before) == 'table' and a.before or {}
  a.after = type(a.after) == 'table' and a.after or {}
  a.text = a.text or ''
  note.summary = note.summary or ''
  note.rationale = note.rationale or ''
  note.status = note.status or 'open'
  note.author = note.author or ''
  note.created_at = note.created_at or util.now()
  if type(note.context) ~= 'table' then
    note.context = nil
  end
  return note
end

local function index(state)
  state.by_id = {}
  state.by_path = {}
  for _, note in ipairs(state.notes) do
    state.by_id[note.id] = note
    local p = note.anchor.path or ''
    state.by_path[p] = state.by_path[p] or {}
    table.insert(state.by_path[p], note)
  end
end

--- Load (or reload, if the file changed underneath us) a repo's notes.
---@param repo table
---@return table state
function M.state(repo)
  local file = M.path(repo)
  local state = states[repo.common]
  local mtime = mtime_of(file)
  if state and state.mtime == mtime then
    return state
  end

  local data = decode(read_file(file))
  local notes = {}
  if data and type(data.notes) == 'table' then
    for _, raw in ipairs(data.notes) do
      local note = normalize(raw)
      if note then
        table.insert(notes, note)
      end
    end
  end
  state = { repo = repo, file = file, mtime = mtime, notes = notes }
  index(state)
  states[repo.common] = state
  return state
end

--- Encode with one note per line: this file lives in `.git`, humans read it.
local function encode(state)
  local parts = { '{\n  "version": ' .. M.VERSION .. ',\n  "notes": [' }
  for i, note in ipairs(state.notes) do
    local copy = vim.deepcopy(note)
    local a = copy.anchor
    if a.kind == 'worktree' then
      a.blob = nil
    end
    if #(a.before or {}) == 0 then
      a.before = nil
    end
    if #(a.after or {}) == 0 then
      a.after = nil
    end
    if copy.rationale == '' then
      copy.rationale = nil
    end
    table.insert(parts, (i == 1 and '\n    ' or ',\n    ') .. vim.json.encode(copy))
  end
  table.insert(parts, (#state.notes > 0 and '\n  ' or '') .. ']\n}\n')
  return table.concat(parts)
end

--- Write the notes back, merging in anything another instance added meanwhile.
---@param repo table
---@return boolean ok
function M.save(repo)
  local state = states[repo.common]
  if not state then
    return false
  end
  local file = state.file

  local disk_mtime = mtime_of(file)
  if disk_mtime ~= state.mtime then
    local data = decode(read_file(file))
    if data and type(data.notes) == 'table' then
      local merged = {}
      local ours = {}
      for _, n in ipairs(state.notes) do
        ours[n.id] = n
      end
      for _, raw in ipairs(data.notes) do
        local note = normalize(raw)
        if note and not ours[note.id] and not (state.deleted and state.deleted[note.id]) then
          table.insert(merged, note)
        end
      end
      vim.list_extend(merged, state.notes)
      state.notes = merged
      index(state)
    end
  end

  local dir = vim.fs.dirname(file)
  vim.fn.mkdir(dir, 'p')
  local tmp = file .. '.tmp'
  local fd = io.open(tmp, 'w')
  if not fd then
    util.err('cannot write ' .. file)
    return false
  end
  fd:write(encode(state))
  fd:close()
  local ok = vim.uv.fs_rename(tmp, file)
  if not ok then
    os.remove(tmp)
    util.err('cannot replace ' .. file)
    return false
  end
  state.mtime = mtime_of(file)
  return true
end

---@param repo table
---@return table[]
function M.all(repo)
  return M.state(repo).notes
end

---@param repo table
---@param path string
---@return table[]
function M.for_path(repo, path)
  return M.state(repo).by_path[path or ''] or {}
end

---@param repo table
---@param id string
---@return table|nil
function M.get(repo, id)
  return M.state(repo).by_id[id]
end

--- Insert a note and flush to disk.
---@param repo table
---@param note table
---@return table note
function M.add(repo, note)
  local state = M.state(repo)
  while not note.id or state.by_id[note.id] do
    note.id = util.uid()
  end
  table.insert(state.notes, note)
  index(state)
  M.save(repo)
  return note
end

--- Apply `fields` to a note and flush.
---@param repo table
---@param id string
---@param fields table
---@return table|nil
function M.update(repo, id, fields)
  local state = M.state(repo)
  local note = state.by_id[id]
  if not note then
    return nil
  end
  for k, v in pairs(fields) do
    if v == vim.NIL then
      note[k] = nil
    else
      note[k] = v
    end
  end
  note.updated_at = util.now()
  index(state)
  M.save(repo)
  return note
end

---@param repo table
---@param ids string[]|string
---@return integer removed
function M.remove(repo, ids)
  if type(ids) == 'string' then
    ids = { ids }
  end
  local state = M.state(repo)
  local drop = {}
  for _, id in ipairs(ids) do
    drop[id] = true
  end
  local kept, removed = {}, 0
  for _, note in ipairs(state.notes) do
    if drop[note.id] then
      removed = removed + 1
    else
      table.insert(kept, note)
    end
  end
  if removed > 0 then
    state.deleted = state.deleted or {}
    for id in pairs(drop) do
      state.deleted[id] = true
    end
    state.notes = kept
    index(state)
    M.save(repo)
  end
  return removed
end

--- Drop every cached state (tests).
function M.reset()
  states = {}
end

return M
