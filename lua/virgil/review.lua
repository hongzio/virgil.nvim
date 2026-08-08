--- The review view: a changeset expanded into per-file diff tabs.
--- virgil renders no diff of its own — both sides are ordinary buffers and
--- Neovim's own diff mode does the work.
local config = require('virgil.config')
local git = require('virgil.git')
local util = require('virgil.util')

local M = {}

--- One review at a time per Neovim instance; starting another replaces it.
M.state = nil ---@type table|nil

M.tabs = {} ---@type table<integer, table>

local function tab_of(path)
  if not M.state then
    return nil
  end
  local tab = M.state.tabs[path]
  if tab and vim.api.nvim_tabpage_is_valid(tab) then
    return tab
  end
  M.state.tabs[path] = nil
  return nil
end

--- Highlight a blob buffer without setting 'filetype', so no language server
--- tries to attach to a buffer that has no file behind it.
local function highlight(buf, path)
  local how = config.options.review.highlight
  if not how then
    return
  end
  local ft = vim.filetype.match({ filename = path, buf = buf })
  if not ft then
    return
  end
  if how == 'filetype' then
    vim.bo[buf].filetype = ft
    return
  end
  local lang = vim.treesitter.language.get_lang(ft) or ft
  if not pcall(vim.treesitter.start, buf, lang) then
    pcall(function()
      vim.bo[buf].syntax = ft
    end)
  end
end

--- Read-only buffer holding one blob's content.
---@param repo table
---@param sha string|nil nil / all-zero means "no content on this side"
---@param path string
---@param rev string|nil label used in the buffer name
---@param side string 'old'|'new'
---@param review string|nil review spec this buffer belongs to
---@return integer buf
function M.blob_buf(repo, sha, path, rev, side, review)
  local label = git.is_null(sha) and 'empty' or tostring(sha):sub(1, 7)
  local name = ('virgil://%s/%s'):format(label, path)

  local buf
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_get_name(b) == name then
      buf = b
      break
    end
  end
  if not buf then
    buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(buf, name)
    local lines = git.is_null(sha) and {} or (git.blob_lines(repo, sha) or {})
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].buftype = 'nofile'
    vim.bo[buf].bufhidden = 'hide'
    vim.bo[buf].swapfile = false
    vim.bo[buf].modifiable = false
    vim.bo[buf].modified = false
    highlight(buf, path)
  end

  if git.is_null(sha) then
    -- an empty side has no content address at all; keep it out of projection
    vim.b[buf].virgil_empty = true
  else
    vim.b[buf].virgil_view = {
      blob = sha,
      path = path,
      root = repo.root,
      rev = rev,
      side = side,
      review = review,
    }
  end
  return buf
end

--- Buffer for the new side. A real file whenever the file on disk *is* the new
--- content, so LSP, treesitter and editing all work.
---@return integer buf, boolean is_file
local function new_side_buf(repo, entry, head, spec)
  local abs = git.abs(repo, entry.path)
  local on_disk = vim.uv.fs_stat(abs) ~= nil

  -- opened under a cwd-relative name, so tab labels stay readable
  local function file_buf()
    return vim.fn.bufadd(vim.fn.fnamemodify(abs, ':.')), true
  end

  if not head and on_disk then
    -- reviewing against the worktree: the file *is* the new side, and it has no
    -- blob address — that is exactly why `new_sha` is all zeros here
    return file_buf()
  end
  if git.is_null(entry.new_sha) or not on_disk then
    return M.blob_buf(repo, entry.new_sha, entry.path, head or 'worktree', 'new', spec), false
  end
  if git.hash_file(repo, abs) == entry.new_sha then
    -- the file on disk *is* the head content, so it can be the editable side
    return file_buf()
  end
  return M.blob_buf(repo, entry.new_sha, entry.path, head, 'new', spec), false
end

--- Collect the changeset.
---@param repo table
---@param base string
---@param head string|nil
---@param paths string[]|nil
---@return table[] files
local function collect(repo, base, head, paths)
  local raw = git.diff_raw(repo, base, head, paths)
  local stats = git.diff_numstat(repo, base, head, paths)
  local files = {}
  for _, e in ipairs(raw) do
    if e.path and e.path ~= '' then
      local st = stats[e.path] or { added = 0, removed = 0 }
      table.insert(files, {
        path = e.path,
        old_path = e.old_path,
        status = e.status,
        old_sha = e.old_sha,
        new_sha = e.new_sha,
        added = st.added,
        removed = st.removed,
      })
    end
  end
  table.sort(files, function(a, b)
    return a.path < b.path
  end)
  return files
end

--- `...` when the diff was taken from the merge base, git's own notation for it.
---@param base string|nil
---@param head string|nil
---@param three_dot boolean|nil
local function spec_of(base, head, three_dot)
  return ('%s%s%s'):format(base or 'HEAD', three_dot and '...' or '..', head or 'worktree')
end

--- Start a review.
---@param opts table `{ base, head, paths, repo }`
---@return table|nil state
function M.start(opts)
  opts = opts or {}
  local repo = opts.repo or git.repo(vim.api.nvim_buf_get_name(0)) or git.repo(vim.uv.cwd())
  if not repo then
    util.err('not inside a git repository')
    return nil
  end
  local base = opts.base or 'HEAD'
  local head = opts.head
  if head == '' then
    head = nil
  end

  -- resolve now and keep the result: `HEAD` and branch names move, and a note
  -- written here has to be able to name this exact changeset later
  local base_sha = git.rev_commit(repo, base)
  if not base_sha then
    util.err(('unknown revision in %s: %s'):format(repo.root, base))
    return nil
  end
  local head_sha
  if head then
    head_sha = git.rev_commit(repo, head)
    if not head_sha then
      util.err(('unknown revision in %s: %s'):format(repo.root, head))
      return nil
    end
  end

  -- A changeset is measured from where the two histories parted, not from the
  -- tip of the base branch. Once the base moves on, a plain two-dot diff folds
  -- the base's own new commits into the review backwards — files the change
  -- never touched, shown as if this change reverted them. This is git's
  -- `base...head`, and the diff a forge shows for a pull request.
  local diff_base = base_sha
  if head_sha then
    diff_base = git.merge_base(repo, base_sha, head_sha) or base_sha
  end
  local spec = spec_of(base, head, head_sha ~= nil)

  local files = collect(repo, diff_base, head, opts.paths)
  if #files == 0 then
    util.notify(('no changes in %s'):format(spec))
    return nil
  end

  if M.state then
    M.close({ keep_notes = true })
  end

  M.state = {
    repo = repo,
    base = base, -- as typed
    head = head, -- as typed; nil is the working tree
    base_sha = diff_base, -- the commit the old side is actually taken from
    head_sha = head_sha,
    paths = opts.paths,
    spec = spec,
    files = files,
    tabs = {},
  }

  M.open_file(files[1].path)
  util.notify(('%s · %d file%s'):format(M.state.spec, #files, #files == 1 and '' or 's'))
  return M.state
end

---@param path string
---@return table|nil entry
function M.entry(path)
  if not M.state then
    return nil
  end
  for _, f in ipairs(M.state.files) do
    if f.path == path then
      return f
    end
  end
  return nil
end

--- Open (or jump to) the diff tab for one file.
---@param path string
---@return boolean ok
function M.open_file(path)
  local st = M.state
  if not st then
    util.warn('no review is open')
    return false
  end
  local entry = M.entry(path)
  if not entry then
    util.warn(('%s is not part of %s'):format(path, st.spec))
    return false
  end

  local existing = tab_of(path)
  if existing then
    vim.api.nvim_set_current_tabpage(existing)
    return true
  end

  local old_buf = M.blob_buf(st.repo, entry.old_sha, entry.old_path or entry.path, st.base_sha, 'old', st.spec)
  local new_buf, is_file = new_side_buf(st.repo, entry, st.head, st.spec)

  vim.cmd('tabnew')
  local tab = vim.api.nvim_get_current_tabpage()
  local right = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(right, new_buf)
  if is_file then
    vim.bo[new_buf].buflisted = true
    vim.fn.bufload(new_buf)
  end

  vim.cmd(config.options.review.layout == 'horizontal' and 'aboveleft split' or 'aboveleft vsplit')
  local left = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(left, old_buf)

  for _, win in ipairs({ left, right }) do
    vim.api.nvim_win_call(win, function()
      vim.wo.wrap = false
      vim.cmd('diffthis')
    end)
  end

  vim.t[tab].virgil_review = path
  st.tabs[path] = tab
  M.tabs[tab] = {
    path = path,
    spec = st.spec,
    base = st.base,
    head = st.head,
    base_sha = st.base_sha,
    head_sha = st.head_sha,
    paths = st.paths,
    left = left,
    right = right,
    left_buf = old_buf,
    right_buf = new_buf,
    entry = entry,
  }

  vim.api.nvim_set_current_win(right)
  vim.api.nvim_win_call(right, function()
    vim.cmd('normal! gg')
    pcall(vim.cmd, 'normal! ]c')
  end)

  local render = require('virgil.render')
  render.render(old_buf)
  render.render(new_buf)
  return true
end

--- Move `delta` files through the changeset (`]f` / `[f`).
---@param delta integer
function M.cycle_file(delta)
  local st = M.state
  if not st then
    util.warn('no review is open')
    return
  end
  local current = vim.t[vim.api.nvim_get_current_tabpage()].virgil_review
  local idx = 1
  for i, f in ipairs(st.files) do
    if f.path == current then
      idx = i
      break
    end
  end
  local target = ((idx - 1 + delta) % #st.files) + 1
  M.open_file(st.files[target].path)
end

--- Review metadata for a buffer, used to stamp `context` on new notes and to
--- decide emphasis while rendering.
---@param buf integer
---@return table|nil `{ spec, side, path, base, head, base_sha, head_sha, paths }`
function M.context_for_buf(buf)
  for tab, data in pairs(M.tabs) do
    if vim.api.nvim_tabpage_is_valid(tab) then
      local side
      if data.right_buf == buf then
        side = 'new'
      elseif data.left_buf == buf then
        side = 'old'
      end
      if side then
        return {
          spec = data.spec,
          side = side,
          path = data.path,
          base = data.base,
          head = data.head,
          base_sha = data.base_sha,
          head_sha = data.head_sha,
          paths = data.paths,
        }
      end
    else
      M.tabs[tab] = nil
    end
  end
  return nil
end

--- The other half of the diff pair `buf` belongs to, if any.
---
--- Only while that half is actually on screen. Splitting a note across two
--- sides is a way of drawing it once when both are in front of you; if the
--- other side is not displayed, the same rule would hand the note to a buffer
--- nobody is looking at, and it would simply vanish.
---@param buf integer
---@return integer|nil
function M.sibling_buf(buf)
  for tab, data in pairs(M.tabs) do
    if vim.api.nvim_tabpage_is_valid(tab) then
      local sibling
      if data.right_buf == buf then
        sibling = data.left_buf
      elseif data.left_buf == buf then
        sibling = data.right_buf
      end
      if sibling and util.buf_is_displayed(sibling) then
        return sibling
      end
    else
      M.tabs[tab] = nil
    end
  end
  return nil
end

--- Does `context` name the same changeset as `other`?
---
--- Two reviews of the same two commits are the same review even when they were
--- spelled differently — `origin/main..abc123` and `main..abc123` — so the
--- recorded commits decide, and the label is only a fast path (and the only
--- thing notes written before commits were recorded have).
---@param context table|nil a note's `context`
---@param other table|nil `{ spec, base_sha, head_sha }` — a review state or tab
---@return boolean
function M.same_changeset(context, other)
  if not context or not other then
    return false
  end
  if context.review and context.review == other.spec then
    return true
  end
  if not context.base or not other.base_sha then
    return false
  end
  return context.base == other.base_sha and (context.head or '') == (other.head_sha or '')
end

--- Read a `base..head` spec back into the commits it names, so a filter written
--- as `origin/main..pr-1` still matches notes recorded under another spelling.
---@param repo table
---@param spec string
---@return table `{ spec, base_sha, head_sha }`
function M.changeset_of(repo, spec)
  local out = { spec = spec }
  -- `..` and `...` both parse; the separator is a label, the rule below is not
  local base, head = spec:match('^(.-)%.%.%.?(.*)$')
  if not base then
    base, head = spec, nil
  end
  if head == '' or head == 'worktree' then
    head = nil
  end
  if base ~= '' then
    out.base_sha = git.rev_commit(repo, base)
  end
  if head then
    out.head_sha = git.rev_commit(repo, head)
  end
  -- same rule `start` uses, or a filter would name the base branch's tip while
  -- the notes recorded the commit the two histories parted at
  if out.base_sha and out.head_sha then
    out.base_sha = git.merge_base(repo, out.base_sha, out.head_sha) or out.base_sha
  end
  return out
end

--- `@@ -a,b +c,d @@ <enclosing line>` for the hunk around `line`.
--- The enclosing line uses git's default rule: nearest line above that starts
--- with an identifier character in column 1.
---@param buf integer
---@param line integer
---@return string|nil
function M.hunk_header(buf, line)
  local ctx = M.context_for_buf(buf)
  if not ctx then
    return nil
  end
  local side = ctx.side
  local data
  for _, d in pairs(M.tabs) do
    if d.right_buf == buf or d.left_buf == buf then
      data = d
      break
    end
  end
  if not data then
    return nil
  end
  local old = util.buf_lines(data.left_buf)
  local new = util.buf_lines(data.right_buf)
  local hunks = vim.diff(util.lines_text(old), util.lines_text(new), { result_type = 'indices', algorithm = 'histogram' })
  if not hunks then
    return nil
  end
  for _, h in ipairs(hunks) do
    local sa, ca, sb, cb = h[1], h[2], h[3], h[4]
    local start = side == 'old' and sa or sb
    local count = side == 'old' and ca or cb
    local last = count > 0 and (start + count - 1) or start
    if line >= start and line <= last + 1 then
      local ctx = ''
      local hay = side == 'old' and old or new
      for i = math.min(start, #hay), 1, -1 do
        local l = hay[i]
        if l and l:match('^[%a_$]') then
          ctx = ' ' .. l
          break
        end
      end
      return ('@@ -%d,%d +%d,%d @@%s'):format(sa, ca, sb, cb, ctx)
    end
  end
  return nil
end

--- Changed files with their stats and note counts.
---@return table[]
function M.files()
  local st = M.state
  if not st then
    return {}
  end
  local store = require('virgil.store')
  local out = {}
  for _, f in ipairs(st.files) do
    table.insert(out, {
      path = f.path,
      status = f.status,
      added = f.added,
      removed = f.removed,
      notes = #store.for_path(st.repo, f.path),
      open = tab_of(f.path) ~= nil,
    })
  end
  return out
end

--- Tear the review down (`:Virgil quit`).
---@param opts table|nil
function M.close(opts)
  opts = opts or {}
  local st = M.state
  if not st then
    return
  end
  local review_tabs = {}
  local count = 0
  for _, tab in pairs(st.tabs) do
    if vim.api.nvim_tabpage_is_valid(tab) and not review_tabs[tab] then
      review_tabs[tab] = true
      count = count + 1
    end
  end
  -- never leave the user with zero tabs
  if count > 0 and count == #vim.api.nvim_list_tabpages() then
    vim.cmd('tabnew')
  end
  for tab in pairs(review_tabs) do
    if vim.api.nvim_tabpage_is_valid(tab) then
      pcall(vim.cmd, vim.api.nvim_tabpage_get_number(tab) .. 'tabclose!')
    end
    M.tabs[tab] = nil
  end

  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    local name = vim.api.nvim_buf_get_name(buf)
    if vim.startswith(name, 'virgil://') and not vim.startswith(name, 'virgil://note/') then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
  end

  M.state = nil
  if not opts.keep_notes then
    require('virgil.render').refresh()
  end
end

return M
