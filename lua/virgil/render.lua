--- Rendering: notes float above the code as `virt_lines`, so the
--- real text — and therefore diff alignment — is never touched.
local config = require('virgil.config')
local project = require('virgil.project')
local util = require('virgil.util')

local M = {}

M.mode = nil ---@type string|nil 'default' | 'all' | 'off'

--- `bufnr -> { {line, id, status}, … }` sorted by line; drives ]n / [n.
M.placed = {}

local debounce = util.debouncer(60)

local function mode()
  if not M.mode then
    M.mode = config.options.visibility or 'default'
  end
  return M.mode
end

local STATUS_HL = {
  stale = 'VirgilStale',
  orphan = 'VirgilOrphan',
  resolved = 'VirgilResolved',
  wontfix = 'VirgilResolved',
}

--- Should this note be drawn at all, and how loud?
---@return boolean show, boolean dim
local function visibility(note, pos, view)
  local m = mode()
  if m == 'off' then
    return false, false
  end
  local closed = note.status == 'resolved' or note.status == 'wontfix'
  if m ~= 'all' and closed then
    return false, false
  end

  local review = require('virgil.review')
  local current = review.state
  local from_review = note.context and note.context.review or nil

  if view.review then
    -- inside a review tab: this review's own notes are the loud ones
    local mine = review.same_changeset(note.context, current or { spec = view.review })
    return true, from_review ~= nil and not mine
  end
  -- ordinary buffer: notes belonging to the review that is currently open are
  -- background context, not the point of this screen
  local dim = current ~= nil and review.same_changeset(note.context, current)
  return true, dim or (pos.status == 'orphan' and m ~= 'all')
end

--- Is `view` the very content this anchor addresses?
---@param view table|nil
---@param a table anchor
---@return boolean
local function addressed_by(view, a)
  if not view then
    return false
  end
  if a.kind == 'worktree' then
    -- a worktree anchor's address is the live file, whatever it says now
    return view.kind == 'file' and a.path == view.path
  end
  if view.kind == 'blob' then
    return a.blob == view.blob
  end
  return a.path == view.path and a.blob == require('virgil.anchor').content_sha(view)
end

--- Inside a diff pair a note belongs to exactly one side.
---
--- Without this, a note written on the new side also lands on the old side —
--- inside a hunk, so marked `stale`. That reading is wrong: `stale` means the
--- line changed *after* the note was written, and here nothing
--- changed; we are just looking at the other revision. Since a review shows two
--- revisions of the same lines side by side, the note is drawn once.
---
--- The side that kept the anchored line intact wins. Only when neither did does
--- the content address decide, and a tie goes to the new side — that is the
--- real file, the half being read and edited. Ownership is deliberately decided
--- per line rather than per file: an edit anywhere in a file changes its sha,
--- and addressing alone would then march every note in it over to the old side.
---@return boolean
local function owns_note(view, other, note, pos)
  if not other then
    return true
  end
  local other_pos = project.project(other, note)
  if not other_pos then
    return true
  end
  if (pos.status == 'ok') ~= (other_pos.status == 'ok') then
    return pos.status == 'ok'
  end
  if pos.status ~= 'ok' then
    -- the line is intact on neither side; the note belongs to the revision it
    -- was written against
    if addressed_by(view, note.anchor) then
      return true
    end
    if addressed_by(other, note.anchor) then
      return false
    end
  end
  return view.side ~= 'old'
end

--- Display width of a leading-whitespace run, so tab-indented code lines up.
---@param ws string
---@param tabstop integer
---@return integer
local function indent_width(ws, tabstop)
  local w = 0
  for i = 1, #ws do
    if ws:sub(i, i) == '\t' then
      w = w + (tabstop - (w % tabstop))
    else
      w = w + 1
    end
  end
  return w
end

--- Frame styles. Order follows `nvim_open_win`'s border: top-left, top,
--- top-right, right, bottom-right, bottom, bottom-left, left.
local BORDERS = {
  single = { '┌', '─', '┐', '│', '┘', '─', '└', '│' },
  rounded = { '╭', '─', '╮', '│', '╯', '─', '╰', '│' },
  double = { '╔', '═', '╗', '║', '╝', '═', '╚', '║' },
  heavy = { '┏', '━', '┓', '┃', '┛', '━', '┗', '┃' },
}

---@param spec string|table|boolean
---@return table|nil chars nil means "no frame"
local function border_chars(spec)
  if type(spec) == 'table' and #spec >= 8 then
    return spec
  end
  return BORDERS[spec]
end

local strw = vim.fn.strdisplaywidth

--- What a note has to say, in the order it is said.
---@return table body `{ {text, hl}, … }`
---@return table title `{icon, hl}`
---@return table meta `{ {text, hl}, … }`
local function material(note, pos, cfg, width)
  local badges = {}
  if pos.status == 'stale' then
    table.insert(badges, 'stale')
  elseif pos.status == 'orphan' then
    table.insert(badges, 'orphan')
  end
  if note.status ~= 'open' then
    table.insert(badges, note.status)
  end

  local meta = {}
  if #badges > 0 then
    table.insert(meta, { '[' .. table.concat(badges, '] [') .. ']', STATUS_HL[pos.status] or 'VirgilResolved' })
  end
  if cfg.show_author and note.author ~= '' then
    table.insert(meta, { note.author, 'VirgilAuthor' })
  end

  local body = {}
  if cfg.show_rationale and note.rationale and note.rationale ~= '' then
    for _, l in ipairs(util.wrap(note.rationale, width)) do
      table.insert(body, { l, 'VirgilRationale' })
    end
  end
  if pos.status == 'stale' or pos.status == 'orphan' then
    local original = vim.trim(note.anchor.text or '')
    if original ~= '' then
      table.insert(body, { '~ ' .. original, 'VirgilStale' })
    end
  end

  local title = { cfg.icon, STATUS_HL[pos.status] or STATUS_HL[note.status] or 'VirgilIcon' }
  return body, title, meta
end

---@param parts table[] `{ {text, hl}, … }`
---@return string
local function joined(parts, sep)
  local out = {}
  for _, p in ipairs(parts) do
    table.insert(out, p[1])
  end
  return table.concat(out, sep or ' ')
end

--- The note as a framed box drawn above the code line.
---
--- The summary rides in the top border, so a note with only a summary costs two
--- screen lines instead of three. When it is too long to fit there the border
--- goes plain and the summary wraps into the body — nothing is ever truncated.
local function framed_block(note, pos, opts, chars)
  local cfg = config.options.render
  local function hl(group)
    return opts.dim and 'VirgilDim' or group
  end
  local B = function(s)
    return { s, hl('VirgilBorder') }
  end

  local indent = string.rep(' ', opts.indent)
  local avail = math.max(math.min(opts.width - opts.indent, cfg.max_width), 16)
  local inner = avail - 4 -- "│ " … " │"

  local summary = note.summary ~= '' and note.summary or '(no summary)'
  local body, title, meta = material(note, pos, cfg, inner)
  local meta_text = joined(meta)

  -- assemble the two ends of the top border, then let the dashes take the slack
  local function chunks_width(list)
    local w = 0
    for _, c in ipairs(list) do
      w = w + strw(c[1])
    end
    return w
  end

  local function ends(with_title, with_meta)
    local left = { B(chars[1] .. chars[2] .. ' ') }
    if with_title then
      table.insert(left, { title[1] .. ' ', hl(title[2]) })
      table.insert(left, { summary .. ' ', hl('VirgilSummary') })
    end
    local right = {}
    if with_meta and meta_text ~= '' then
      table.insert(right, B(' '))
      for i, part in ipairs(meta) do
        table.insert(right, { (i > 1 and ' ' or '') .. part[1], hl(part[2]) })
      end
      table.insert(right, B(' '))
    end
    table.insert(right, B(chars[2] .. chars[3]))
    return left, right
  end

  -- Whatever still fits on the top border stays there; the rest drops into the
  -- body. Nothing is truncated, and the frame never runs past the window.
  local left, right, in_border, meta_in_border
  for _, try in ipairs({ { true, true }, { false, true }, { false, false } }) do
    left, right = ends(try[1], try[2])
    in_border, meta_in_border = try[1], try[2]
    if chunks_width(left) + 1 + chunks_width(right) <= avail then
      break
    end
  end

  if not meta_in_border and meta_text ~= '' then
    table.insert(body, { meta_text, meta[1] and meta[1][2] or 'VirgilAuthor' })
  end
  if not in_border then
    local wrapped = util.wrap(summary, math.max(inner - strw(title[1]) - 1, 8))
    for i = #wrapped, 1, -1 do
      table.insert(body, 1, { (i == 1 and (title[1] .. ' ') or '  ') .. wrapped[i], 'VirgilSummary' })
    end
  end

  local width = chunks_width(left) + 1 + chunks_width(right)
  for _, line in ipairs(body) do
    width = math.max(width, strw(line[1]) + 4)
  end
  width = math.min(math.max(width, 8), avail)

  local pad_chunk = function(text)
    return indent ~= '' and { { indent, 'VirgilBorder' }, text } or { text }
  end

  local out = {}

  local top = pad_chunk(left[1])
  for i = 2, #left do
    table.insert(top, left[i])
  end
  table.insert(top, B(string.rep(chars[2], math.max(width - chunks_width(left) - chunks_width(right), 1))))
  for _, c in ipairs(right) do
    table.insert(top, c)
  end
  table.insert(out, top)

  for _, line in ipairs(body) do
    local pad = math.max(width - 4 - strw(line[1]), 0)
    local row = pad_chunk(B(chars[8] .. ' '))
    table.insert(row, { line[1], hl(line[2]) })
    table.insert(row, B(string.rep(' ', pad) .. ' ' .. chars[4]))
    table.insert(out, row)
  end

  table.insert(out, pad_chunk(B(chars[7] .. string.rep(chars[6], math.max(width - 2, 1)) .. chars[5])))
  return out
end

--- The unframed style: a bar in the left margin, one line per thought.
local function bar_block(note, pos, opts)
  local cfg = config.options.render
  local function hl(group)
    return opts.dim and 'VirgilDim' or group
  end
  local indent = string.rep(' ', opts.indent)
  local prefix = cfg.border == 'none' and '' or (cfg.prefix .. ' ')
  local bar = { indent .. prefix, hl('VirgilSign') }
  local width = math.min(opts.width - opts.indent - 4, cfg.max_width)

  local summary = util.wrap(note.summary ~= '' and note.summary or '(no summary)', width)
  local body, title, meta = material(note, pos, cfg, width)

  local out = {}
  local head = { bar, { title[1] .. ' ', hl(title[2]) }, { summary[1], hl('VirgilSummary') } }
  for _, part in ipairs(meta) do
    table.insert(head, { ' · ' .. part[1], hl(part[2]) })
  end
  table.insert(out, head)
  for i = 2, #summary do
    table.insert(out, { bar, { '  ' .. summary[i], hl('VirgilSummary') } })
  end
  for _, line in ipairs(body) do
    table.insert(out, { bar, { '  ' .. line[1], hl(line[2]) } })
  end
  return out
end

---@param note table
---@param pos table
---@param opts table
---@return table[] virt_lines
local function block(note, pos, opts)
  local chars = border_chars(config.options.render.border)
  if chars then
    return framed_block(note, pos, opts, chars)
  end
  return bar_block(note, pos, opts)
end

--- Draw every note that projects into `buf`.
---@param buf integer
function M.render(buf)
  if buf == nil or buf == 0 then
    buf = vim.api.nvim_get_current_buf()
  end
  if not vim.api.nvim_buf_is_valid(buf) or not vim.api.nvim_buf_is_loaded(buf) then
    return
  end
  vim.api.nvim_buf_clear_namespace(buf, util.NS, 0, -1)
  M.placed[buf] = nil

  local view = require('virgil.anchor').view(buf)
  if not view then
    return
  end

  local ok, items = pcall(project.visible, view)
  if not ok then
    return
  end

  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local total = math.max(#lines, 1)
  local width = util.buf_width(buf)
  local cfg = config.options.render
  local placed = {}

  local sibling = require('virgil.review').sibling_buf(buf)
  local other = sibling and require('virgil.anchor').view(sibling) or nil

  for _, item in ipairs(items) do
    local show, dim = visibility(item.note, item.pos, view)
    show = show and owns_note(view, other, item.note, item.pos)
    if show then
      local line = math.min(math.max(item.pos.line, 1), total)
      local indent = 0
      if cfg.align_indent then
        indent = math.min(indent_width((lines[line] or ''):match('^%s*') or '', vim.bo[buf].tabstop), 40)
      end
      local virt = block(item.note, item.pos, { dim = dim, indent = indent, width = width })
      vim.api.nvim_buf_set_extmark(buf, util.NS, line - 1, 0, {
        virt_lines = virt,
        virt_lines_above = true,
        priority = 200,
      })
      table.insert(placed, { line = line, id = item.note.id, status = item.pos.status })
    end
  end

  M.placed[buf] = placed
end

--- Debounced render, safe to call from autocmds.
---@param buf integer
function M.schedule(buf)
  if buf == nil or buf == 0 then
    buf = vim.api.nvim_get_current_buf()
  end
  debounce(buf, function()
    M.render(buf)
  end)
end

--- Re-render everything on screen; call after any change to the note store.
function M.refresh()
  project.clear_cache()
  for _, buf in ipairs(util.visible_buffers()) do
    M.render(buf)
  end
  -- the review's file list carries per-file note counts, so it is stale too
  local review = require('virgil.review')
  if review.state then
    review.sidebar_sync()
  end
end

--- Cycle visibility: default -> all -> off.
---@param to string|nil
---@return string
function M.toggle(to)
  local order = { default = 'all', all = 'off', off = 'default' }
  M.mode = to or order[mode()] or 'default'
  M.refresh()
  return M.mode
end

--- Notes drawn in `buf`, in line order.
---@param buf integer
---@return table[]
function M.notes_in(buf)
  if buf == nil or buf == 0 then
    buf = vim.api.nvim_get_current_buf()
  end
  return M.placed[buf] or {}
end

--- The note nearest to `line` in `buf`. Deliberately forgiving: a note hangs
--- *above* its line, so the cursor is rarely exactly on it.
---@param buf integer
---@param line integer
---@return table|nil
function M.note_at(buf, line)
  local best, dist
  for _, p in ipairs(M.notes_in(buf)) do
    local d = math.abs(p.line - line)
    if not dist or d < dist then
      best, dist = p, d
    end
  end
  return best
end

return M
