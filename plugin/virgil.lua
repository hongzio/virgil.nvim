-- virgil.nvim — commands, <Plug> maps, highlights, autocmds.
-- Everything here works without calling `setup()`.

if vim.g.loaded_virgil then
  return
end
vim.g.loaded_virgil = true

if vim.fn.has('nvim-0.10') == 0 then
  vim.notify('virgil.nvim requires Neovim 0.10+', vim.log.levels.ERROR)
  return
end

local group = vim.api.nvim_create_augroup('virgil', { clear = true })

--------------------------------------------------------------------- highlights

local function set_highlights()
  local defs = {
    VirgilSign = { link = 'Comment' },
    VirgilBorder = { link = 'FloatBorder' },
    VirgilIcon = { link = 'DiagnosticInfo' },
    VirgilSummary = { link = 'Normal' },
    VirgilRationale = { link = 'Comment' },
    -- a reply is a new statement, not a footnote to the note's own words: it
    -- reads at the summary's weight rather than the rationale's
    VirgilReply = { link = 'Normal' },
    -- Comment, not NonText: NonText is for characters that aren't really in the
    -- buffer, and a colorscheme may draw it in the background color.
    VirgilAuthor = { link = 'Comment' },
    VirgilStale = { link = 'DiagnosticWarn' },
    VirgilOrphan = { link = 'DiagnosticError' },
    VirgilResolved = { link = 'DiagnosticOk' },
    VirgilDim = { link = 'Comment' },
  }
  for name, def in pairs(defs) do
    def.default = true
    vim.api.nvim_set_hl(0, name, def)
  end
end

set_highlights()
vim.api.nvim_create_autocmd('ColorScheme', { group = group, callback = set_highlights })

----------------------------------------------------------------------- commands

local function notify(msg, level)
  vim.notify('virgil: ' .. msg, level or vim.log.levels.INFO, { title = 'virgil' })
end

--- The second step of the changeset picker. Reached only by choosing the pull
--- request row, so the network call is never one the human did not ask for.
local function pick_pull_request(repo)
  local forge = require('virgil.forge')
  local fit = require('virgil.util').fit
  notify('asking gh for pull requests…')
  forge.pull_requests(repo, function(prs, err)
    if err then
      notify(err, vim.log.levels.ERROR)
      return
    end
    if #prs == 0 then
      notify('no open pull requests')
      return
    end
    require('virgil.ui').select(prs, {
      prompt = 'pull requests',
      format_item = function(pr)
        return ('#%-5d %s  %s%s'):format(
          pr.number,
          fit(pr.title, 52),
          pr.author and pr.author.login or '?',
          pr.isDraft and '  draft' or ''
        )
      end,
    }, function(pr)
      if not pr then
        return
      end
      local base, head = forge.revisions(repo, pr)
      -- the number first, so it survives being truncated into a column later:
      -- two revisions do not say which pull request they came out of
      local title = ('#%d %s'):format(pr.number, pr.title)
      local function open()
        require('virgil').review({ base = base, head = head, title = title })
      end
      if forge.have_head(repo, pr) then
        open()
        return
      end
      -- a clone that never saw the branch does not have the sha gh named
      local ask = ('#%d is not in this clone yet.\nFetch pull/%d/head from origin?'):format(pr.number, pr.number)
      if vim.fn.confirm(ask, '&Yes\n&No', 1) ~= 1 then
        return
      end
      notify(('fetching pull/%d/head…'):format(pr.number))
      forge.fetch_head(repo, pr, function(ok, ferr)
        if not ok then
          notify(ferr or 'fetch failed', vim.log.levels.ERROR)
          return
        end
        open()
      end)
    end)
  end)
end

local subcommands = {
  note = function(_, range)
    require('virgil').note(range and { line = range[1], end_line = range[2] } or {})
  end,

  notes = function()
    local git = require('virgil.git')
    local repo = git.repo(vim.api.nvim_buf_get_name(0)) or git.repo(vim.uv.cwd())
    -- rebuilt after every picker action, so the list reflects what just happened
    local function build()
      local items = {}
      for _, note in ipairs(require('virgil').notes({})) do
        local pos = note.projected
        items[#items + 1] = {
          filename = repo and git.abs(repo, note.anchor.path) or note.anchor.path,
          lnum = pos and pos.line or note.anchor.line,
          col = 1,
          note_id = note.id,
          summary = note.summary,
          text = ('[%s] %s%s%s'):format(
            note.status,
            note.summary,
            pos and pos.status ~= 'ok' and (' (' .. pos.status .. ')') or '',
            #(note.replies or {}) > 0 and ('  ↩' .. #note.replies) or ''
          ),
        }
      end
      return items
    end
    require('virgil.ui').pick(build, { title = 'virgil notes' })
  end,
  remove = function(args)
    require('virgil').remove(args[1])
  end,
  -- `:Virgil reply <note-id>`; with no id, the note at the cursor
  reply = function(args)
    require('virgil').reply(args[1])
  end,
  -- and the pair of it, since deleting a reply is as irreversible as deleting
  -- a note: `:Virgil unreply [note-id] [reply-id]`
  unreply = function(args)
    require('virgil').unreply(args[1], args[2])
  end,
  toggle = function(args)
    require('virgil').toggle(args[1])
  end,
  -- With revisions, review them. With none, ask which changeset — the answer is
  -- rarely the working tree once an agent has left notes somewhere else.
  review = function(args)
    if #args > 0 then
      require('virgil').review({ base = args[1], head = args[2] })
      return
    end
    local git = require('virgil.git')
    local fit = require('virgil.util').fit
    local repo = git.repo(vim.api.nvim_buf_get_name(0)) or git.repo(vim.uv.cwd())
    if not repo then
      vim.notify('virgil: not inside a git repository', vim.log.levels.ERROR, { title = 'virgil' })
      return
    end
    local items = require('virgil.changeset').candidates(repo)
    if #items == 0 then
      vim.notify('virgil: nothing to review', vim.log.levels.INFO, { title = 'virgil' })
      return
    end
    table.insert(items, { kind = 'other', label = 'other revisions…', detail = 'type them out' })

    require('virgil.ui').select(items, {
      prompt = 'changeset',
      format_item = function(it)
        return ('%-9s %s  %s'):format(it.kind, fit(it.label, 52), it.detail or '')
      end,
    }, function(choice)
      if not choice then
        return
      end
      if choice.kind == 'other' then
        -- hand it to the command line, where ref completion already works
        vim.schedule(function()
          vim.fn.feedkeys(':Virgil review ', 'n')
        end)
        return
      end
      if choice.kind == 'pr' then
        pick_pull_request(repo)
        return
      end
      -- `title` only where the row carries a real one; a row labelled with its
      -- own spec must not have that spelling promoted into a name
      require('virgil').review({ base = choice.base, head = choice.head, title = choice.title })
    end)
  end,
  files = function()
    local changeset = require('virgil.changeset')
    local files = require('virgil').files()
    if #files == 0 then
      vim.notify('virgil: no changed files', vim.log.levels.INFO, { title = 'virgil' })
      return
    end
    require('virgil.ui').select(files, {
      prompt = changeset.state and ('files · ' .. changeset.state.spec) or 'changed files',
      format_item = function(f)
        return ('%s %-50s +%d -%d%s'):format(f.status, f.path, f.added, f.removed, f.notes > 0 and ('  ' .. f.notes .. '♦') or '')
      end,
    }, function(choice)
      if not choice then
        return
      end
      if changeset.state then
        changeset.open_file(choice.path)
      else
        require('virgil').open(choice.path, {})
      end
    end)
  end,
  export = function(args)
    require('virgil').export({ out = args[1], format = args[2] })
  end,
  import = function(args)
    require('virgil').import({ file = args[1] })
  end,
  prune = function()
    local virgil = require('virgil')
    local report = virgil.prune({ dry_run = true })
    if #report.ids == 0 then
      vim.notify('virgil: nothing to prune', vim.log.levels.INFO, { title = 'virgil' })
      return
    end
    local msg = ('prune %d note(s)? (%d unlocatable, %d long-closed)'):format(#report.ids, report.orphan, report.resolved)
    if vim.fn.confirm(msg, '&Yes\n&No', 2) == 1 then
      local done = virgil.prune({})
      vim.notify(('virgil: pruned %d note(s)'):format(done.removed), vim.log.levels.INFO, { title = 'virgil' })
    end
  end,
  socket = function()
    local sock = require('virgil').socket()
    if sock == '' then
      vim.notify('virgil: no socket (socket.enable = false?)', vim.log.levels.WARN, { title = 'virgil' })
    else
      vim.notify(sock, vim.log.levels.INFO, { title = 'virgil' })
      vim.fn.setreg('+', sock)
      print(sock)
    end
  end,
  sidebar = function()
    local changeset = require('virgil.changeset')
    if not changeset.state then
      vim.notify('virgil: no changeset is open', vim.log.levels.WARN, { title = 'virgil' })
      return
    end
    changeset.sidebar_toggle()
  end,
  quit = function()
    require('virgil.changeset').close()
  end,
  status = function()
    print(vim.inspect(require('virgil').status()))
  end,
}

local names = vim.tbl_keys(subcommands)
table.sort(names)

vim.api.nvim_create_user_command('Virgil', function(cmd)
  local args = cmd.fargs
  local name = table.remove(args, 1) or 'status'
  local fn = subcommands[name]
  if not fn then
    vim.notify(('virgil: unknown command %q (try %s)'):format(name, table.concat(names, ', ')), vim.log.levels.ERROR)
    return
  end
  local range = cmd.range > 0 and { cmd.line1, cmd.line2 } or nil
  fn(args, range)
end, {
  nargs = '*',
  range = true,
  desc = 'virgil',
  complete = function(lead, line)
    local parts = vim.split(line, '%s+')
    if #parts <= 2 then
      return vim.tbl_filter(function(n)
        return vim.startswith(n, lead)
      end, names)
    end
    if parts[2] == 'review' then
      local git = require('virgil.git')
      local repo = git.repo(vim.api.nvim_buf_get_name(0)) or git.repo(vim.uv.cwd())
      if repo then
        return vim.tbl_filter(function(r)
          return vim.startswith(r, lead)
        end, git.refs(repo))
      end
    end
    return {}
  end,
})

------------------------------------------------------------------- <Plug> maps

local plugs = {
  ['<Plug>(virgil-note)'] = function()
    require('virgil').note({})
  end,
  ['<Plug>(virgil-next-note)'] = function()
    require('virgil').next_note()
  end,
  ['<Plug>(virgil-prev-note)'] = function()
    require('virgil').prev_note()
  end,
  -- rewrites the words of the note at the cursor; where it points does not move
  ['<Plug>(virgil-edit)'] = function()
    require('virgil').edit()
  end,
  -- the note at the cursor, and irreversibly: nothing else in virgil destroys one
  ['<Plug>(virgil-remove)'] = function()
    require('virgil').remove()
  end,
  -- answers the note at the cursor; the reply hangs under it in the same box
  ['<Plug>(virgil-reply)'] = function()
    require('virgil').reply()
  end,
  -- both of these ask which reply when the note has more than one
  ['<Plug>(virgil-reply-edit)'] = function()
    require('virgil').update_reply()
  end,
  ['<Plug>(virgil-reply-remove)'] = function()
    require('virgil').unreply()
  end,
  ['<Plug>(virgil-toggle)'] = function()
    require('virgil').toggle()
  end,
  ['<Plug>(virgil-sidebar)'] = function()
    subcommands.sidebar({})
  end,
  ['<Plug>(virgil-next-file)'] = function()
    require('virgil.changeset').cycle_file(1)
  end,
  ['<Plug>(virgil-prev-file)'] = function()
    require('virgil.changeset').cycle_file(-1)
  end,
}

for lhs, rhs in pairs(plugs) do
  vim.keymap.set('n', lhs, rhs, { desc = 'virgil: ' .. lhs:match('%(virgil%-(.-)%)') })
end

-- visual mode: note on the selected range
vim.keymap.set('x', '<Plug>(virgil-note)', function()
  local start_line = vim.fn.line('v')
  local end_line = vim.fn.line('.')
  if start_line > end_line then
    start_line, end_line = end_line, start_line
  end
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<Esc>', true, false, true), 'nx', false)
  require('virgil').note({ line = start_line, end_line = end_line })
end, { desc = 'virgil: note on selection' })

----------------------------------------------------------------------- autocmds

local render = nil
local function lazy_render()
  render = render or require('virgil.render')
  return render
end

vim.api.nvim_create_autocmd({ 'BufReadPost', 'BufWinEnter', 'BufEnter' }, {
  group = group,
  callback = function(ev)
    lazy_render().schedule(ev.buf)
  end,
})

vim.api.nvim_create_autocmd({ 'TextChanged', 'InsertLeave' }, {
  group = group,
  callback = function(ev)
    lazy_render().schedule(ev.buf)
  end,
})

-- the file list follows you between a changeset's tabs; what changes is which row
-- is marked current
vim.api.nvim_create_autocmd('TabEnter', {
  group = group,
  callback = function()
    local ok, changeset = pcall(require, 'virgil.changeset')
    if ok and changeset.state then
      changeset.sidebar_sync()
    end
  end,
})

vim.api.nvim_create_autocmd('BufWritePost', {
  group = group,
  callback = function(ev)
    require('virgil').harden(ev.buf)
    lazy_render().schedule(ev.buf)
  end,
})

-- a commit (or checkout) elsewhere can turn worktree anchors into blob anchors
vim.api.nvim_create_autocmd({ 'FocusGained', 'VimResume' }, {
  group = group,
  callback = function()
    require('virgil.git').clear_cache()
    for _, buf in ipairs(require('virgil.util').visible_buffers()) do
      require('virgil').harden(buf)
    end
    lazy_render().refresh()
  end,
})

vim.api.nvim_create_autocmd({ 'BufDelete', 'BufWipeout' }, {
  group = group,
  callback = function(ev)
    require('virgil.anchor').forget(ev.buf)
    lazy_render().placed[ev.buf] = nil
  end,
})

vim.api.nvim_create_autocmd('VimEnter', {
  group = group,
  once = true,
  callback = function()
    require('virgil').start_server()
    lazy_render().refresh()
  end,
})
