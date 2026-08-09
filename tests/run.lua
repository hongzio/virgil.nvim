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
local changeset = require('virgil.changeset')
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

section('column fitting')
do
  local dw = vim.fn.strdisplaywidth
  eq('a short string is padded to the column', util.fit('ab', 6), 'ab    ')
  eq('one that already fits exactly is untouched', util.fit('abcdef', 6), 'abcdef')
  eq('a long one is cut and marked', util.fit('abcdefgh', 6), 'abcde…')

  -- the point: wide characters are two cells each, so cutting by character
  -- count would hand back a string twice as wide as the column
  eq('a wide string still occupies exactly the column', dw(util.fit('가나다라마바사', 6)), 6)
  -- two wide characters and the ellipsis are 5 of the 6 cells; a third would
  -- overrun, so the cell it cannot fill is padded instead
  eq('and is cut by cells, not characters', util.fit('가나다라마바사', 6), '가나… ')
  eq('a column a wide character fills exactly needs no padding', util.fit('가나다라', 5), '가나…')
  eq('mixed width counts the same way', dw(util.fit('ab가나다', 6)), 6)

  -- every column this feeds is fixed width, whatever lands in it
  for _, s in ipairs({ '', 'x', '가', 'a가b나c', string.rep('가', 40), string.rep('x', 80) }) do
    eq(('%q fills its column'):format(s), dw(util.fit(s, 12)), 12)
  end
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

  -- a narrow window (a changeset's diff half) must not be overrun
  local columns = vim.o.columns
  vim.o.columns = 44
  virgil.note({ line = 18, summary = 'a summary far too long to ride in the border of a narrow window', rationale = 'and a rationale as well', author = 'agent' })
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

section('removing notes')
do
  local repo = git.repo(dir)
  local note = store.all(repo)[1]
  local before = #store.all(repo)
  virgil.remove(note.id)
  eq('remove', #store.all(repo), before - 1)

  -- pickers select several rows at once, so it takes id lists too
  local a = virgil.note({ path = 'a.txt', line = 5, summary = 'batch one' })
  local b = virgil.note({ path = 'a.txt', line = 6, summary = 'batch two' })
  local n = #store.all(repo)
  virgil.remove({ a.id, b.id })
  eq('and a list of them', #store.all(repo), n - 2)
  eq('a missing id is not fatal', virgil.remove({ 'n-nope' }), false)

  -- with no id at all it takes the note the cursor is on, which is what the
  -- keymap does
  local buf = edit(vim.fs.joinpath(dir, 'a.txt'))
  -- line 8 has no other note: two on one line is legal, and the nearest wins
  local here = virgil.note({ path = 'a.txt', line = 8, summary = 'under the cursor' })
  render.render(buf)
  vim.api.nvim_win_set_cursor(0, { 8, 0 })
  eq('no id means the note at the cursor', virgil.remove(), true)
  check('which is the one that goes', store.get(repo, here.id) == nil)
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

  -- virgil no longer closes a note itself, but an imported one can arrive
  -- closed, and "all" is how you see it
  local id = render.notes_in(buf)[1].id
  store.update(git.repo(dir), id, { status = 'resolved' })
  render.refresh()
  render.render(buf)
  eq('a closed note drops out of the default view', #render.notes_in(buf), shown - 1)
  virgil.toggle('all')
  render.render(buf)
  eq('… and comes back under "all"', #render.notes_in(buf), shown)
  virgil.toggle('default')
  store.update(git.repo(dir), id, { status = 'open' })
end

-------------------------------------------------------------------- changeset

section('changeset')
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
  check('changeset opened', res ~= nil and #res.files == 1, res and vim.inspect(res.files))

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

  local data = changeset.tabs[tab]
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

  -- note on the new side, from inside the changeset
  vim.api.nvim_set_current_win(data.right)
  local n_new = virgil.note({ line = 4, summary = 'changed line', rationale = '' })
  eq('note stamped with its changeset', n_new.context and n_new.context.changeset, res.spec)
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
  changeset.close()
  reset_state()
  virgil.review({ base = c1, head = c2 })
  local tab2 = vim.api.nvim_get_current_tabpage()
  local d2 = changeset.tabs[tab2]
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

  changeset.close()
  eq('quit clears the changeset', changeset.state, nil)
end

section('worktree changeset')
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
  check('uncommitted changes open as a changeset', res ~= nil and #res.files == 1)
  local d = changeset.tabs[vim.api.nvim_get_current_tabpage()]
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


  changeset.close()
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

section('side ownership')
local sdir = new_repo('sides')
do
  vim.cmd('cd ' .. vim.fn.fnameescape(sdir))
  write(sdir, 'code.go', {
    'package main',
    '',
    'func alpha() int {',
    '\treturn 1',
    '}',
  })
  sh('git add -A && git commit -qm one', sdir)
  local c1 = sh('git rev-parse HEAD', sdir)

  -- notes written while the file is clean: both address the committed blob,
  -- which is also the blob the changeset's old side will hold
  reset_state()
  edit(vim.fs.joinpath(sdir, 'code.go'))
  local n_keep = virgil.note({ line = 1, summary = 'untouched line' })
  local n_chg = virgil.note({ line = 4, summary = 'line that will change' })
  eq('anchored to the committed blob', n_keep.anchor.blob, git.file_blob(git.repo(sdir), c1, 'code.go'))

  write(sdir, 'code.go', {
    'package main',
    '',
    'func alpha() int {',
    '\treturn 2',
    '}',
  })
  reset_state()
  virgil.review({ base = c1 })
  local d = changeset.tabs[vim.api.nvim_get_current_tabpage()]
  local function ids(b)
    render.render(b)
    return vim.tbl_map(function(p)
      return p.id
    end, render.notes_in(b))
  end

  -- the reported bug: editing line 4 changes the whole file's sha, so the new
  -- side stopped matching the anchor's address and *every* note in the file
  -- moved to the old side — including notes on lines the edit never touched
  check('a note on an untouched line stays on the new side', vim.tbl_contains(ids(d.right_buf), n_keep.id), vim.inspect(ids(d.right_buf)))
  check('and is not duplicated onto the old side', not vim.tbl_contains(ids(d.left_buf), n_keep.id))
  check('a note on the changed line belongs to the old side', vim.tbl_contains(ids(d.left_buf), n_chg.id))
  check('and is not drawn stale on the new side', not vim.tbl_contains(ids(d.right_buf), n_chg.id))

  -- with the pair split up, giving a note to the half nobody is looking at is
  -- indistinguishable from losing it
  vim.api.nvim_set_current_win(d.right)
  vim.cmd('only')
  eq('the old side is off screen', util.buf_is_displayed(d.left_buf), false)
  eq('so it is no longer treated as a sibling', changeset.sibling_buf(d.right_buf), nil)
  local alone = ids(d.right_buf)
  check('the old-side note is drawn where it can be seen', vim.tbl_contains(alone, n_chg.id), vim.inspect(alone))
  check('and the new-side note is still there', vim.tbl_contains(alone, n_keep.id))

  changeset.close()
end

section('changeset provenance')
local pdir = new_repo('provenance')
do
  vim.cmd('cd ' .. vim.fn.fnameescape(pdir))
  write(pdir, 'a.txt', { 'one', 'two', 'three' })
  sh('git add -A && git commit -qm one', pdir)
  local c1 = sh('git rev-parse HEAD', pdir)
  sh('git branch base-branch', pdir) -- a second name for the same commit
  write(pdir, 'a.txt', { 'one', 'TWO', 'three' })
  sh('git add -A && git commit -qm two', pdir)
  local c2 = sh('git rev-parse HEAD', pdir)

  reset_state()
  edit(vim.fs.joinpath(pdir, 'a.txt'))
  virgil.review({ base = 'base-branch', head = c2 })
  local d = changeset.tabs[vim.api.nvim_get_current_tabpage()]
  vim.api.nvim_set_current_win(d.right)
  local n = virgil.note({ line = 2, summary = 'written in a changeset' })

  eq('the label a human reads is still recorded', n.context.changeset, 'base-branch...' .. c2)
  eq('base is recorded as the commit it resolved to', n.context.base, c1)
  eq('together with the name it was typed as', n.context.base_ref, 'base-branch')
  eq('head is recorded as a commit', n.context.head, c2)
  check('a head already typed as a sha needs no second name', n.context.head_ref == nil, n.context.head_ref)

  -- the point of keeping commits: the same changeset under another spelling
  eq('a filter naming the same commits matches', #virgil.notes({ changeset = c1 .. '..' .. c2 }), 1)
  eq('a different changeset does not', #virgil.notes({ changeset = 'HEAD..worktree' }), 0)

  -- notes written before commits were kept have only their label, and it works
  local legacy = store.add(git.repo(pdir), {
    anchor = { kind = 'blob', blob = n.anchor.blob, path = 'a.txt', line = 1, end_line = 1, text = 'one' },
    author = 't',
    summary = 'legacy',
    rationale = '',
    status = 'open',
    created_at = util.now(),
    context = { changeset = 'base-branch..' .. c2 },
  })
  check('a note with no commits still matches its own label', #virgil.notes({ changeset = legacy.context.changeset }) == 2)
  changeset.close()

  -- reopened under a different spelling, the note is still *this* changeset's own
  -- and must not be dimmed as belonging to someone else's
  reset_state()
  virgil.review({ base = c1, head = c2 })
  check('the same commits under another spelling are one changeset', changeset.same_changeset(n.context, changeset.state))
  check('and a note from elsewhere is not', not changeset.same_changeset(legacy.context, { spec = 'x..y', base_sha = c2 }))
  changeset.close()

  -- a worktree changeset has no head commit, rather than a "worktree" revision
  write(pdir, 'a.txt', { 'one', 'TWO', 'four' })
  reset_state()
  edit(vim.fs.joinpath(pdir, 'a.txt'))
  virgil.review({ base = 'HEAD' })
  local d2 = changeset.tabs[vim.api.nvim_get_current_tabpage()]
  vim.api.nvim_set_current_win(d2.right)
  local w = virgil.note({ line = 3, summary = 'against the worktree' })
  eq('a worktree changeset records no head commit', w.context.head, nil)
  eq('and its base is the commit HEAD stood at', w.context.base, c2)
  changeset.close()
end

section('changeset title')
local tdir = new_repo('title')
do
  vim.cmd('cd ' .. vim.fn.fnameescape(tdir))
  write(tdir, 'a.txt', { 'one', 'two', 'three' })
  sh('git add -A && git commit -qm one', tdir)
  local c1 = sh('git rev-parse HEAD', tdir)
  write(tdir, 'a.txt', { 'one', 'TWO', 'three' })
  sh('git add -A && git commit -qm two', tdir)
  local c2 = sh('git rev-parse HEAD', tdir)
  local repo = git.repo(tdir)

  -- a name carried from the picker down to the note: state, tab, context
  reset_state()
  edit(vim.fs.joinpath(tdir, 'a.txt'))
  local res = virgil.review({ base = c1, head = c2, title = '#7 fix the retry loop' })
  eq('review() reports the title back', res.title, '#7 fix the retry loop')
  eq('and the open changeset carries it', changeset.state.title, '#7 fix the retry loop')
  local d = changeset.tabs[vim.api.nvim_get_current_tabpage()]
  eq('so does the tab', d.title, '#7 fix the retry loop')
  eq('and the buffer context read back off it', changeset.context_for_buf(d.right_buf).title, '#7 fix the retry loop')
  vim.api.nvim_set_current_win(d.right)
  local titled = virgil.note({ line = 2, summary = 'in a named changeset' })
  eq('a note written there records the name', titled.context.title, '#7 fix the retry loop')
  eq('status() reports it too', virgil.status().changeset.title, '#7 fix the retry loop')

  -- the name is decoration: identity is still the two commits
  check('a title takes no part in matching', changeset.same_changeset(titled.context, changeset.state))
  eq('and a filter still works off commits', #virgil.notes({ changeset = c1 .. '..' .. c2 }), 1)
  changeset.close()

  -- reopened without one, a further note has no title of its own
  reset_state()
  edit(vim.fs.joinpath(tdir, 'a.txt'))
  virgil.review({ base = c1, head = c2 })
  local d2 = changeset.tabs[vim.api.nvim_get_current_tabpage()]
  vim.api.nvim_set_current_win(d2.right)
  local untitled = virgil.note({ line = 3, summary = 'after reopening' })
  eq('a changeset opened with no title records none', untitled.context.title, nil)
  changeset.close()

  -- ...but the row keeps the name, wherever in the group it sits
  reset_state()
  local rows = vim.tbl_filter(function(i)
    return i.kind == 'notes'
  end, changeset.candidates(repo))
  eq('both notes are one row', #rows, 1)
  eq('labelled by the note that had a name', rows[1].label, '#7 fix the retry loop')
  eq('and the row offers it back for the next note', rows[1].title, '#7 fix the retry loop')

  -- a group nobody named falls back to the spelling of its revisions
  store.add(repo, {
    anchor = { kind = 'blob', blob = titled.anchor.blob, path = 'a.txt', line = 1, end_line = 1, text = 'one' },
    author = 't',
    summary = 'nameless',
    rationale = '',
    status = 'open',
    created_at = util.now(),
    context = { changeset = 'HEAD..worktree', base = c2 },
  })
  reset_state()
  local nameless = vim.tbl_filter(function(i)
    return i.kind == 'notes' and i.base == c2
  end, changeset.candidates(repo))
  eq('an unnamed group is labelled by its spec', nameless[1].label, 'HEAD..worktree')
  check('and offers no title to promote', nameless[1].title == nil, tostring(nameless[1].title))
end

section('merge base')
local mdir = new_repo('mergebase')
do
  vim.cmd('cd ' .. vim.fn.fnameescape(mdir))
  write(mdir, 'base.txt', { 'a' })
  sh('git add -A && git commit -qm one', mdir)
  local parted_at = sh('git rev-parse HEAD', mdir)
  local trunk = sh('git rev-parse --abbrev-ref HEAD', mdir)

  sh('git checkout -q -b feature', mdir)
  write(mdir, 'feature.txt', { 'new' })
  sh('git add -A && git commit -qm feature', mdir)

  -- the base branch moves on after the branch point, which is what makes a
  -- two-dot diff wrong: it would report base.txt as reverted by this branch
  sh('git checkout -q ' .. trunk, mdir)
  write(mdir, 'base.txt', { 'a', 'b' })
  sh('git add -A && git commit -qm three', mdir)

  reset_state()
  edit(vim.fs.joinpath(mdir, 'base.txt'))
  local res = virgil.review({ base = trunk, head = 'feature' })
  eq('the changeset is what the branch changed', #res.files, 1)
  eq('and not what the base branch moved on to', res.files[1].path, 'feature.txt')
  eq('the old side is the commit they parted at', changeset.state.base_sha, parted_at)
  eq('and the spec says three-dot', res.spec, trunk .. '...feature')
  changeset.close()

  -- a worktree changeset has no second commit to find a merge base with
  write(mdir, 'base.txt', { 'a', 'b', 'c' })
  reset_state()
  edit(vim.fs.joinpath(mdir, 'base.txt'))
  local w = virgil.review({ base = 'HEAD' })
  eq('a worktree changeset stays two-dot', w.spec, 'HEAD..worktree')
  changeset.close()
end

section('changeset candidates')
local cdir = new_repo('candidates')
do
  vim.cmd('cd ' .. vim.fn.fnameescape(cdir))
  write(cdir, 'a.txt', { 'one' })
  sh('git add -A && git commit -qm root', cdir)
  local root = sh('git rev-parse HEAD', cdir)
  write(cdir, 'a.txt', { 'two' })
  sh('git add -A && git commit -qm second', cdir)
  local second = sh('git rev-parse HEAD', cdir)

  reset_state()
  local repo = git.repo(cdir)
  local function kinds(list)
    return vim.tbl_map(function(i)
      return i.kind
    end, list)
  end
  local function first_of(list, kind)
    for i, it in ipairs(list) do
      if it.kind == kind then
        return i, it
      end
    end
  end

  local clean = changeset.candidates(repo)
  check('a clean tree offers nothing to review in it', not vim.tbl_contains(kinds(clean), 'worktree'), vim.inspect(kinds(clean)))
  local commits = vim.tbl_filter(function(i)
    return i.kind == 'commit'
  end, clean)
  eq('a root commit has no parent to diff against, so it is not offered', #commits, 1)
  eq('a commit is offered against its parent', commits[1].base, second .. '^')
  eq('and is the head of that diff', commits[1].head, second)

  write(cdir, 'a.txt', { 'three' })
  local dirty = changeset.candidates(repo)
  eq('uncommitted changes come first', dirty[1].kind, 'worktree')
  eq('measured from HEAD', dirty[1].base, 'HEAD')
  check('to the working tree, which is not a commit', dirty[1].head == nil)
  eq('counted', dirty[1].detail, '1 file')

  -- a note that remembers its changeset puts that changeset back on the list
  local function note_from(ctx)
    return store.add(repo, {
      anchor = { kind = 'blob', blob = git.file_blob(repo, second, 'a.txt'), path = 'a.txt', line = 1, end_line = 1, text = 'two' },
      author = 't',
      summary = 'from a changeset',
      rationale = '',
      status = 'open',
      created_at = util.now(),
      context = ctx,
    })
  end
  note_from({ changeset = 'root...second', base = root, head = second })
  note_from({ changeset = 'root...second', base = root, head = second })
  note_from({ changeset = 'gone...gone', base = string.rep('f', 40), head = string.rep('e', 40) })

  local listed = changeset.candidates(repo)
  local at, entry = first_of(listed, 'notes')
  check('a changeset holding notes is offered', entry ~= nil, vim.inspect(kinds(listed)))
  eq('under the label it was recorded with', entry.label, 'root...second')
  eq('once, however many notes it holds', entry.detail, '2 notes')
  check('ahead of the commit list', at < (first_of(listed, 'commit')), vim.inspect(kinds(listed)))
  eq('and a changeset whose commits are gone is not offered', #vim.tbl_filter(function(i)
    return i.kind == 'notes'
  end, listed), 1)
end

section('pull requests')
local fdir = new_repo('forge')
do
  vim.cmd('cd ' .. vim.fn.fnameescape(fdir))
  write(fdir, 'a.txt', { 'one' })
  sh('git add -A && git commit -qm one', fdir)
  local trunk = sh('git rev-parse --abbrev-ref HEAD', fdir)
  local head = sh('git rev-parse HEAD', fdir)
  local repo = git.repo(fdir)
  local forge = require('virgil.forge')

  -- no remote at all, so nothing to ask gh about
  reset_state()
  check('a repo with no GitHub remote offers no pull requests', not forge.available(repo))
  local kinds = vim.tbl_map(function(i)
    return i.kind
  end, changeset.candidates(repo))
  check('and the row is not in the list', not vim.tbl_contains(kinds, 'pr'), vim.inspect(kinds))

  sh('git remote add origin https://github.com/example/example.git', fdir)
  git.clear_cache()
  eq('a GitHub remote plus gh on PATH offers them', forge.available(repo), vim.fn.executable('gh') == 1)

  -- a non-GitHub remote is not a forge virgil knows how to ask
  sh('git remote set-url origin https://gitlab.com/example/example.git', fdir)
  git.clear_cache()
  check('a remote elsewhere does not', not forge.available(repo))

  -- the revisions a pull request is reviewed between
  sh('git remote set-url origin https://github.com/example/example.git', fdir)
  sh('git update-ref refs/remotes/origin/' .. trunk .. ' ' .. head, fdir)
  git.clear_cache()
  local pr = { number = 7, baseRefName = trunk, headRefOid = head }
  local base, h = forge.revisions(repo, pr)
  eq('the base is the remote-tracking branch when there is one', base, 'origin/' .. trunk)
  eq('and the head is the sha, not the branch name', h, head)
  sh('git update-ref -d refs/remotes/origin/' .. trunk, fdir)
  git.clear_cache()
  eq('falling back to the plain name when there is not', (forge.revisions(repo, pr)), trunk)

  check('a head already in the clone needs no fetch', forge.have_head(repo, pr))
  check('one that is not does', not forge.have_head(repo, { headRefOid = string.rep('a', 40) }))
end

section('file list sidebar')
local bdir = new_repo('sidebar')
do
  vim.cmd('cd ' .. vim.fn.fnameescape(bdir))
  write(bdir, 'alpha.txt', { 'one' })
  write(bdir, 'beta.txt', { 'one' })
  sh('git add -A && git commit -qm one', bdir)
  write(bdir, 'alpha.txt', { 'two' })
  write(bdir, 'beta.txt', { 'two' })

  reset_state()
  edit(vim.fs.joinpath(bdir, 'alpha.txt'))
  virgil.review({ base = 'HEAD' })

  local function sidebar_win(tab)
    for _, w in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
      if vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(w)):find('changeset/files', 1, true) then
        return w
      end
    end
  end
  local tab = vim.api.nvim_get_current_tabpage()
  eq('a changeset tab is two windows', #vim.api.nvim_tabpage_list_wins(tab), 2)
  check('the list is off until asked for', sidebar_win(tab) == nil)

  local columns = vim.o.columns
  vim.o.columns = 200
  eq('toggling turns it on', changeset.sidebar_toggle(), true)
  local sb = sidebar_win(tab)
  check('which adds a window', sb ~= nil)
  eq('outside the diff', vim.wo[sb].diff, false)
  eq('at the configured width', vim.api.nvim_win_get_width(sb), 40)

  -- a vsplit takes its width out of the current window alone, so without a
  -- rebalance the two halves of the diff came out lopsided — and again in
  -- every tab opened after
  local function diff_widths(t)
    local out = {}
    for _, w in ipairs(vim.api.nvim_tabpage_list_wins(t)) do
      if w ~= sidebar_win(t) then
        table.insert(out, vim.api.nvim_win_get_width(w))
      end
    end
    return out
  end
  local w1 = diff_widths(tab)
  check('the diff halves stay even', math.abs(w1[1] - w1[2]) <= 1, vim.inspect(w1))

  local buf = vim.api.nvim_win_get_buf(sb)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  eq('a row per changed file', #lines, 2)
  check('the file you are on is marked', vim.startswith(lines[1], '▸'), lines[1])
  check('and the others are not', not vim.startswith(lines[2], '▸'), lines[2])
  eq('every row is one column wide', vim.fn.strdisplaywidth(lines[1]), vim.fn.strdisplaywidth(lines[2]))

  -- open the second file from the list
  vim.api.nvim_set_current_win(sb)
  vim.api.nvim_win_set_cursor(sb, { 2, 0 })
  changeset.sidebar_open_under_cursor()
  local tab2 = vim.api.nvim_get_current_tabpage()
  eq('choosing a row opens that file', vim.t[tab2].virgil_changeset, 'beta.txt')
  check('the new tab gets a list too', sidebar_win(tab2) ~= nil)
  local w2 = diff_widths(tab2)
  check('and its diff halves are even as well', math.abs(w2[1] - w2[2]) <= 1, vim.inspect(w2))
  vim.o.columns = columns
  local moved = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  check('and the mark follows', vim.startswith(moved[2], '▸'), table.concat(moved, ' / '))
  check('one buffer, shown in both tabs', vim.api.nvim_win_get_buf(sidebar_win(tab)) == buf)

  eq('toggling turns it off', changeset.sidebar_toggle(), false)
  check('in the tab you are in', sidebar_win(tab2) == nil)
  check('and in the ones you are not', sidebar_win(tab) == nil, 'a stranded list reads as a failed toggle')
  changeset.close()
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
