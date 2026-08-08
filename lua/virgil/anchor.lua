--- Content addressing and anchor hardening.
---
--- A *view* is any buffer virgil can attach notes to. It has exactly one content
--- address: a blob sha (immutable) or a worktree path (mutable).
local config = require('virgil.config')
local git = require('virgil.git')
local util = require('virgil.util')

local M = {}

local sha_cache = {} ---@type table<integer, {tick:integer, sha:string|nil}>

--- Resolve the content address of a buffer.
---@param buf integer|nil
---@return table|nil view `{ buf, repo, kind = 'blob'|'file', path, blob?, file?, rev?, side?, review? }`
function M.view(buf)
  if buf == nil or buf == 0 then
    buf = vim.api.nvim_get_current_buf()
  end
  if not vim.api.nvim_buf_is_valid(buf) then
    return nil
  end

  local marked = vim.b[buf].virgil_view
  if type(marked) == 'table' and marked.blob then
    local repo = git.repo(marked.root)
    if not repo then
      return nil
    end
    return {
      buf = buf,
      repo = repo,
      kind = 'blob',
      blob = marked.blob,
      path = marked.path,
      rev = marked.rev,
      side = marked.side,
      review = marked.review,
    }
  end

  if vim.bo[buf].buftype ~= '' then
    return nil
  end
  local name = vim.api.nvim_buf_get_name(buf)
  if name == '' then
    return nil
  end
  local repo = git.repo(name)
  if not repo then
    return nil
  end
  local rel = git.rel(repo, name)
  if not rel then
    return nil
  end
  local view = { buf = buf, repo = repo, kind = 'file', path = rel, file = vim.fs.normalize(name) }
  -- a worktree file shown as the new side of a review is still a plain file
  -- buffer; it just knows which review it is being read under
  local ok, review = pcall(require, 'virgil.review')
  if ok then
    local ctx = review.context_for_buf(buf)
    if ctx then
      view.review, view.side = ctx.spec, ctx.side
    end
  end
  return view
end

---@param view table
---@return string[]
function M.lines(view)
  return util.buf_lines(view.buf)
end

--- The blob sha this view's *current* content hashes to, if git has such an object.
--- For blob views this is free; for file views it costs one `git hash-object`,
--- cached per changedtick.
---@param view table
---@return string|nil
function M.content_sha(view)
  if view.kind == 'blob' then
    return view.blob
  end
  local tick = vim.api.nvim_buf_get_changedtick(view.buf)
  local hit = sha_cache[view.buf]
  if hit and hit.tick == tick then
    return hit.sha
  end
  local sha = git.hash_object(view.repo, util.buf_text(view.buf), view.file)
  sha_cache[view.buf] = { tick = tick, sha = sha }
  return sha
end

--- Build an anchor for `line`..`end_line` of `view`.
---@param view table
---@param line integer
---@param end_line integer|nil
---@return table anchor
function M.make(view, line, end_line)
  local lines = M.lines(view)
  local total = math.max(#lines, 1)
  line = math.min(math.max(line, 1), total)
  end_line = math.min(math.max(end_line or line, line), total)

  local ctx = config.options.context_lines
  local before, after = {}, {}
  for i = math.max(1, line - ctx), line - 1 do
    table.insert(before, lines[i] or '')
  end
  for i = end_line + 1, math.min(total, end_line + ctx) do
    table.insert(after, lines[i] or '')
  end

  local anchor = {
    path = view.path,
    line = line,
    end_line = end_line,
    text = lines[line] or '',
    before = before,
    after = after,
  }

  if view.kind == 'blob' then
    anchor.kind = 'blob'
    anchor.blob = view.blob
    return anchor
  end

  -- A worktree buffer whose content already exists as an object gets the
  -- immutable address for free — that is the "clean file read" case.
  local sha = M.content_sha(view)
  if sha and git.have_object(view.repo, sha) then
    anchor.kind = 'blob'
    anchor.blob = sha
  else
    anchor.kind = 'worktree'
    anchor.hash = sha
  end
  return anchor
end

--- Refresh the fallback material of an anchor from `lines`.
local function refresh_context(anchor, lines)
  local ctx = config.options.context_lines
  anchor.text = lines[anchor.line] or anchor.text
  local before, after = {}, {}
  for i = math.max(1, anchor.line - ctx), anchor.line - 1 do
    table.insert(before, lines[i] or '')
  end
  for i = anchor.end_line + 1, math.min(#lines, anchor.end_line + ctx) do
    table.insert(after, lines[i] or '')
  end
  anchor.before, anchor.after = before, after
end

--- Promote `worktree` anchors to `blob` anchors once the content is in the
--- odb. Returns how many notes were hardened.
---@param view table
---@return integer
function M.harden(view)
  if not view or view.kind ~= 'file' then
    return 0
  end
  local store = require('virgil.store')
  local project = require('virgil.project')
  local notes = store.for_path(view.repo, view.path)

  local pending = {}
  for _, note in ipairs(notes) do
    if note.anchor.kind == 'worktree' then
      table.insert(pending, note)
    end
  end
  if #pending == 0 then
    return 0
  end

  local sha = M.content_sha(view)
  local buffer_is_object = sha and git.have_object(view.repo, sha)
  local lines = M.lines(view)
  local hardened = 0

  for _, note in ipairs(pending) do
    local a = note.anchor
    if a.hash and a.hash ~= sha and git.have_object(view.repo, a.hash) then
      -- the exact content the note was written against got committed
      a.kind = 'blob'
      a.blob = a.hash
      a.hash = nil
      hardened = hardened + 1
    elseif buffer_is_object then
      -- content moved on before it was committed: re-anchor where the note
      -- projects onto the content that *did* get an address
      local pos = project.project(view, note)
      if pos and pos.status ~= 'orphan' then
        a.kind = 'blob'
        a.blob = sha
        a.hash = nil
        a.line, a.end_line = pos.line, pos.end_line
        refresh_context(a, lines)
        hardened = hardened + 1
      end
    end
  end

  if hardened > 0 then
    store.save(view.repo)
  end
  return hardened
end

--- Human-readable content address, for `status()`.
---@param view table|nil
---@return string
function M.describe(view)
  if not view then
    return 'none'
  end
  if view.kind == 'blob' then
    return ('blob:%s'):format(view.blob:sub(1, 12))
  end
  -- a file buffer whose content git already knows has the immutable address too
  local sha = M.content_sha(view)
  if sha and git.have_object(view.repo, sha) then
    return ('blob:%s'):format(sha:sub(1, 12))
  end
  return ('worktree:%s'):format(view.path)
end

function M.forget(buf)
  sha_cache[buf] = nil
end

return M
