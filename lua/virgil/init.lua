--- virgil — notes on code, for humans and agents.
---
--- Every function here is part of the control surface: the user calls them
--- through `:Virgil …`, an agent calls the same ones over the RPC socket.
local anchor = require('virgil.anchor')
local config = require('virgil.config')
local convert = require('virgil.convert')
local git = require('virgil.git')
local project = require('virgil.project')
local render = require('virgil.render')
local changeset = require('virgil.changeset')
local store = require('virgil.store')
local ui = require('virgil.ui')
local util = require('virgil.util')

local M = {}

M.socket_path = nil

---@param opts table|nil
function M.setup(opts)
  config.setup(opts)
  M.start_server()
  render.refresh()
end

--------------------------------------------------------------------------- util

local function current_repo()
  local view = anchor.view(0)
  if view then
    return view.repo
  end
  return git.repo(vim.api.nvim_buf_get_name(0)) or git.repo(vim.uv.cwd())
end

--- Buffer holding `path`, loading it if necessary.
---@param repo table
---@param path string repo-relative or absolute
---@return integer|nil buf
local function buf_for(repo, path)
  local abs = vim.startswith(path, '/') and vim.fs.normalize(path) or git.abs(repo, path)
  if not vim.uv.fs_stat(abs) then
    return nil
  end
  local buf = vim.fn.bufadd(abs)
  vim.fn.bufload(buf)
  return buf
end

--- The view a command should act on.
---@param opts table|nil
---@return table|nil view
local function target_view(opts)
  opts = opts or {}
  if opts.path and opts.path ~= '' then
    local repo = current_repo()
    if not repo then
      return nil
    end
    local buf = buf_for(repo, opts.path)
    if not buf then
      util.err('no such file: ' .. opts.path)
      return nil
    end
    return anchor.view(buf)
  end
  return anchor.view(0)
end

local function cursor_line(buf)
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(win) == buf then
      return vim.api.nvim_win_get_cursor(win)[1]
    end
  end
  return 1
end

--- Note ids to act on: an explicit id, a list of them (pickers select several),
--- or — given nothing — the note at the cursor.
---
--- `act` runs at once for everything but the last case, and there too whenever
--- the cursor names a single note. Only a genuine tie — several notes on one
--- line, or one above and one below — puts a picker up first, and then `act`
--- runs from the picker, after this function has already returned. Callers that
--- report what they did have to cope with that; nothing has happened yet by the
--- time they return.
---@param ids string|string[]|nil
---@param prompt string what the chooser is for, when one is needed
---@param act fun(ids: string[], repo: table)
local function resolve_ids(ids, prompt, act)
  local repo = current_repo()
  if not repo then
    util.err('not inside a git repository')
    return
  end
  if type(ids) == 'string' and ids ~= '' then
    return act({ ids }, repo)
  end
  if type(ids) == 'table' then
    return act(ids, repo)
  end
  local buf = vim.api.nvim_get_current_buf()
  local hits = render.notes_at(buf, vim.api.nvim_win_get_cursor(0)[1])
  if #hits == 0 then
    util.warn('no note here')
    return
  end
  if #hits == 1 then
    return act({ hits[1].id }, repo)
  end

  local items = {}
  for _, hit in ipairs(hits) do
    local note = store.get(repo, hit.id)
    table.insert(items, {
      id = hit.id,
      line = hit.line,
      -- the store is what the note actually says; `hit` only knows where it was
      -- drawn. A note removed from another instance leaves its id to show
      summary = note and note.summary or hit.id,
      state = hit.status ~= 'ok' and hit.status or (note and note.status ~= 'open' and note.status or nil),
    })
  end
  ui.select(items, {
    prompt = prompt,
    format_item = function(it)
      return ('%d  %s%s'):format(it.line, util.fit(it.summary, 60), it.state and (' (' .. it.state .. ')') or '')
    end,
  }, function(choice)
    if not choice then
      return
    end
    act({ choice.id }, repo)
  end)
end

--------------------------------------------------------------------------- api

--- What am I looking at? The first thing an agent asks.
---@return table
function M.status()
  local view = anchor.view(0)
  local buf = vim.api.nvim_get_current_buf()
  local cursor = vim.api.nvim_win_get_cursor(0)

  local out = {
    socket = M.socket_path or '',
    visibility = render.mode or config.options.visibility,
    cursor = { line = cursor[1], col = cursor[2] + 1 },
    notes = { visible = #render.notes_in(buf), total = 0 },
  }

  if not view then
    out.view = { kind = 'none', buffer = vim.api.nvim_buf_get_name(buf) }
    return out
  end

  out.repo = { root = view.repo.root, common_dir = view.repo.common }
  out.view = {
    kind = view.kind,
    address = anchor.describe(view),
    path = view.path,
    blob = view.blob,
    rev = view.rev,
    side = view.side,
    file = view.file,
    lines = vim.api.nvim_buf_line_count(buf),
  }
  out.notes.total = #store.for_path(view.repo, view.path)

  local ctx = changeset.context_for_buf(buf)
  if changeset.state then
    out.changeset = {
      spec = changeset.state.spec,
      title = changeset.state.title or '',
      base = changeset.state.base,
      head = changeset.state.head or '',
      base_sha = changeset.state.base_sha or '',
      head_sha = changeset.state.head_sha or '',
      files = #changeset.state.files,
      current = ctx and ctx.path or '',
      side = ctx and ctx.side or '',
      in_changeset = ctx ~= nil,
    }
  end
  return out
end

--- Attach a note to the current view's content address.
--- With no `summary` this opens the composer; with one it returns immediately,
--- which is the path agents take.
---@param opts table|nil `{ path, line, end_line, summary, rationale, author }`
---@return table|nil note
function M.note(opts)
  opts = opts or {}
  local view = target_view(opts)
  if not view then
    util.err('virgil: no content address for this buffer (not a file in a git repo)')
    return nil
  end

  local line = tonumber(opts.line) or cursor_line(view.buf)
  local end_line = tonumber(opts.end_line) or line
  if end_line < line then
    line, end_line = end_line, line
  end

  local rc = changeset.context_for_buf(view.buf)
  local author = opts.author or config.options.author or vim.env.USER or 'me'

  local function create(summary, rationale)
    local a = anchor.make(view, line, end_line)
    local context
    if rc then
      -- `changeset` is the label a human reads; `base`/`head` are the commits it
      -- actually meant. Refs move and `HEAD` moves, so the label alone cannot
      -- name this changeset again tomorrow.
      context = { changeset = rc.spec, base = rc.base_sha, head = rc.head_sha }
      -- what a human calls this changeset, when it has a name of its own. Like
      -- `hunk_header`, it is written down and read back out; nothing matches on it
      if rc.title and rc.title ~= '' then
        context.title = rc.title
      end
      if rc.base ~= rc.base_sha then
        context.base_ref = rc.base
      end
      if rc.head and rc.head ~= rc.head_sha then
        context.head_ref = rc.head
      end
      if rc.paths and #rc.paths > 0 then
        context.paths = vim.deepcopy(rc.paths)
      end
      local header = changeset.hunk_header(view.buf, line)
      if header then
        context.hunk_header = header
      end
    end
    local note = store.add(view.repo, {
      id = util.uid(),
      anchor = a,
      author = author,
      summary = summary,
      rationale = rationale or '',
      status = 'open',
      created_at = util.now(),
      context = context,
    })
    project.clear_cache()
    render.refresh()
    return note
  end

  if opts.summary and opts.summary ~= '' then
    return create(opts.summary, opts.rationale)
  end

  local title = ('note · %s:%s'):format(view.path, line == end_line and line or (line .. '-' .. end_line))
  ui.compose({ title = title }, function(summary, rationale)
    local note = create(summary, rationale)
    util.notify(('note %s saved'):format(note.id))
  end)
  return nil
end

--- The composer half of `edit`, reached once it is settled which note that is.
---@param repo table
---@param id string
local function edit_note(repo, id)
  local note = store.get(repo, id)
  if not note then
    util.warn('no note ' .. tostring(id))
    return nil
  end

  local a = note.anchor
  local where = a.line == a.end_line and tostring(a.line) or (a.line .. '-' .. a.end_line)
  ui.compose({
    title = ('edit · %s:%s'):format(a.path or '?', where),
    summary = note.summary,
    rationale = note.rationale,
  }, function(summary, rationale)
    -- read back through the store: the window was open for a while, and the
    -- note may have been removed from another instance meanwhile
    local updated = store.update(repo, note.id, { summary = summary, rationale = rationale })
    if not updated then
      util.warn(('note %s is gone'):format(note.id))
      return
    end
    render.refresh()
    util.notify(('note %s updated'):format(note.id))
  end)
  return nil
end

--- Which reply of `note_id` does this act on?
---
--- The same shape as `resolve_ids` one level down: an explicit id runs at once,
--- a note with one reply needs no asking, and only a real choice puts a picker
--- up — after which `act` runs once this function has already returned.
---@param repo table
---@param note_id string
---@param reply_id string|nil
---@param prompt string
---@param act fun(reply: table)
local function resolve_reply(repo, note_id, reply_id, prompt, act)
  local note = store.get(repo, note_id)
  if not note then
    util.warn('no note ' .. tostring(note_id))
    return
  end
  local replies = note.replies or {}
  if #replies == 0 then
    util.warn('that note has no replies')
    return
  end
  if type(reply_id) == 'string' and reply_id ~= '' then
    local reply = store.get_reply(repo, note_id, reply_id)
    if not reply then
      util.warn('no reply ' .. reply_id)
      return
    end
    return act(reply)
  end
  if #replies == 1 then
    return act(replies[1])
  end
  ui.select(replies, {
    prompt = prompt,
    format_item = function(r)
      return ('%s  %s'):format(util.fit(r.author ~= '' and r.author or '?', 12), util.fit((r.body:gsub('%s+', ' ')), 60))
    end,
  }, function(choice)
    if choice then
      act(choice)
    end
  end)
end

--- Answer a note. Replies hang under it inside the same box, in the order they
--- were written.
---
--- A reply is not a note of its own: it has no anchor, no status and no
--- changeset. It says something about the note, and the note is what says
--- something about the code. Deleting the note takes the thread with it.
---
--- With a `body` this returns immediately, which is the path agents take;
--- without one the composer opens, and the whole buffer is the reply.
---@param id string|nil the note to answer; omit it for the one at the cursor
---@param opts table|nil `{ body, author }`
---@return table|nil reply
function M.reply(id, opts)
  opts = opts or {}
  -- nil while a chooser is still up: nothing has been written yet
  local written = nil
  resolve_ids(id, 'reply to which note?', function(list, repo)
    if #list == 0 then
      return
    end
    local note_id = list[1]
    local note = store.get(repo, note_id)
    if not note then
      util.warn('no note ' .. tostring(note_id))
      return
    end
    local author = opts.author or config.options.author or vim.env.USER or 'me'

    local function save(body)
      -- read back through the store: the composer was open for a while, and the
      -- note may have been removed from another instance meanwhile
      local reply = store.add_reply(repo, note_id, { author = author, body = body })
      if not reply then
        util.warn(('note %s is gone'):format(note_id))
        return nil
      end
      render.refresh()
      return reply
    end

    -- whitespace is not an answer: a body of blanks opens the composer rather
    -- than writing a reply nobody can read
    local body = opts.body and vim.trim(tostring(opts.body)) or nil
    if body and body ~= '' then
      written = save(body)
      return
    end
    local subject = note.summary ~= '' and note.summary or note_id
    ui.compose({ title = ('reply · %s'):format(vim.trim(util.fit(subject, 48))), plain = true }, function(body)
      local reply = save(body)
      if reply then
        util.notify(('replied to %s'):format(note_id))
      end
    end)
  end)
  return written
end

--- Rewrite a reply, prefilled with what it says now. Both ids may be omitted:
--- the note at the cursor, and then its only reply or the one you pick.
---@param note_id string|nil
---@param reply_id string|nil
---@param fields table|nil `{ body }`
---@return table|nil
function M.update_reply(note_id, reply_id, fields)
  fields = fields or {}
  local written = nil
  resolve_ids(note_id, 'a reply on which note?', function(list, repo)
    if #list == 0 then
      return
    end
    local nid = list[1]
    resolve_reply(repo, nid, reply_id, 'edit which reply?', function(reply)
      local body = fields.body and vim.trim(tostring(fields.body)) or nil
      if body and body ~= '' then
        written = store.update_reply(repo, nid, reply.id, { body = body })
        if not written then
          util.warn(('reply %s is gone'):format(reply.id))
          return
        end
        render.refresh()
        return
      end
      local who = reply.author ~= '' and reply.author or reply.id
      ui.compose({ title = ('edit reply · %s'):format(who), plain = true, body = reply.body }, function(body)
        if not store.update_reply(repo, nid, reply.id, { body = body }) then
          util.warn(('reply %s is gone'):format(reply.id))
          return
        end
        render.refresh()
        util.notify(('reply %s updated'):format(reply.id))
      end)
    end)
  end)
  return written
end

--- Delete a reply. Like `remove`, this is not undoable, and it is the only
--- thing that destroys one — emptying the composer leaves it as it was.
---@param note_id string|nil
---@param reply_id string|nil
---@return boolean
function M.unreply(note_id, reply_id)
  local removed = false
  resolve_ids(note_id, 'a reply on which note?', function(list, repo)
    if #list == 0 then
      return
    end
    local nid = list[1]
    resolve_reply(repo, nid, reply_id, 'delete which reply?', function(reply)
      if not store.remove_reply(repo, nid, reply.id) then
        return
      end
      render.refresh()
      removed = true
      util.notify(('removed reply by %s'):format(reply.author ~= '' and reply.author or reply.id))
    end)
  end)
  return removed
end

--- Rewrite a note's text in the composer, prefilled with what it says now.
--- Only the words change: the anchor, the status and the context stay as they
--- were, so an edit never moves a note off the code it was written about.
--- Emptying the buffer cancels — `remove` is still the only thing that destroys
--- a note.
---@param id string|nil the note to edit; omit it for the one at the cursor
---@return nil
function M.edit(id)
  resolve_ids(id, 'edit which note?', function(list, repo)
    if #list > 0 then
      edit_note(repo, list[1])
    end
  end)
  return nil
end

--- Change a note in place. Agents use this to fix their own wording.
---@param id string
---@param fields table
---@return table|nil
function M.update(id, fields)
  local repo = current_repo()
  if not repo then
    return nil
  end
  local note = store.update(repo, id, fields or {})
  if not note then
    util.warn('no note ' .. tostring(id))
    return nil
  end
  render.refresh()
  return note
end

--- Query notes: stored anchor plus where they land in the current view.
---@param filter table|nil `{ path, status, changeset, id }`
---@return table[]
function M.notes(filter)
  filter = filter or {}
  local repo = current_repo()
  if not repo then
    return {}
  end
  local view = anchor.view(0)
  local path = filter.path
  if path and vim.startswith(path, '/') then
    path = git.rel(repo, path) or path
  end
  local notes = path and store.for_path(repo, path) or store.all(repo)
  -- resolved once: a changeset filter names commits, not a string to match
  local want = filter.changeset and changeset.changeset_of(repo, filter.changeset) or nil
  local out = {}
  for _, note in ipairs(notes) do
    local ok = true
    if filter.id and note.id ~= filter.id then
      ok = false
    end
    if filter.status and note.status ~= filter.status then
      ok = false
    end
    if want and not changeset.same_changeset(note.context, want) then
      ok = false
    end
    if ok then
      local entry = vim.deepcopy(note)
      if view then
        local pos = project.project(view, note)
        if pos then
          entry.projected = {
            line = pos.line,
            end_line = pos.end_line,
            status = pos.status,
            path = view.path,
            address = anchor.describe(view),
          }
        end
      end
      table.insert(out, entry)
    end
  end
  table.sort(out, function(a, b)
    if a.anchor.path == b.anchor.path then
      return a.anchor.line < b.anchor.line
    end
    return (a.anchor.path or '') < (b.anchor.path or '')
  end)
  return out
end

--- Move the screen to a file (optionally at a revision) and place the cursor.
---@param path string
---@param opts table|nil `{ line, rev }`
---@return table status
function M.open(path, opts)
  opts = opts or {}
  local repo = current_repo()
  if not repo then
    util.err('not inside a git repository')
    return M.status()
  end

  if opts.rev and opts.rev ~= '' then
    local sha = git.file_blob(repo, opts.rev, path)
    if not sha then
      util.err(('%s does not exist at %s'):format(path, opts.rev))
      return M.status()
    end
    local buf = changeset.blob_buf(repo, sha, path, opts.rev, 'old', nil)
    vim.api.nvim_set_current_buf(buf)
  else
    local abs = vim.startswith(path, '/') and path or git.abs(repo, path)
    if not vim.uv.fs_stat(abs) then
      util.err('no such file: ' .. path)
      return M.status()
    end
    vim.cmd.edit(vim.fn.fnameescape(abs))
  end

  local line = tonumber(opts.line)
  if line then
    local total = vim.api.nvim_buf_line_count(0)
    vim.api.nvim_win_set_cursor(0, { math.min(math.max(line, 1), total), 0 })
    vim.cmd('normal! zz')
  end
  render.render(vim.api.nvim_get_current_buf())
  return M.status()
end

--- Delete notes. This is the only thing in virgil that destroys one, and it is
--- not undoable — everything else fails by keeping the note.
---@param ids string|string[]|nil
---@return boolean
function M.remove(ids)
  -- false while a chooser is still up: nothing has gone yet, and saying it did
  -- would be a lie to whoever asked
  local removed = false
  resolve_ids(ids, 'delete which note?', function(list, repo)
    if #list == 0 then
      return
    end
    -- read the summary before it is gone: this is not undoable, so the message
    -- has to say what went, not which id went
    local only = #list == 1 and store.get(repo, list[1]) or nil
    local label = only and only.summary ~= '' and only.summary or list[1]
    local n = store.remove(repo, list)
    render.refresh()
    if n > 0 then
      util.notify(n == 1 and ('removed: %s'):format(label) or ('%d notes removed'):format(n))
    end
    removed = n > 0
  end)
  return removed
end

local function jump(delta)
  local buf = vim.api.nvim_get_current_buf()
  local placed = render.notes_in(buf)
  if #placed == 0 then
    util.notify('no notes in this buffer')
    return nil
  end
  local cur = vim.api.nvim_win_get_cursor(0)[1]
  local target
  if delta > 0 then
    for _, p in ipairs(placed) do
      if p.line > cur then
        target = p
        break
      end
    end
    target = target or placed[1]
  else
    for i = #placed, 1, -1 do
      if placed[i].line < cur then
        target = placed[i]
        break
      end
    end
    target = target or placed[#placed]
  end
  vim.api.nvim_win_set_cursor(0, { math.min(target.line, vim.api.nvim_buf_line_count(buf)), 0 })
  vim.cmd('normal! zz')
  return target
end

function M.next_note()
  return jump(1)
end

function M.prev_note()
  return jump(-1)
end

--- Cycle note visibility.
---@param mode string|nil
---@return string
function M.toggle(mode)
  local m = render.toggle(mode)
  util.notify('notes: ' .. m)
  return m
end

--- Open a changeset as diff tabs.
---@param opts table|nil `{ base, head, paths, title }`
---@return table|nil
function M.review(opts)
  opts = opts or {}
  local st = changeset.start({
    base = opts.base,
    head = opts.head,
    paths = opts.paths,
    title = opts.title,
    repo = current_repo(),
  })
  if not st then
    return nil
  end
  return {
    spec = st.spec,
    title = st.title or '',
    base = st.base,
    head = st.head or '',
    files = changeset.files(),
  }
end

--- Changed files of the open changeset, or of the worktree if none is open.
---@return table[]
function M.files()
  if changeset.state then
    return changeset.files()
  end
  local repo = current_repo()
  if not repo then
    return {}
  end
  local stats = git.diff_numstat(repo, 'HEAD', nil, nil)
  local out = {}
  for _, e in ipairs(git.diff_raw(repo, 'HEAD', nil, nil)) do
    local st = stats[e.path] or { added = 0, removed = 0 }
    table.insert(out, {
      path = e.path,
      status = e.status,
      added = st.added,
      removed = st.removed,
      notes = #store.for_path(repo, e.path),
      open = false,
    })
  end
  return out
end

--- Export notes.
---@param opts table|nil `{ format, changeset, status, path, out }`
---@return string|nil
function M.export(opts)
  opts = opts or {}
  local repo = current_repo()
  if not repo then
    return nil
  end
  local notes = M.notes({ changeset = opts.changeset, status = opts.status, path = opts.path })
  for _, n in ipairs(notes) do
    n.projected = nil
  end
  local res = convert.export(notes, opts)
  if res and opts.out then
    util.notify(('exported %d note%s → %s'):format(#notes, #notes == 1 and '' or 's', res))
  end
  return res
end

--- Import notes produced by another tool.
---@param opts table `{ file, changeset, author }`
---@return integer
function M.import(opts)
  local repo = current_repo()
  if not repo then
    return 0
  end
  local n = convert.import(repo, opts or {})
  if n > 0 then
    render.refresh()
    util.notify(('imported %d note%s'):format(n, n == 1 and '' or 's'))
  end
  return n
end

--- Drop notes that can no longer be located, and long-closed ones.
---@param opts table|nil `{ dry_run, orphan_days, resolved_days }`
---@return table report
function M.prune(opts)
  opts = opts or {}
  local repo = current_repo()
  if not repo then
    return { orphan = 0, resolved = 0, removed = 0 }
  end
  local policy = config.options.prune
  local orphan_days = opts.orphan_days or policy.orphan_days
  local resolved_days = opts.resolved_days or policy.resolved_days
  local now = os.time()

  local function age_days(note)
    local t = util.parse_time(note.updated_at or note.created_at)
    if not t then
      return 0
    end
    return (now - t) / 86400
  end

  local doomed, report = {}, { orphan = 0, resolved = 0, removed = 0, ids = {} }
  for _, note in ipairs(store.all(repo)) do
    local closed = note.status == 'resolved' or note.status == 'wontfix'
    local a = note.anchor
    local located = project.anchor_lines(repo, a) ~= nil
    if not located then
      local abs = git.abs(repo, a.path or '')
      local st = vim.uv.fs_stat(abs)
      if st then
        local fd = io.open(abs, 'r')
        if fd then
          local lines = util.text_lines(fd:read('*a'))
          fd:close()
          located = project.search(a, lines) ~= nil
        end
      end
    end
    if not located and age_days(note) >= orphan_days then
      report.orphan = report.orphan + 1
      table.insert(doomed, note.id)
    elseif closed and age_days(note) >= resolved_days then
      report.resolved = report.resolved + 1
      table.insert(doomed, note.id)
    end
  end
  report.ids = doomed
  if not opts.dry_run and #doomed > 0 then
    report.removed = store.remove(repo, doomed)
    render.refresh()
  end
  return report
end

--------------------------------------------------------------------------- rpc

local function default_socket()
  local user = vim.env.USER or 'user'
  local runtime = vim.env.XDG_RUNTIME_DIR
  if runtime and runtime ~= '' then
    return vim.fs.joinpath(runtime, 'virgil.sock')
  end
  local tmp = vim.env.TMPDIR or '/tmp'
  return vim.fs.joinpath(tmp, ('virgil-%s.sock'):format(user))
end

local function socket_alive(path)
  local ok, chan = pcall(vim.fn.sockconnect, 'pipe', path, { rpc = true })
  if ok and chan and chan > 0 then
    pcall(vim.fn.chanclose, chan)
    return true
  end
  return false
end

--- Open the RPC socket agents drive virgil through.
--- The first instance takes the canonical path; later ones append their pid, so
--- several Neovims can be reviewed at once. `:Virgil socket` prints ours.
---@return string|nil
function M.start_server()
  if not config.options.socket.enable or M.socket_path then
    return M.socket_path
  end
  local path = vim.g.virgil_socket or config.options.socket.path or default_socket()
  if type(path) ~= 'string' or path == '' then
    return nil
  end
  vim.fn.mkdir(vim.fs.dirname(path), 'p')

  if vim.uv.fs_stat(path) and not socket_alive(path) then
    os.remove(path) -- a previous instance died with the socket still on disk
  end

  local ok, addr = pcall(vim.fn.serverstart, path)
  if not ok or addr == nil or addr == '' then
    path = ('%s.%d'):format(path, vim.uv.os_getpid())
    ok, addr = pcall(vim.fn.serverstart, path)
  end
  if not ok or addr == nil or addr == '' then
    return nil
  end
  M.socket_path = addr
  vim.g.virgil_socket_active = addr
  return addr
end

---@return string
function M.socket()
  return M.socket_path or ''
end

--------------------------------------------------------------------- lifecycle

--- Promote worktree anchors that gained a blob address.
---@param buf integer
function M.harden(buf)
  local view = anchor.view(buf)
  if not view or view.kind ~= 'file' then
    return
  end
  local n = anchor.harden(view)
  if n > 0 then
    project.clear_cache()
    render.refresh()
  end
end

return M
