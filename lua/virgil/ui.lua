--- Small UI helpers: the note composer and the picker fallback chain.
local config = require('virgil.config')
local util = require('virgil.util')

local M = {}

local compose_seq = 0

--- Floating scratch window for writing a note.
--- First non-empty line is the summary, everything after it the rationale.
---
--- `plain` drops that split: the whole buffer is one piece of text, which is
--- what a reply is. A reply has no summary to head it — it is already hanging
--- under the note that has one.
---
--- The last argument is always a `meta` table saying *how* it was saved —
--- `<C-s>` and `<C-q>` write the same words and differ only in `meta.question`.
--- It is a table even when nothing is set, so callers never guard for nil.
---@param opts table `{ title, summary, rationale }`, or `{ title, plain, body }`
---@param on_done fun(summary: string, rationale: string, meta: table) `fun(body, meta)` when `plain`
function M.compose(opts, on_done)
  opts = opts or {}
  local buf = vim.api.nvim_create_buf(false, true)
  compose_seq = compose_seq + 1
  pcall(vim.api.nvim_buf_set_name, buf, ('virgil://note/%d'):format(compose_seq))

  local prefilled = opts.plain and (opts.body or '') ~= '' or (opts.summary or '') ~= ''
  local lines = {}
  if opts.plain then
    lines = vim.split(opts.body or '', '\n', { plain = true })
  else
    table.insert(lines, opts.summary or '')
    if opts.rationale and opts.rationale ~= '' then
      table.insert(lines, '')
      vim.list_extend(lines, vim.split(opts.rationale, '\n', { plain = true }))
    end
  end
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

  vim.bo[buf].buftype = 'acwrite'
  vim.bo[buf].bufhidden = 'wipe'
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = 'markdown'
  vim.bo[buf].modified = false

  local width = math.min(84, math.max(40, vim.o.columns - 8))
  local height = math.min(12, math.max(6, vim.o.lines - 8))
  local win = vim.api.nvim_open_win(buf, true, {
    relative = 'editor',
    width = width,
    height = height,
    row = math.floor((vim.o.lines - height) / 2 - 1),
    col = math.floor((vim.o.columns - width) / 2),
    style = 'minimal',
    border = 'rounded',
    title = ' ' .. (opts.title or 'virgil note') .. ' ',
    title_pos = 'left',
    footer = ' <C-s> save   <C-q> ask   q cancel ',
    footer_pos = 'right',
  })
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true

  local finished = false
  local function close()
    -- leaving the float while still in insert mode would drop the user into
    -- insert mode in the code buffer underneath
    vim.cmd('stopinsert')
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end

  --- An empty composer is a cancel, and on something that already exists that
  --- is not the same as discarding it: say which one happened.
  local function abandon()
    util.warn(prefilled and 'left as it was' or 'empty note discarded')
    finished = true
    close()
  end

  ---@param meta table|nil how it was saved, e.g. `{ question = true }`
  local function submit(meta)
    if finished then
      return
    end
    meta = meta or {}
    local content = vim.api.nvim_buf_get_lines(buf, 0, -1, false)

    if opts.plain then
      local text = vim.deepcopy(content)
      while #text > 0 and vim.trim(text[1]) == '' do
        table.remove(text, 1)
      end
      while #text > 0 and vim.trim(text[#text]) == '' do
        table.remove(text)
      end
      if #text == 0 then
        abandon()
        return
      end
      finished = true
      vim.bo[buf].modified = false
      close()
      on_done(table.concat(text, '\n'), meta)
      return
    end

    local summary, rest = '', {}
    for i, l in ipairs(content) do
      if summary == '' and vim.trim(l) ~= '' then
        summary = vim.trim(l)
        rest = vim.list_slice(content, i + 1)
        break
      end
    end
    while #rest > 0 and vim.trim(rest[1]) == '' do
      table.remove(rest, 1)
    end
    while #rest > 0 and vim.trim(rest[#rest]) == '' do
      table.remove(rest)
    end
    if summary == '' then
      abandon()
      return
    end
    finished = true
    vim.bo[buf].modified = false
    close()
    on_done(summary, table.concat(rest, '\n'), meta)
  end

  vim.keymap.set({ 'n', 'i' }, '<C-s>', function()
    submit()
  end, { buffer = buf, desc = 'virgil: save note' })
  -- the same words, marked as a question. Offered whether or not an agent is
  -- configured: the mark is durable, and an agent on the socket can answer it
  vim.keymap.set({ 'n', 'i' }, '<C-q>', function()
    submit({ question = true })
  end, { buffer = buf, desc = 'virgil: save as a question' })
  vim.keymap.set('n', 'q', function()
    finished = true
    vim.bo[buf].modified = false
    close()
  end, { buffer = buf, desc = 'virgil: cancel note' })
  -- `ZZ` and `:w` mean save, not ask: only `<C-q>` marks a question
  vim.keymap.set('n', 'ZZ', function()
    submit()
  end, { buffer = buf })

  vim.api.nvim_create_autocmd('BufWriteCmd', {
    buffer = buf,
    callback = function()
      submit()
    end,
  })

  vim.cmd('startinsert')
  if prefilled then
    vim.cmd('stopinsert')
  else
    vim.api.nvim_win_set_cursor(win, { 1, 0 })
  end
  return buf
end

local function has(mod)
  return pcall(require, mod)
end

--- Choose one item from a list, through whichever picker is available.
---
--- Deliberately `vim.ui.select`-shaped, with `vim.ui.select` as the last resort
--- rather than the only option: `picker = 'fzf-lua'` should govern every list
--- virgil puts up, not `:Virgil notes` alone. Both plugins ship their own
--- implementation of this exact contract, abort included, so there is nothing
--- to do here but pick one. `quickfix` is a jump list rather than a chooser,
--- so that setting lands on `vim.ui.select` too.
---@param items table[]
---@param opts table|nil `{ prompt, format_item }`
---@param on_choice fun(item: any|nil, index: integer|nil)
function M.select(items, opts, on_choice)
  local want = config.options.picker
  if want == 'auto' then
    want = has('fzf-lua') and 'fzf-lua' or (has('snacks') and 'snacks' or 'quickfix')
  end

  if want == 'fzf-lua' then
    -- fzf-lua exports only register/deregister, and registering would hand it
    -- `vim.ui.select` for the whole editor — a decision that is the user's, not
    -- virgil's. The provider behind it is what we actually want.
    local ok, provider = pcall(require, 'fzf-lua.providers.ui_select')
    if ok and type(provider.ui_select) == 'function' then
      return provider.ui_select(items, opts, on_choice)
    end
  elseif want == 'snacks' then
    local ok, snacks = pcall(require, 'snacks')
    if ok and snacks.picker and type(snacks.picker.select) == 'function' then
      return snacks.picker.select(items, opts, on_choice)
    end
  end

  vim.ui.select(items, opts, on_choice)
end

local function abs_key(path, line)
  return vim.fs.normalize(vim.fn.fnamemodify(path, ':p')) .. ':' .. tostring(line or 1)
end

--- Actions that act on the *note*, not on the list.
---
--- fzf-lua's own `ctrl-x` on a quickfix list only drops rows from the throwaway
--- list it was handed, which reads like a delete but is not one. Here the key
--- does what its header says.
---@param index table `abs path:line -> { {id, summary}, … }`, refreshed by `fill`
---@param fill fun(): integer rebuilds the quickfix list and the index
local function note_actions(index, fill)
  local fzf = require('fzf-lua')

  --- Which notes do the selected rows stand for?
  local function ids_of(selected)
    local ids, seen = {}, {}
    for _, sel in ipairs(selected or {}) do
      local ok, entry = pcall(fzf.path.entry_to_file, sel, {})
      local candidates = (ok and entry and entry.path) and index[abs_key(entry.path, entry.line)] or {}
      for _, c in ipairs(candidates) do
        -- several notes can share a line; the summary is in the row text
        if (#candidates == 1 or sel:find(c.summary, 1, true)) and not seen[c.id] then
          seen[c.id] = true
          table.insert(ids, c.id)
        end
      end
    end
    return ids
  end

  local function act(fn)
    return function(selected)
      local ids = ids_of(selected)
      if #ids == 0 then
        util.warn('could not tell which note that row is')
        return
      end
      fn(ids)
      fill()
    end
  end

  return {
    ['ctrl-x'] = {
      fn = act(function(ids)
        require('virgil').remove(ids)
      end),
      reload = true,
      header = 'delete note',
    },
    -- no `reload`: this one takes you out of the list and into the composer,
    -- and the window has to be gone before the float opens over where it was
    ['ctrl-e'] = {
      fn = function(selected)
        local ids = ids_of(selected)
        if #ids == 0 then
          util.warn('could not tell which note that row is')
          return
        end
        if #ids > 1 then
          -- unlike delete, there is no sensible way to do several at once, and
          -- silently picking one of the marked rows is worse than saying so
          util.warn('edit takes one note at a time')
          return
        end
        vim.schedule(function()
          require('virgil').edit(ids[1])
        end)
      end,
      header = 'edit note',
    },
  }
end

--- Show notes through whichever picker is available: fzf-lua, then snacks,
--- then quickfix. virgil has no hard dependencies, so all of them may be gone.
---
--- `build()` returns quickfix-shaped items; each may carry `note_id` and
--- `summary` so the picker can act on the note behind the row.
---@param build fun(): table[]
---@param opts table|nil `{ title }`
function M.pick(build, opts)
  opts = opts or {}
  local title = opts.title or 'virgil'
  local index = {}
  local first = true

  local function fill()
    local items = build()
    -- cleared in place: the actions below hold a reference to this very table
    for k in pairs(index) do
      index[k] = nil
    end
    for _, it in ipairs(items) do
      if it.note_id then
        local key = abs_key(it.filename, it.lnum)
        index[key] = index[key] or {}
        table.insert(index[key], { id = it.note_id, summary = it.summary or '' })
      end
    end
    vim.fn.setqflist({}, first and ' ' or 'r', { title = title, items = items })
    first = false
    return #items
  end

  if fill() == 0 then
    util.notify('no notes')
    return
  end

  local want = config.options.picker
  if want == 'auto' then
    want = has('fzf-lua') and 'fzf-lua' or (has('snacks') and 'snacks' or 'quickfix')
  end

  if want == 'fzf-lua' and has('fzf-lua') then
    require('fzf-lua').quickfix({ actions = note_actions(index, fill) })
  elseif want == 'snacks' and has('snacks') then
    require('snacks').picker.qflist()
  else
    vim.cmd('botright copen')
  end
end

return M
