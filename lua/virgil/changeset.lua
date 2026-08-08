--- A changeset: two revisions expanded into per-file diff tabs.
--- virgil renders no diff of its own — both sides are ordinary buffers and
--- Neovim's own diff mode does the work.
local config = require('virgil.config')
local git = require('virgil.git')
local util = require('virgil.util')

local M = {}

--- One changeset at a time per Neovim instance; starting another replaces it.
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
  local how = config.options.changeset.highlight
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
---@param changeset string|nil changeset spec this buffer belongs to
---@return integer buf
function M.blob_buf(repo, sha, path, rev, side, changeset)
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
      changeset = changeset,
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

--- Start reviewing a changeset.
---@param opts table `{ base, head, paths, repo, title }`
--- `title` is a human-readable name for this changeset — a pull request's
--- `#7 fix the retry loop` rather than the two revisions it resolves to. It is
--- recorded on the notes written here and shown when they are offered back,
--- and takes no part in identifying the changeset.
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
  -- the base's own new commits into the changeset backwards — files the change
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
    title = opts.title,
    files = files,
    tabs = {},
  }

  -- configured on, it starts on; configured off, a manual toggle still carries
  -- across changesets rather than being reset under you
  if config.options.changeset.sidebar then
    M.sidebar_toggle(true)
  end
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

------------------------------------------------------------------- sidebar
--
-- A changeset is one tab per file, so "the sidebar" is really one window per tab
-- showing one shared buffer. It is off by default and follows you from tab to
-- tab rather than being rebuilt: what changes between tabs is which row is
-- marked current, and that is a redraw, not a window.

local sidebar = { on = false, buf = nil, wins = {}, rows = {} }
local SIDEBAR_NS = vim.api.nvim_create_namespace('virgil.sidebar')

local function sidebar_buf()
  if sidebar.buf and vim.api.nvim_buf_is_valid(sidebar.buf) then
    return sidebar.buf
  end
  local buf = vim.api.nvim_create_buf(false, true)
  pcall(vim.api.nvim_buf_set_name, buf, 'virgil://changeset/files')
  vim.bo[buf].buftype = 'nofile'
  vim.bo[buf].bufhidden = 'hide'
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = 'virgil-files'
  vim.keymap.set('n', '<CR>', function()
    M.sidebar_open_under_cursor()
  end, { buffer = buf, nowait = true, desc = 'virgil: open this file' })
  vim.keymap.set('n', 'q', function()
    M.sidebar_toggle(false)
  end, { buffer = buf, nowait = true, desc = 'virgil: close the file list' })
  sidebar.buf = buf
  return buf
end

--- Keep the tail of a path: the file name says more than the repository root.
local function shorten(path, budget)
  if budget < 4 or vim.fn.strdisplaywidth(path) <= budget then
    return path
  end
  local chars = vim.fn.strcharlen(path)
  return '…' .. vim.fn.strcharpart(path, chars - (budget - 1))
end

local function sidebar_render()
  local buf = sidebar_buf()
  local width = config.options.changeset.sidebar_width
  local current = vim.t[vim.api.nvim_get_current_tabpage()].virgil_changeset
  local lines, tails = {}, {}
  sidebar.rows = {}

  -- widths are display cells (▸ and ♦ are one cell but several bytes); extmark
  -- columns are byte offsets. Mixing the two is what makes a column wobble.
  local dw = vim.fn.strdisplaywidth
  for _, f in ipairs(M.files()) do
    local head = ('%s %s '):format(f.path == current and '▸' or ' ', f.status)
    local tail = ('+%d -%d%s'):format(f.added, f.removed, f.notes > 0 and ('  %d♦'):format(f.notes) or '')
    local name = shorten(f.path, width - dw(head) - dw(tail) - 2)
    local pad = math.max(width - dw(head) - dw(name) - dw(tail) - 1, 1)
    table.insert(lines, head .. name .. string.rep(' ', pad) .. tail)
    table.insert(tails, { row = #lines - 1, from = #head + #name + pad, current = f.path == current })
    table.insert(sidebar.rows, f.path)
  end

  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(buf, SIDEBAR_NS, 0, -1)
  for _, t in ipairs(tails) do
    if t.current then
      vim.api.nvim_buf_set_extmark(buf, SIDEBAR_NS, t.row, 0, { end_row = t.row + 1, hl_group = 'VirgilSummary' })
    end
    vim.api.nvim_buf_set_extmark(buf, SIDEBAR_NS, t.row, t.from, { end_row = t.row + 1, hl_group = 'VirgilDim' })
  end
end

local function open_sidebar_win()
  local prev = vim.api.nvim_get_current_win()
  vim.cmd('topleft vsplit')
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, sidebar_buf())
  -- a split off a diff window inherits 'diff'; a file list is not a revision
  vim.wo[win].diff = false
  vim.wo[win].wrap = false
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = 'no'
  vim.wo[win].winfixwidth = true
  vim.wo[win].cursorline = true
  vim.api.nvim_win_set_width(win, config.options.changeset.sidebar_width)
  -- a vsplit takes its width out of the current window alone, which would
  -- leave the two halves of the diff lopsided. 'winfixwidth' holds the list at
  -- its column while the rest is shared out evenly.
  vim.cmd('wincmd =')
  if vim.api.nvim_win_is_valid(prev) then
    vim.api.nvim_set_current_win(prev)
  end
  return win
end

--- Bring this tab in line with whether the sidebar is on. Cheap enough to call
--- on every tab switch and after any change to the notes.
function M.sidebar_sync()
  for tab, win in pairs(sidebar.wins) do
    if not vim.api.nvim_tabpage_is_valid(tab) or not vim.api.nvim_win_is_valid(win) then
      sidebar.wins[tab] = nil
    end
  end

  local tab = vim.api.nvim_get_current_tabpage()
  local want = sidebar.on and M.state ~= nil and M.tabs[tab] ~= nil
  if not want then
    local win = sidebar.wins[tab]
    if win and vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_close, win, true)
    end
    sidebar.wins[tab] = nil
    return
  end
  if not sidebar.wins[tab] then
    sidebar.wins[tab] = open_sidebar_win()
  end
  sidebar_render()
end

--- Show or hide the changeset's file list. Returns the state it settled on.
---@param to boolean|nil nil toggles
---@return boolean on
function M.sidebar_toggle(to)
  if to == nil then
    sidebar.on = not sidebar.on
  else
    sidebar.on = to and true or false
  end
  if not sidebar.on then
    -- close every tab's, not just this one: a stranded list in a tab you have
    -- not visited yet reads as the toggle having failed
    for tab, win in pairs(sidebar.wins) do
      if vim.api.nvim_win_is_valid(win) then
        pcall(vim.api.nvim_win_close, win, true)
      end
      sidebar.wins[tab] = nil
    end
  end
  M.sidebar_sync()
  return sidebar.on
end

function M.sidebar_open_under_cursor()
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local path = sidebar.rows[row]
  if path then
    M.open_file(path)
  end
end

--- Open (or jump to) the diff tab for one file.
---@param path string
---@return boolean ok
function M.open_file(path)
  local st = M.state
  if not st then
    util.warn('no changeset is open')
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
    M.sidebar_sync()
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

  vim.cmd(config.options.changeset.layout == 'horizontal' and 'aboveleft split' or 'aboveleft vsplit')
  local left = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(left, old_buf)

  for _, win in ipairs({ left, right }) do
    vim.api.nvim_win_call(win, function()
      vim.wo.wrap = false
      vim.cmd('diffthis')
    end)
  end

  vim.t[tab].virgil_changeset = path
  st.tabs[path] = tab
  M.tabs[tab] = {
    path = path,
    spec = st.spec,
    title = st.title,
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
  M.sidebar_sync()
  return true
end

--- Move `delta` files through the changeset (`]f` / `[f`).
---@param delta integer
function M.cycle_file(delta)
  local st = M.state
  if not st then
    util.warn('no changeset is open')
    return
  end
  local current = vim.t[vim.api.nvim_get_current_tabpage()].virgil_changeset
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
          title = data.title,
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

--- Changesets worth reviewing, in the order you are most likely to want them:
--- what is uncommitted, what you already left notes on, what this branch adds,
--- then recent commits.
---
--- Pure data. The picker that shows these lives in the command layer, so
--- nothing here blocks on a human — agents call `review()` with revisions.
---@param repo table
---@return table[] `{ kind, label, detail, base, head }`
function M.candidates(repo)
  local out = {}

  local dirty = git.diff_numstat(repo, 'HEAD', nil, nil)
  local n = vim.tbl_count(dirty)
  if n > 0 then
    table.insert(out, {
      kind = 'worktree',
      label = 'uncommitted changes',
      detail = ('%d file%s'):format(n, n == 1 and '' or 's'),
      base = 'HEAD',
    })
  end

  -- changesets that already hold notes: the way back to what an agent left behind
  local store = require('virgil.store')
  local seen, changesets = {}, {}
  for _, note in ipairs(store.all(repo)) do
    local c = note.context
    if c and c.base then
      local key = c.base .. '|' .. (c.head or '')
      if not seen[key] then
        seen[key] = { kind = 'notes', label = c.changeset or key, base = c.base, head = c.head, count = 0 }
        table.insert(changesets, seen[key])
      end
      -- a name beats the spelling of two revisions wherever in the group it
      -- turns up, so re-opening a changeset and leaving one more note cannot
      -- rename the row back to a pair of shas
      if c.title and not seen[key].title then
        seen[key].label, seen[key].title = c.title, c.title
      end
      seen[key].count = seen[key].count + 1
    end
  end
  for _, r in ipairs(changesets) do
    -- a changeset whose commits are gone would only fail at open time
    local alive = git.rev_commit(repo, r.base) and (not r.head or git.rev_commit(repo, r.head))
    if alive then
      r.detail = ('%d note%s'):format(r.count, r.count == 1 and '' or 's')
      r.count = nil
      table.insert(out, r)
    end
  end

  local upstream = git.upstream(repo)
  if upstream then
    local branch = git.branch(repo) or 'HEAD'
    table.insert(out, {
      kind = 'branch',
      label = ('%s...%s'):format(upstream, branch),
      detail = 'what this branch adds',
      base = upstream,
      head = branch,
    })
  end

  -- asking gh costs a network round trip, so it is a row you choose, not one
  -- the list waits for
  if require('virgil.forge').available(repo) then
    table.insert(out, { kind = 'pr', label = 'pull requests…', detail = 'ask gh' })
  end

  for _, c in ipairs(git.log(repo, 10)) do
    -- a root commit has no `^` to diff against
    if #c.parents > 0 then
      table.insert(out, {
        kind = 'commit',
        label = ('%s %s'):format(c.short, c.subject),
        detail = ('%s · %s'):format(c.author, c.when),
        base = c.sha .. '^',
        head = c.sha,
      })
    end
  end

  return out
end

--- Does `context` name the same changeset as `other`?
---
--- Two changesets over the same two commits are the same changeset even when
--- spelled differently — `origin/main..abc123` and `main..abc123` — so the
--- recorded commits decide, and the label is only a fast path (and the only
--- thing notes written before commits were recorded have).
---@param context table|nil a note's `context`
---@param other table|nil `{ spec, base_sha, head_sha }` — a changeset state or tab
---@return boolean
function M.same_changeset(context, other)
  if not context or not other then
    return false
  end
  if context.changeset and context.changeset == other.spec then
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

--- Tear the changeset down (`:Virgil quit`).
---@param opts table|nil
function M.close(opts)
  opts = opts or {}
  local st = M.state
  if not st then
    return
  end
  -- the tabs are about to go; the list windows in them go with the tabs
  for tab in pairs(sidebar.wins) do
    sidebar.wins[tab] = nil
  end
  local changeset_tabs = {}
  local count = 0
  for _, tab in pairs(st.tabs) do
    if vim.api.nvim_tabpage_is_valid(tab) and not changeset_tabs[tab] then
      changeset_tabs[tab] = true
      count = count + 1
    end
  end
  -- never leave the user with zero tabs
  if count > 0 and count == #vim.api.nvim_list_tabpages() then
    vim.cmd('tabnew')
  end
  for tab in pairs(changeset_tabs) do
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
