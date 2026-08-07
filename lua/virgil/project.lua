--- Projection: notes are stored against an anchor and their position in
--- any given view is computed at render time with `vim.diff`.
local git = require('virgil.git')
local util = require('virgil.util')

local M = {}

local map_cache = {} ---@type table<string, table>

--- Content the anchor was written against, if it is still obtainable.
---@param repo table
---@param a table anchor
---@return string[]|nil
function M.anchor_lines(repo, a)
  if a.kind == 'blob' then
    return git.blob_lines(repo, a.blob)
  end
  if not a.hash then
    return nil
  end
  if git.have_object(repo, a.hash) then
    return git.blob_lines(repo, a.hash)
  end
  -- Uncommitted content has no address in git, but it is still right there in
  -- the editor: a buffer on the same path that still hashes to `a.hash` *is*
  -- the content this note was written against.
  local anchor = require('virgil.anchor')
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) then
      local v = anchor.view(buf)
      if v and v.kind == 'file' and v.path == a.path and v.repo.common == repo.common and anchor.content_sha(v) == a.hash then
        return anchor.lines(v)
      end
    end
  end
  return nil
end

---@param a table anchor
---@return string
local function anchor_key(a)
  if a.kind == 'blob' then
    return 'b:' .. (a.blob or '?')
  end
  return 'w:' .. (a.hash or a.path or '?')
end

---@param view table
---@return string
local function view_key(view)
  if view.kind == 'blob' then
    return 'b:' .. view.blob
  end
  return ('f:%d:%d'):format(view.buf, vim.api.nvim_buf_get_changedtick(view.buf))
end

--- Hunk list between anchor content and view content, cached per (anchor, view).
--- Cheap check first: identical content needs no diff at all.
---@return table[]|nil hunks nil means "identical"
local function hunks_for(a, src, view, dst)
  local key = anchor_key(a) .. '|' .. view_key(view)
  local hit = map_cache[key]
  if hit then
    return hit.hunks
  end
  local src_text = util.lines_text(src)
  local dst_text = util.lines_text(dst)
  local hunks
  if src_text ~= dst_text then
    hunks = vim.diff(src_text, dst_text, { result_type = 'indices', algorithm = 'histogram' })
  end
  map_cache[key] = { hunks = hunks }
  return hunks
end

--- Map one line from anchor content to view content.
--- Three rules, and only three: outside every hunk the line shifts by
--- the accumulated offset; inside a hunk it was rewritten or deleted, so it is
--- stale; hunks after the line are irrelevant.
---@param hunks table[]|nil
---@param line integer
---@return integer mapped, boolean inside_hunk, boolean deleted
function M.map_line(hunks, line)
  if not hunks then
    return line, false, false
  end
  local delta = 0
  for _, h in ipairs(hunks) do
    local sa, ca, sb, cb = h[1], h[2], h[3], h[4]
    if ca == 0 then
      -- pure insertion after A line `sa`
      if sa < line then
        delta = delta + cb
      else
        break
      end
    else
      local last = sa + ca - 1
      if last < line then
        delta = delta + (cb - ca)
      elseif line < sa then
        break
      else
        -- the anchored line itself was touched
        if cb == 0 then
          -- nothing replaced it: this content does not exist in the view at all
          return sb + 1, true, true
        end
        return math.min(sb + (line - sa), sb + cb - 1), true, false
      end
    end
  end
  return line + delta, false, false
end

--- Fallback location search when the anchor content is gone.
--- Requires an exact (then whitespace-insensitive) match of `anchor.text`;
--- candidates are scored by how much recorded context still surrounds them,
--- with adjacent lines weighing most, and ties broken by proximity to the
--- recorded line number.
---@param a table anchor
---@param lines string[]
---@return integer|nil
function M.search(a, lines)
  if not a.text or a.text == '' then
    return nil
  end
  local function scan(eq)
    local best, best_score
    for i, l in ipairs(lines) do
      if eq(l, a.text) then
        local score = 0
        local before = a.before or {}
        for k = 1, #before do
          local want = before[#before - k + 1]
          if lines[i - k] and eq(lines[i - k], want) then
            score = score + (4 - math.min(k, 3))
          end
        end
        for k = 1, #(a.after or {}) do
          if lines[i + k] and eq(lines[i + k], a.after[k]) then
            score = score + (4 - math.min(k, 3))
          end
        end
        local total = score * 1000 - math.abs(i - a.line)
        if not best_score or total > best_score then
          best, best_score = i, total
        end
      end
    end
    return best
  end

  local exact = scan(function(x, y)
    return x == y
  end)
  if exact then
    return exact
  end
  return scan(function(x, y)
    return vim.trim(x) == vim.trim(y) and vim.trim(x) ~= ''
  end)
end

--- Where (if anywhere) does `note` land in `view`?
---@param view table
---@param note table
---@return table|nil `{ line, end_line, status = 'ok'|'stale'|'orphan', exact, fallback }`
function M.project(view, note)
  local a = note.anchor
  if not a then
    return nil
  end

  -- Same blob: the note is at exactly the line it was written on, forever.
  if a.kind == 'blob' and view.kind == 'blob' and a.blob == view.blob then
    return { line = a.line, end_line = a.end_line, status = 'ok', exact = true }
  end

  if a.path ~= view.path then
    return nil
  end

  local dst = require('virgil.anchor').lines(view)
  local total = math.max(#dst, 1)
  local src = M.anchor_lines(view.repo, a)

  if not src then
    local found = M.search(a, dst)
    if found then
      local span = a.end_line - a.line
      local stale = dst[found] ~= a.text
      return {
        line = found,
        end_line = math.min(found + span, total),
        status = stale and 'stale' or 'ok',
        fallback = true,
      }
    end
    if view.kind ~= 'file' then
      -- A recorded line number means "the file as it is now"; pinning it onto
      -- some other revision's blob would be a guess, not a projection.
      return nil
    end
    return {
      line = math.min(a.line, total),
      end_line = math.min(a.end_line, total),
      status = 'orphan',
    }
  end

  local hunks = hunks_for(a, src, view, dst)
  if not hunks then
    return { line = math.min(a.line, total), end_line = math.min(a.end_line, total), status = 'ok', exact = true }
  end

  local sline, s_inside, s_gone = M.map_line(hunks, a.line)
  local eline, e_inside, e_gone = M.map_line(hunks, a.end_line)
  if s_gone and e_gone then
    -- the anchored lines were deleted outright: there is no content here to
    -- hang the note on, so it simply does not project into this view.
    -- It stays exactly where it belongs — on the old side.
    return nil
  end
  local stale = s_inside or e_inside or eline < sline
  sline = math.min(math.max(sline, 1), total)
  eline = math.min(math.max(eline, sline), total)

  return { line = sline, end_line = eline, status = stale and 'stale' or 'ok' }
end

--- Every note that lands in `view`, sorted by line.
---@param view table
---@return table[] `{ note = …, pos = … }`
function M.visible(view)
  local store = require('virgil.store')
  local seen, out = {}, {}

  local function consider(note)
    if seen[note.id] then
      return
    end
    local pos = M.project(view, note)
    if pos then
      seen[note.id] = true
      table.insert(out, { note = note, pos = pos })
    end
  end

  for _, note in ipairs(store.for_path(view.repo, view.path)) do
    consider(note)
  end
  -- notes anchored to this very blob under a different path (renames)
  if view.kind == 'blob' then
    for _, note in ipairs(store.all(view.repo)) do
      if note.anchor.kind == 'blob' and note.anchor.blob == view.blob then
        consider(note)
      end
    end
  end

  table.sort(out, function(x, y)
    if x.pos.line == y.pos.line then
      return (x.note.created_at or '') < (y.note.created_at or '')
    end
    return x.pos.line < y.pos.line
  end)
  return out
end

function M.clear_cache()
  map_cache = {}
end

return M
