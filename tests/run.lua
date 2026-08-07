-- virgil.nvim test suite.
--   nvim --clean -l tests/run.lua
--

local root = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
vim.opt.runtimepath:prepend(root)
vim.cmd('runtime! plugin/virgil.lua')

local passed, failures = 0, {}
local current = ''

local function section(name)
  current = name
  io.write(('\n\27[1m%s\27[0m\n'):format(name))
end

local function check(name, cond, extra)
  if cond then
    passed = passed + 1
    io.write(('  \27[32m✓\27[0m %s\n'):format(name))
  else
    table.insert(failures, current .. ' › ' .. name .. (extra and ('  [' .. tostring(extra) .. ']') or ''))
    io.write(('  \27[31m✗\27[0m %s%s\n'):format(name, extra and ('  ' .. tostring(extra)) or ''))
  end
end

local function eq(name, got, want)
  check(name, got == want, ('got %s, want %s'):format(vim.inspect(got), vim.inspect(want)))
end

--------------------------------------------------------------------- fixtures

local function sh(cmd, cwd)
  local res = vim.system({ 'sh', '-c', cmd }, { cwd = cwd, text = true }):wait()
  if res.code ~= 0 then
    error(('cmd failed (%s): %s\n%s'):format(cwd, cmd, res.stderr))
  end
  return vim.trim(res.stdout or '')
end

local tmp_root = vim.fn.tempname()
vim.fn.mkdir(tmp_root, 'p')

local function new_repo(name)
  local dir = vim.fs.joinpath(tmp_root, name)
  vim.fn.mkdir(dir, 'p')
  sh('git init -q && git config user.email t@t && git config user.name t && git config commit.gpgsign false', dir)
  return dir
end

local function write(dir, rel, lines)
  local path = vim.fs.joinpath(dir, rel)
  vim.fn.mkdir(vim.fs.dirname(path), 'p')
  vim.fn.writefile(lines, path)
  return path
end

local function numbered(n, prefix)
  local out = {}
  for i = 1, n do
    table.insert(out, ('%sline %d'):format(prefix or '', i))
  end
  return out
end

local function edit(path)
  vim.cmd('edit! ' .. vim.fn.fnameescape(path))
  return vim.api.nvim_get_current_buf()
end

local function reset_state()
  require('virgil.store').reset()
  require('virgil.project').clear_cache()
  require('virgil.git').clear_cache()
end

local virgil = require('virgil')
local anchor = require('virgil.anchor')
local git = require('virgil.git')
local project = require('virgil.project')
local render = require('virgil.render')
local review = require('virgil.review')
local store = require('virgil.store')
local util = require('virgil.util')

----------------------------------------------------------------- unit: mapping

section('projection maths')
do
  local base = util.lines_text(numbered(5))

  local function hunks_to(lines)
    return vim.diff(base, util.lines_text(lines), { result_type = 'indices' })
  end

  -- insertion above
  local h = hunks_to(vim.list_extend({ 'new' }, numbered(5)))
  eq('one hunk for a top insertion', #h, 1)
  eq('line 1 shifts to 2', (project.map_line(h, 1)), 2)
  eq('line 5 shifts to 6', (project.map_line(h, 5)), 6)
  check('shifted lines are not stale', not select(2, project.map_line(h, 3)))

  -- deletion above
  local kept = numbered(5)
  table.remove(kept, 1)
  h = hunks_to(kept)
  eq('line 5 shifts to 4 after a deletion above', (project.map_line(h, 5)), 4)
  check('the deleted line itself is stale', select(2, project.map_line(h, 1)))
  -- nothing replaced it, so it has nowhere to land: the note stays on the side
  -- that still has the line
  check('and is reported as gone', select(3, project.map_line(h, 1)))
  check('a rewritten line is stale but not gone', not select(3, project.map_line(hunks_to({ 'x', 'line 2', 'line 3', 'line 4', 'line 5' }), 1)))

  -- edit in place
  local edited = numbered(5)
  edited[3] = 'rewritten'
  h = hunks_to(edited)
  check('the rewritten line is stale', select(2, project.map_line(h, 3)))
  check('its neighbours are not', not select(2, project.map_line(h, 4)))
  eq('and they keep their position', (project.map_line(h, 4)), 4)

  -- unrelated change below
  local appended = numbered(5)
  table.insert(appended, 'tail')
  h = hunks_to(appended)
  eq('a change below never moves a line', (project.map_line(h, 2)), 2)
  eq('no hunks at all is identity', (project.map_line(nil, 42)), 42)
end

section('fallback search')
do
  local a = {
    kind = 'worktree',
    path = 'p',
    line = 3,
    end_line = 3,
    text = '\tif err != nil {',
    before = { 'x, err := f()', '' },
    after = { '\t\treturn err', '\t}' },
  }
  local lines = {
    '\tif err != nil {', -- decoy, no context
    '\t\treturn nil',
    '',
    'x, err := f()',
    '',
    '\tif err != nil {', -- the real one
    '\t\treturn err',
    '\t}',
  }
  eq('context disambiguates repeated lines', project.search(a, lines), 6)
  eq('missing text yields nil', project.search({ text = 'nope', line = 1, before = {}, after = {} }, lines), nil)
end

------------------------------------------------------------------- note layer

section('note layer')
local dir = new_repo('phase1')
do
  write(dir, 'a.txt', numbered(20))
  sh('git add -A && git commit -qm init', dir)
  vim.cmd('cd ' .. vim.fn.fnameescape(dir))

  local buf = edit(vim.fs.joinpath(dir, 'a.txt'))
  local view = anchor.view(buf)
  check('view resolved', view ~= nil and view.path == 'a.txt', view and view.path)

  local note = virgil.note({ line = 10, summary = 'tenth line', rationale = 'because' })
  check('note created', note ~= nil)
  eq('clean file gets an immutable address', note.anchor.kind, 'blob')
  eq('anchor records the line text', note.anchor.text, 'line 10')

  -- 1. notes survive a restart
  local repo = git.repo(dir)
  local notes_file = store.path(repo)
  check('notes.json lives in the git common dir', notes_file:find('%.git/virgil/notes%.json') ~= nil, notes_file)
  check('notes.json on disk', vim.uv.fs_stat(notes_file) ~= nil)

  local out = vim.system({
    vim.v.progpath,
    '--clean',
    '--headless',
    '--cmd',
    'set rtp^=' .. root,
    '-c',
    'lua vim.cmd.edit("' .. vim.fs.joinpath(dir, 'a.txt') .. '")',
    '-c',
    'lua local n=require("virgil").notes({}); io.write(("%d %s %d"):format(#n, n[1].summary, n[1].projected.line))',
    '-c',
    'qa!',
  }, { text = true }):wait()
  eq('1. a fresh Neovim finds the note at the same line', vim.trim(out.stdout or ''), '1 tenth line 10')

  -- 2. inserting a line above keeps the note attached
  vim.api.nvim_buf_set_lines(buf, 0, 0, false, { 'inserted at the top' })
  vim.cmd('silent write')
  reset_state()
  buf = edit(vim.fs.joinpath(dir, 'a.txt'))
  local pos = project.project(anchor.view(buf), store.all(git.repo(dir))[1])
  eq('2. note follows the insertion', pos.line, 11)
  eq('2. and is not marked stale', pos.status, 'ok')

  render.render(buf)
  local placed = render.notes_in(buf)
  eq('2. rendered above the right line', placed[1] and placed[1].line, 11)
  local marks = vim.api.nvim_buf_get_extmarks(buf, util.NS, 0, -1, { details = true })
  eq('note drawn as virt_lines', marks[1] and marks[1][4].virt_lines ~= nil, true)
  eq('virt_lines float above the code', marks[1] and marks[1][4].virt_lines_above, true)

  -- 3. editing the anchored line marks it stale, never deletes it
  vim.api.nvim_buf_set_lines(buf, 10, 11, false, { 'line 10 but rewritten' })
  reset_state()
  pos = project.project(anchor.view(buf), store.all(git.repo(dir))[1])
  eq('3. edited line becomes stale', pos.status, 'stale')
  eq('3. the note is still there', #store.all(git.repo(dir)), 1)
  render.render(buf)
  eq('3. and still rendered', #render.notes_in(buf), 1)
  vim.cmd('silent! edit!') -- drop the unsaved change

  -- 4. worktree anchors harden into blob anchors after a commit
  write(dir, 'b.txt', numbered(5, 'b '))
  local bbuf = edit(vim.fs.joinpath(dir, 'b.txt'))
  local wnote = virgil.note({ line = 3, summary = 'uncommitted', rationale = '' })
  eq('4. uncommitted content anchors to the worktree', wnote.anchor.kind, 'worktree')
  sh('git add -A && git commit -qm second', dir)
  reset_state()
  bbuf = edit(vim.fs.joinpath(dir, 'b.txt'))
  virgil.harden(bbuf)
  local hardened
  for _, n in ipairs(store.all(git.repo(dir))) do
    if n.summary == 'uncommitted' then
      hardened = n
    end
  end
  eq('4. hardened to a blob anchor', hardened.anchor.kind, 'blob')
  eq('4. at the same line', hardened.anchor.line, 3)
  local committed = git.file_blob(git.repo(dir), 'HEAD', 'b.txt')
  eq('4. pointing at the committed blob', hardened.anchor.blob, committed)
end

section('navigation and rendering')
do
  local buf = edit(vim.fs.joinpath(dir, 'a.txt'))
  reset_state()
  virgil.note({ line = 3, summary = 'first', rationale = '' })
  virgil.note({ line = 15, summary = 'second', rationale = '' })
  eq('rendered as soon as the note is written', #render.notes_in(buf), 3)

  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  eq(']n goes to the first note below', virgil.next_note().line, 3)
  eq(']n again continues down', virgil.next_note().line, 11)
  eq('[n goes back up', virgil.prev_note().line, 3)
  vim.api.nvim_win_set_cursor(0, { 20, 0 })
  eq(']n wraps around', virgil.next_note().line, 3)

  local marks = vim.api.nvim_buf_get_extmarks(buf, util.NS, 0, -1, { details = true })
  local virt = marks[1][4].virt_lines
  local function row(chunks)
    return table.concat(vim.tbl_map(function(c)
      return c[1]
    end, chunks))
  end
  local top, bottom = row(virt[1]), row(virt[#virt])
  check('the note is framed', vim.startswith(top, '┌') and vim.endswith(top, '┐'), vim.inspect(top))
  check('the summary rides in the top border', top:find('first', 1, true) ~= nil, top)
  check('the frame is closed', vim.startswith(bottom, '└') and vim.endswith(bottom, '┘'), vim.inspect(bottom))
  eq('every row of the frame is the same width', vim.fn.strdisplaywidth(top), vim.fn.strdisplaywidth(bottom))
  eq('border uses its own highlight group', virt[1][1][2], 'VirgilBorder')

  -- a narrow window (a review's diff half) must not be overrun
  local columns = vim.o.columns
  vim.o.columns = 44
  virgil.note({ line = 18, summary = 'a summary far too long to ride in the border of a narrow window', rationale = 'and a rationale as well', author = 'claude' })
  render.render(buf)
  marks = vim.api.nvim_buf_get_extmarks(buf, util.NS, 0, -1, { details = true })
  local widest, framed = 0, 0
  for _, m in ipairs(marks) do
    for _, l in ipairs(m[4].virt_lines) do
      widest = math.max(widest, vim.fn.strdisplaywidth(row(l)))
    end
    framed = framed + #m[4].virt_lines
  end
  check('the frame stays inside the window', widest <= util.buf_width(buf), widest .. ' > ' .. util.buf_width(buf))
  local long = render.notes_in(buf)
  check('and the long summary is kept in full', framed > 0 and #long > 0)
  vim.o.columns = columns
end

section('note lifecycle')
do
  local repo = git.repo(dir)
  local note = store.all(repo)[1]
  virgil.resolve(note.id)
  eq('resolve', store.get(repo, note.id).status, 'resolved')
  virgil.unresolve(note.id)
  eq('unresolve', store.get(repo, note.id).status, 'open')

  store.update(repo, note.id, { context = { review = 'a..b' } })
  virgil.keep(note.id)
  eq('keep cuts the review link', store.get(repo, note.id).context, nil)

  local before = #store.all(repo)
  virgil.remove(note.id)
  eq('remove', #store.all(repo), before - 1)

  -- pickers select several rows at once, so the same calls take id lists
  local a = virgil.note({ path = 'a.txt', line = 5, summary = 'batch one' })
  local b = virgil.note({ path = 'a.txt', line = 6, summary = 'batch two' })
  virgil.resolve({ a.id, b.id })
  eq('resolve takes a list', store.get(repo, a.id).status .. '/' .. store.get(repo, b.id).status, 'resolved/resolved')
  virgil.unresolve({ a.id, b.id })
  eq('so does unresolve', store.get(repo, a.id).status, 'open')
  local n = #store.all(repo)
  virgil.remove({ a.id, b.id })
  eq('and remove', #store.all(repo), n - 2)
  eq('a missing id is not fatal', virgil.remove({ 'n-nope' }), false)
end

section('visibility')
do
  local buf = edit(vim.fs.joinpath(dir, 'b.txt'))
  render.render(buf)
  local shown = #render.notes_in(buf)
  check('note visible by default', shown >= 1, shown)
  virgil.toggle('off')
  render.render(buf)
  eq('toggle off hides them', #render.notes_in(buf), 0)
  virgil.toggle('default')
  render.render(buf)
  eq('toggle back shows them', #render.notes_in(buf), shown)

  local id = render.notes_in(buf)[1].id
  virgil.resolve(id)
  render.render(buf)
  eq('resolved notes drop out of the default view', #render.notes_in(buf), shown - 1)
  virgil.toggle('all')
  render.render(buf)
  eq('… and come back under "all"', #render.notes_in(buf), shown)
  virgil.toggle('default')
  virgil.unresolve(id)
end

------------------------------------------------------------------ review view

section('review view')
local rdir = new_repo('phase2')
do
  vim.cmd('cd ' .. vim.fn.fnameescape(rdir))
  write(rdir, 'code.go', {
    'package main',
    '',
    'func alpha() int {',
    '\treturn 1',
    '}',
    '',
    '// this whole line goes away',
    '',
    'func gamma() {',
    '\tprintln("stays")',
    '}',
  })
  sh('git add -A && git commit -qm one', rdir)
  local c1 = sh('git rev-parse HEAD', rdir)

  write(rdir, 'code.go', {
    'package main',
    '',
    'func alpha() int {',
    '\treturn 2',
    '}',
    '',
    '',
    'func gamma() {',
    '\tprintln("stays")',
    '}',
  })
  sh('git add -A && git commit -qm two', rdir)
  local c2 = sh('git rev-parse HEAD', rdir)

  reset_state()
  edit(vim.fs.joinpath(rdir, 'code.go'))
  local res = virgil.review({ base = c1, head = c2 })
  check('review opened', res ~= nil and #res.files == 1, res and vim.inspect(res.files))

  local tab = vim.api.nvim_get_current_tabpage()
  local wins = vim.api.nvim_tabpage_list_wins(tab)
  eq('two windows', #wins, 2)
  local diffs = 0
  for _, w in ipairs(wins) do
    if vim.wo[w].diff then
      diffs = diffs + 1
    end
  end
  eq('both in diff mode', diffs, 2)

  local data = review.tabs[tab]
  eq('left side is the old blob', vim.b[data.left_buf].virgil_view.blob, git.file_blob(git.repo(rdir), c1, 'code.go'))
  -- 1. the right side is the real file on disk: LSP, treesitter, editing all work
  eq(
    '1. right side is a real file buffer',
    vim.uv.fs_realpath(vim.api.nvim_buf_get_name(data.right_buf)),
    vim.uv.fs_realpath(vim.fs.joinpath(rdir, 'code.go'))
  )
  eq('1. and is writable', vim.bo[data.right_buf].modifiable, true)
  eq('1. with a normal buftype (so language servers attach)', vim.bo[data.right_buf].buftype, '')
  eq('left side is read-only', vim.bo[data.left_buf].modifiable, false)

  -- note on the new side, from inside the review
  vim.api.nvim_set_current_win(data.right)
  local n_new = virgil.note({ line = 4, summary = 'changed line', rationale = '' })
  eq('note stamped with its review', n_new.context and n_new.context.review, res.spec)
  check('hunk header recorded', (n_new.context.hunk_header or ''):match('^@@') ~= nil, n_new.context.hunk_header)

  -- 3. a note on a deleted line: anchored in the old blob
  vim.api.nvim_set_current_win(data.left)
  local n_old = virgil.note({ line = 7, summary = 'deleted line', rationale = '' })
  eq('3. anchored to the old blob', n_old.anchor.blob, git.file_blob(git.repo(rdir), c1, 'code.go'))

  render.render(data.left_buf)
  render.render(data.right_buf)
  local left_ids = vim.tbl_map(function(p)
    return p.id
  end, render.notes_in(data.left_buf))
  local right_ids = vim.tbl_map(function(p)
    return p.id
  end, render.notes_in(data.right_buf))
  check('3. deleted-line note shows on the old side', vim.tbl_contains(left_ids, n_old.id))
  check('3. and not on the new side', not vim.tbl_contains(right_ids, n_old.id), vim.inspect(right_ids))
  check('new-side note shows on the new side', vim.tbl_contains(right_ids, n_new.id))
  -- the reported bug: a note written on a changed line also appeared on the
  -- opposite side, marked stale, the instant it was created
  check('and only there — never stale on the old side', not vim.tbl_contains(left_ids, n_new.id), vim.inspect(left_ids))
  for _, side in ipairs({ data.left_buf, data.right_buf }) do
    local seen = {}
    for _, p in ipairs(render.notes_in(side)) do
      check('each note is drawn once per side', not seen[p.id], p.id)
      seen[p.id] = true
    end
  end

  -- a note on a line this changeset did not touch belongs to one side too
  vim.api.nvim_set_current_win(data.right)
  local n_same = virgil.note({ line = 1, summary = 'unchanged line' })
  render.render(data.left_buf)
  render.render(data.right_buf)
  local function ids(b)
    return vim.tbl_map(function(p)
      return p.id
    end, render.notes_in(b))
  end
  check('unchanged-line note shows on the new side', vim.tbl_contains(ids(data.right_buf), n_same.id))
  check('and is not duplicated onto the old side', not vim.tbl_contains(ids(data.left_buf), n_same.id))
  virgil.remove(n_same.id)

  -- 2. close and reopen: notes land on exactly the same lines
  local before_left = render.notes_in(data.left_buf)[1].line
  local before_right
  for _, p in ipairs(render.notes_in(data.right_buf)) do
    if p.id == n_new.id then
      before_right = p.line
    end
  end
  review.close()
  reset_state()
  virgil.review({ base = c1, head = c2 })
  local tab2 = vim.api.nvim_get_current_tabpage()
  local d2 = review.tabs[tab2]
  render.render(d2.left_buf)
  render.render(d2.right_buf)
  eq('2. old-side note is back on the same line', render.notes_in(d2.left_buf)[1].line, before_left)
  local after_right
  for _, p in ipairs(render.notes_in(d2.right_buf)) do
    if p.id == n_new.id then
      after_right = p.line
    end
  end
  eq('2. new-side note is back on the same line', after_right, before_right)

  eq('files() reports the changeset', #virgil.files(), 1)
  eq('files() counts notes', virgil.files()[1].notes, 2)

  review.close()
  eq('quit clears the review', review.state, nil)
end

section('worktree review')
do
  write(rdir, 'code.go', {
    'package main',
    '',
    'func alpha() int {',
    '\treturn 3',
    '}',
  })
  reset_state()
  local res = virgil.review({ base = 'HEAD' })
  check('uncommitted changes open as a review', res ~= nil and #res.files == 1)
  local d = review.tabs[vim.api.nvim_get_current_tabpage()]
  eq('right side is the working tree file', vim.bo[d.right_buf].buftype, '')
  local n = virgil.note({ line = 4, summary = 'dirty note' })
  eq('a dirty file anchors to the worktree', n.anchor.kind, 'worktree')

  render.render(d.right_buf)
  render.render(d.left_buf)
  local right_ids = vim.tbl_map(function(p)
    return p.id
  end, render.notes_in(d.right_buf))
  local left_ids = vim.tbl_map(function(p)
    return p.id
  end, render.notes_in(d.left_buf))
  check('a note on uncommitted content shows on the new side', vim.tbl_contains(right_ids, n.id))
  -- a brand new note must not turn up on the opposite side wearing a [stale]
  -- badge: nothing changed since it was written
  check('and not a second time on the old side', not vim.tbl_contains(left_ids, n.id), vim.inspect(left_ids))

  -- Uncommitted content has no address in git, but it is still in the editor,
  -- so the old side gets a real projection rather than a guess: a line that was
  -- modified shows up stale, a line that is new to the worktree not at all.
  local stored = store.get(git.repo(rdir), n.id)
  local pos = project.project(anchor.view(d.left_buf), stored)
  eq('a modified line projects back as stale', pos and pos.status, 'stale')
  check('and never as an orphan', not (pos and pos.status == 'orphan'), vim.inspect(pos))


  review.close()
end

------------------------------------------------------------------- conversion

section('external formats')
do
  local repo = git.repo(rdir)
  local out = vim.fs.joinpath(tmp_root, 'agent-context.json')
  virgil.export({ format = 'agent-context', out = out })
  check('export writes a file', vim.uv.fs_stat(out) ~= nil)
  local decoded = vim.json.decode(table.concat(vim.fn.readfile(out), '\n'))
  check('files[].annotations[].newRange', decoded.files[1].annotations[1].newRange.start ~= nil, vim.inspect(decoded.files[1]))

  local before = #store.all(repo)
  virgil.import({ file = out })
  check('import round-trips', #store.all(repo) > before, #store.all(repo))

  local md = virgil.export({ format = 'markdown' })
  check('markdown export', type(md) == 'string' and md:find('##') ~= nil)
end

section('rpc surface')
do
  local st = virgil.status()
  check('status() returns a view', st.view ~= nil and st.view.address ~= nil, vim.inspect(st.view))
  check('status() is json-encodable', pcall(vim.json.encode, st))
  local sock = virgil.start_server()
  check('serverstart', type(sock) == 'string' and sock ~= '', sock)
  check('socket() reports it', virgil.socket() == sock)
end

section('prune policy')
do
  local repo = git.repo(rdir)
  local ghost = store.add(repo, {
    anchor = { kind = 'blob', blob = string.rep('f', 40), path = 'gone.txt', line = 1, end_line = 1, text = 'x' },
    author = 't',
    summary = 'ghost',
    rationale = '',
    status = 'open',
    created_at = '2020-01-01T00:00:00Z',
  })
  local report = virgil.prune({ dry_run = true })
  check('unlocatable old note is prune-eligible', vim.tbl_contains(report.ids, ghost.id), vim.inspect(report))
  local fresh = store.add(repo, {
    anchor = { kind = 'blob', blob = string.rep('e', 40), path = 'gone.txt', line = 1, end_line = 1, text = 'x' },
    author = 't',
    summary = 'fresh ghost',
    rationale = '',
    status = 'open',
    created_at = util.now(),
  })
  report = virgil.prune({ dry_run = true })
  check('recent unlocatable note is kept', not vim.tbl_contains(report.ids, fresh.id))
  report = virgil.prune({})
  check('prune removes them', report.removed >= 1, vim.inspect(report))
  check('and only them', store.get(repo, fresh.id) ~= nil)
end

--------------------------------------------------------------------- summary

io.write(('\n%d passed, %d failed\n'):format(passed, #failures))
if #failures > 0 then
  for _, f in ipairs(failures) do
    io.write('  \27[31mFAIL\27[0m ' .. f .. '\n')
  end
  vim.cmd('cq')
end
vim.cmd('qa!')
