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

--- A field that is only ever a non-empty string, or absent. Anything else on
--- disk — a hand-edited `notes.json` saying `"question": "yes"` — is nothing.
---@param v any
---@return string|nil
local function str_or_nil(v)
  return type(v) == 'string' and v ~= '' and v or nil
end

--- A reply carries no anchor of its own: it points at the note, and the note
--- points at the code. Anything without words to say is not a reply.
---@param reply any
---@return table|nil
local function normalize_reply(reply)
  if type(reply) ~= 'table' then
    return nil
  end
  reply.body = type(reply.body) == 'string' and reply.body or ''
  if vim.trim(reply.body) == '' then
    return nil
  end
  if type(reply.id) ~= 'string' or reply.id == '' then
    reply.id = util.uid('r')
  end
  reply.author = reply.author or ''
  reply.created_at = reply.created_at or util.now()
  -- a reply that asks rather than answers, and the link back to what it answers
  reply.question = reply.question == true or nil
  reply.answers = str_or_nil(reply.answers)
  -- which agent session produced this answer, so a follow-up can carry on in it
  reply.session = str_or_nil(reply.session)
  reply.agent = str_or_nil(reply.agent)
  return reply
end

--- Replace `note.replies` with a list the rest of the code can walk without
--- guarding: every entry has an id, an author and something to say.
---@param note table
---@return table note
local function normalize_replies(note)
  local out, seen = {}, {}
  if type(note.replies) == 'table' then
    for _, raw in ipairs(note.replies) do
      local reply = normalize_reply(raw)
      if reply and not seen[reply.id] then
        seen[reply.id] = true
        table.insert(out, reply)
      end
    end
  end
  note.replies = out
  return note
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
  note.question = note.question == true or nil
  if type(note.context) ~= 'table' then
    note.context = nil
  end
  return normalize_replies(note)
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
    if #(copy.replies or {}) == 0 then
      copy.replies = nil
    end
    table.insert(parts, (i == 1 and '\n    ' or ',\n    ') .. vim.json.encode(copy))
  end
  table.insert(parts, (#state.notes > 0 and '\n  ' or '') .. ']\n}\n')
  return table.concat(parts)
end

--- Take the replies another instance wrote and we have not seen.
---
--- Everywhere else the note we hold wins outright, and it has to: two
--- instances editing one note's words leaves no way to tell which wording is
--- the later one. Replies are different — they are only ever appended, so both
--- sides can be kept and put back in the order they were written. Only the ones
--- deleted here stay deleted.
---@param ours table
---@param theirs table
---@param dropped table<string, boolean>|nil
local function merge_replies(ours, theirs, dropped)
  local have = {}
  for _, reply in ipairs(ours.replies or {}) do
    have[reply.id] = true
  end
  local added = false
  for _, reply in ipairs(theirs.replies or {}) do
    if not have[reply.id] and not (dropped and dropped[reply.id]) then
      ours.replies = ours.replies or {}
      table.insert(ours.replies, reply)
      added = true
    end
  end
  if added then
    -- the timestamps are ISO-8601 UTC, so sorting them as strings is sorting
    -- them as times
    table.sort(ours.replies, function(a, b)
      if a.created_at == b.created_at then
        return a.id < b.id
      end
      return (a.created_at or '') < (b.created_at or '')
    end)
  end
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
        if note and ours[note.id] then
          merge_replies(ours[note.id], note, state.dropped_replies)
        elseif note and not (state.deleted and state.deleted[note.id]) then
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
  normalize_replies(note)
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
---@param note_id string
---@param reply_id string
---@return table|nil
function M.get_reply(repo, note_id, reply_id)
  local note = M.state(repo).by_id[note_id]
  for _, reply in ipairs(note and note.replies or {}) do
    if reply.id == reply_id then
      return reply
    end
  end
  return nil
end

--- Append a reply to a note and flush.
---
--- The note's `updated_at` moves with it: a thread someone answered this
--- morning is not a note nobody has touched since March, and `prune` reads that
--- field to decide what has gone cold.
---@param repo table
---@param note_id string
---@param fields table `{ body, author, created_at, question, answers, session, agent }`
---@return table|nil reply
function M.add_reply(repo, note_id, fields)
  local state = M.state(repo)
  local note = state.by_id[note_id]
  if not note then
    return nil
  end
  note.replies = note.replies or {}
  local taken = {}
  for _, reply in ipairs(note.replies) do
    taken[reply.id] = true
  end
  local reply = normalize_reply({
    id = fields.id,
    author = fields.author or '',
    body = fields.body or '',
    created_at = fields.created_at,
    question = fields.question,
    answers = fields.answers,
    session = fields.session,
    agent = fields.agent,
  })
  if not reply then
    return nil
  end
  while taken[reply.id] do
    reply.id = util.uid('r')
  end
  table.insert(note.replies, reply)
  note.updated_at = util.now()
  M.save(repo)
  return reply
end

--- Apply `fields` to one reply and flush.
---@param repo table
---@param note_id string
---@param reply_id string
---@param fields table
---@return table|nil
function M.update_reply(repo, note_id, reply_id, fields)
  local reply = M.get_reply(repo, note_id, reply_id)
  if not reply then
    return nil
  end
  -- checked before anything is written: emptying a reply is not a way to
  -- delete one, and half-applying the change would leave it wordless
  if fields.body ~= nil and vim.trim(tostring(fields.body)) == '' then
    return nil
  end
  for k, v in pairs(fields) do
    if k ~= 'id' then
      reply[k] = v ~= vim.NIL and v or nil
    end
  end
  reply.updated_at = util.now()
  M.save(repo)
  return reply
end

--- Delete one reply. Like `remove`, this is the only thing that destroys one.
---@param repo table
---@param note_id string
---@param reply_id string
---@return boolean
function M.remove_reply(repo, note_id, reply_id)
  local state = M.state(repo)
  local note = state.by_id[note_id]
  for i, reply in ipairs(note and note.replies or {}) do
    if reply.id == reply_id then
      table.remove(note.replies, i)
      -- remembered, so a merge with another instance's copy does not bring it
      -- back the moment it is written out
      state.dropped_replies = state.dropped_replies or {}
      state.dropped_replies[reply_id] = true
      note.updated_at = util.now()
      M.save(repo)
      return true
    end
  end
  return false
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
