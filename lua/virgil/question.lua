--- Questions left on a line of code, and the agents that answer them.
---
--- Modelled on `forge`: the only thing in virgil that spawns a process lives in
--- its own file, everything that leaves the editor is asynchronous, and none of
--- it runs unless someone asked for it. What each agent CLI wants on its
--- command line is not here — that is `virgil.agents`.
---
--- A question is a note or a reply carrying `question = true`. It is answered
--- when some reply in the same thread carries `answers = <that id>`, and by
--- nothing else: not by being followed, not by being recent. Replies merge by
--- appending, so a link written by the instance that answers survives; a flag
--- written back onto the question would not (`store.merge_replies`).
local config = require('virgil.config')
local git = require('virgil.git')
local project = require('virgil.project')
local store = require('virgil.store')
local util = require('virgil.util')

local agents = require('virgil.agents')

local M = {}

--- Jobs in flight, keyed by repository and question id. In memory and never
--- written down: a crashed editor must not come back to a note that has been
--- asking for ever, and there is nothing on disk worth resuming.
---@type table<string, table>
M.jobs = {}

---@param repo table
---@param question_id string
---@return string
function M.key(repo, question_id)
  return repo.common .. '\0' .. question_id
end

--- Every question in a note's thread, in the order they were asked, each with
--- the reply that answers it if one exists.
---
--- The note itself is a question when it carries the flag; its id is then the
--- one an answer names. Replies can ask too — a thread really does go
--- ask, answer, ask again — and there the reply's own id is what is named.
---@param note table
---@return table[] `{ { id, kind, text, author, created_at, answer } }`
function M.thread(note)
  local answered = {}
  for _, reply in ipairs(note.replies or {}) do
    if reply.answers then
      -- first one wins: a second reply naming the same question is a second
      -- opinion, not a correction of who answered first
      answered[reply.answers] = answered[reply.answers] or reply
    end
  end

  local out = {}
  if note.question then
    table.insert(out, {
      id = note.id,
      kind = 'note',
      text = note.summary,
      author = note.author,
      created_at = note.created_at,
      answer = answered[note.id],
    })
  end
  for _, reply in ipairs(note.replies or {}) do
    if reply.question then
      table.insert(out, {
        id = reply.id,
        kind = 'reply',
        text = reply.body,
        author = reply.author,
        created_at = reply.created_at,
        answer = answered[reply.id],
      })
    end
  end
  return out
end

--- The job asking one of this note's questions right now, if any.
---@param repo table
---@param note table
---@return table|nil job, string|nil question_id
function M.pending(repo, note)
  for _, q in ipairs(M.thread(note)) do
    local job = M.jobs[M.key(repo, q.id)]
    if job then
      return job, q.id
    end
  end
  return nil
end

--- Flat rows for `virgil.questions()`: one per question, across notes.
---
--- `state` defaults to `unanswered`, which is the only state a caller usually
--- wants — an unanswered question is somebody waiting.
---@param repo table
---@param notes table[] already filtered and projected by the caller
---@param filter table|nil `{ note_id, state }`
---@return table[]
function M.list(repo, notes, filter)
  filter = filter or {}
  local want = filter.state or 'unanswered'
  local out = {}
  for _, note in ipairs(notes) do
    if not filter.note_id or note.id == filter.note_id then
      for _, q in ipairs(M.thread(note)) do
        local job = M.jobs[M.key(repo, q.id)]
        local row = {
          note_id = note.id,
          question_id = q.id,
          kind = q.kind,
          text = q.text,
          author = q.author,
          created_at = q.created_at,
          answered = q.answer ~= nil,
          pending = job ~= nil and job.state == 'running' or nil,
          failed = job ~= nil and job.state == 'failed' and (job.err or 'failed') or nil,
          summary = note.summary,
          path = note.anchor.path,
          line = note.anchor.line,
          projected = note.projected,
        }
        if q.answer then
          row.answer = { id = q.answer.id, author = q.answer.author, body = q.answer.body }
        end
        local keep = want == 'all'
          or (want == 'unanswered' and not row.answered)
          or (want == 'answered' and row.answered)
          or (want == 'pending' and row.pending)
        if keep then
          table.insert(out, row)
        end
      end
    end
  end
  return out
end


--- Which session a follow-up on this note should carry on in.
---
--- The newest answer that recorded one wins, and only when the same adapter
--- made it: a session id is a handle into one tool's own store, and swapping
--- `question.agent` leaves the old one pointing at nothing.
---@param note table
---@param agent virgil.Agent
---@return string|nil
function M.session_of(note, agent)
  local replies = note.replies or {}
  for i = #replies, 1, -1 do
    local reply = replies[i]
    if reply.session and reply.agent == agent.name then
      return reply.session
    end
  end
  return nil
end

--------------------------------------------------------------------- the prompt

---@param repo table
---@param a table anchor
---@return string[]|nil lines, integer|nil offset, boolean current
local function source_lines(repo, a)
  local abs = git.abs(repo, a.path)
  if abs and vim.uv.fs_stat(abs) then
    local fd = io.open(abs, 'r')
    if fd then
      local text = fd:read('*a')
      fd:close()
      return vim.split(text or '', '\n', { plain = true }), nil, true
    end
  end
  local stored = project.anchor_lines(repo, a)
  if stored then
    return stored, nil, false
  end
  return nil, nil, false
end

--- The anchored lines with their neighbours, numbered, with the anchor marked.
---@param repo table
---@param note table
---@return string block, boolean current whether it is what is on disk now
local function code_block(repo, note)
  local a = note.anchor
  local lines, _, current = source_lines(repo, a)
  local first, last = a.line, a.end_line or a.line
  if lines then
    -- the file may have moved under the note; find where the text lives now so
    -- the numbers we quote are the ones the agent will see when it opens it
    local hit = project.search(a, lines)
    if hit then
      last = hit + (last - first)
      first = hit
    end
  else
    -- nothing readable: fall back to the neighbours recorded in the anchor
    lines = {}
    vim.list_extend(lines, a.before or {})
    table.insert(lines, a.text or '')
    vim.list_extend(lines, a.after or {})
    first = #(a.before or {}) + 1
    last = first
  end

  local span = config.options.question.context_lines
  local out = {}
  for i = math.max(1, first - span), math.min(#lines, last + span) do
    local mark = (i >= first and i <= last) and '>' or ' '
    table.insert(out, ('%s %5d  %s'):format(mark, i, lines[i]))
  end
  return table.concat(out, '\n'), current
end

--- Everything the agent needs to answer one question, as plain Markdown.
---
--- Headings rather than XML-ish tags: a note says whatever a person typed, and
--- a `<note>` in their prose would close a tag that never opened.
---
--- Resuming is a different prompt, not a shorter version of the same one. The
--- session already holds the code, the thread and whatever the agent worked out
--- last time; sending it all again is noise it has to reconcile with what it
--- remembers.
---@param repo table
---@param note table
---@param q table one entry from `M.thread`
---@param opts table|nil `{ resuming }`
---@return string
function M.prompt(repo, note, q, opts)
  opts = opts or {}
  local a = note.anchor
  local where = ('%s:%s'):format(a.path, a.line == (a.end_line or a.line) and a.line or (a.line .. '-' .. a.end_line))
  local out = {}
  local function add(s)
    table.insert(out, s)
  end

  if opts.resuming then
    add('A follow-up question on the same note, from the same person.')
    add('')
    add(('The code is at `%s`, and may have changed since you last looked — read it again if the answer turns on it.'):format(where))
    add('')
    for _, reply in ipairs(note.replies or {}) do
      if reply.created_at and q.created_at and reply.created_at < q.created_at and not reply.session then
        -- written by hand between your last answer and this question
        add(('%s said: %s'):format(reply.author ~= '' and reply.author or 'someone', reply.body))
        add('')
      end
    end
    add('## The question')
    add('')
    add(q.text or '')
    add('')
    add('Answer it in your final response: prose, no preamble, no restating the question.')
    return table.concat(out, '\n')
  end

  add('A developer left a question on a line of code. Answer it.')
  add('')
  add('Put the answer in your final response: prose, no preamble, no restating')
  add('the question. Your working directory is the root of the repository, so')
  add('read whatever files you need.')
  add('')

  local block, current = code_block(repo, note)
  add(('## %s'):format(where))
  add('')
  add(current and 'This is what the file holds right now:' or 'The file could not be read; this is what the note was written against:')
  add('')
  add('```')
  add(block)
  add('```')
  add('')

  local ctx = note.context
  if ctx then
    add('## The change under review')
    add('')
    if ctx.title and ctx.title ~= '' then
      add(('- %s'):format(ctx.title))
    end
    if ctx.changeset then
      add(('- changeset `%s` (%s..%s)'):format(ctx.changeset, ctx.base or '?', ctx.head or '?'))
    end
    if ctx.hunk_header then
      add(('- hunk `%s`'):format(ctx.hunk_header))
    end
    add('')
  end

  add('## The note')
  add('')
  add(('- %s'):format(note.summary ~= '' and note.summary or '(no summary)'))
  if note.rationale and note.rationale ~= '' then
    add('')
    add(note.rationale)
  end
  add('')

  local thread = {}
  for _, reply in ipairs(note.replies or {}) do
    if reply.id ~= q.id then
      table.insert(thread, ('- %s%s: %s'):format(reply.author ~= '' and reply.author or 'someone', reply.question and ' asked' or '', reply.body))
    end
  end
  if #thread > 0 then
    add('## The thread so far')
    add('')
    vim.list_extend(out, thread)
    add('')
  end

  add('## The question')
  add('')
  add(q.text or '')
  add('')
  add('Rules: answer this and nothing else. Cite `file:line` for anything you')
  add('looked at. If you cannot work it out, say so plainly rather than')
  add('guessing. Do not call `virgil.reply` for this answer — virgil records')
  add('your final response as the reply itself.')
  return table.concat(out, '\n')
end

------------------------------------------------------------------ dispatching

--- What to put on screen when a run did not produce an answer.
---@param res table `vim.system` result
---@param timeout integer|nil ms
---@return string
local function why(res, timeout)
  if res.signal ~= 0 then
    return ('timed out after %ds'):format(math.floor((timeout or 0) / 1000))
  end
  local last = ''
  for _, line in ipairs(vim.split(res.stderr or '', '\n', { plain = true })) do
    if vim.trim(line) ~= '' then
      last = vim.trim(line)
    end
  end
  return last ~= '' and last or ('exited with %d'):format(res.code)
end

---@param job table
local function clean_scratch(job)
  if job.scratch then
    pcall(vim.uv.fs_unlink, job.scratch)
    job.scratch = nil
  end
end

---@param job table
local function finish(job)
  clean_scratch(job)
  M.jobs[M.key(job.repo, job.question_id)] = nil
end

--- Everything the answer to one question ends up as, once the process is done.
---@param job table
---@param res table `vim.system` result
---@param ctx table
local function record(job, res, ctx)
  local agent = job.agent

  local body, err = agent.answer(res, ctx)
  body = body and vim.trim(body) or ''
  -- a CLI that thinks it is on a terminal colours what it prints; the note
  -- store is a text file people read
  body = body:gsub('\27%[[%d;]*m', '')
  if body == '' then
    job.state = 'failed'
    job.err = err or 'the agent said nothing'
    clean_scratch(job)
    util.warn(('ask failed: %s'):format(job.err))
    return false
  end

  local LIMIT = 4000
  if #body > LIMIT then
    body = body:sub(1, LIMIT) .. '\n[…truncated]'
  end

  local reply = store.add_reply(job.repo, job.note_id, {
    author = config.options.question.author or agent.name,
    body = body,
    answers = job.question_id,
    session = agent.session(res, ctx),
    agent = agent.name,
  })
  if not reply then
    -- the note went while we were asking. The words cost somebody real time,
    -- so they go where they can still be read rather than nowhere
    util.warn(('note %s is gone; the answer was not saved'):format(job.note_id))
    vim.api.nvim_echo({ { body } }, true, {})
    finish(job)
    return false
  end
  finish(job)
  require('virgil.render').refresh()
  return true
end

--- Ask the configured agent one question, and write its answer back as a reply.
---
--- Returns `false` and a reason rather than failing when there is no agent to
--- ask: the question mark is already written and is worth something on its own.
---@param repo table
---@param note_id string
---@param question_id string the note's own id, or a reply's
---@param opts table|nil `{ on_done }`
---@return boolean sent, string|nil err
function M.dispatch(repo, note_id, question_id, opts)
  opts = opts or {}
  local cfg = config.options.question

  local agent, err = agents.resolve(cfg.agent, cfg.command)
  if not agent then
    return false, err
  end
  if vim.fn.executable(agent.command[1]) ~= 1 then
    return false, ('%s is not on your PATH'):format(agent.command[1])
  end

  local note = store.get(repo, note_id)
  if not note then
    return false, ('no note %s'):format(note_id)
  end
  local question
  for _, q in ipairs(M.thread(note)) do
    if q.id == question_id then
      question = q
    end
  end
  if not question then
    return false, ('%s is not a question on %s'):format(question_id, note_id)
  end

  local key = M.key(repo, question_id)
  local running = M.jobs[key]
  if running and running.state == 'running' then
    return false, 'already asking'
  end
  if agent.sessions then
    -- one session, one conversation: two processes carrying the same thread on
    -- at once is not something any of these tools promises to survive
    local busy = M.pending(repo, note)
    if busy and busy.state == 'running' then
      return false, 'already asking about this note'
    end
  end
  M.jobs[key] = nil

  local session = agent.sessions and M.session_of(note, agent) or nil
  M.spawn(repo, note, question, agent, {
    session = session,
    resuming = session ~= nil,
    on_done = opts.on_done,
  })
  return true
end

--- Start one run. Split out of `dispatch` because the retry after a dead
--- session comes back through here rather than through the checks above.
---@param repo table
---@param note table
---@param question table
---@param agent virgil.Agent
---@param opts table `{ session, resuming, retried, on_done }`
function M.spawn(repo, note, question, agent, opts)
  local cfg = config.options.question
  local prompt = M.prompt(repo, note, question, { resuming = opts.resuming })

  local ctx = {
    repo = repo,
    note = note,
    question = question,
    prompt = prompt,
    command = agent.command,
    args = cfg.args or {},
    session = opts.session,
    new_session = (not opts.resuming and agent.seeds_session) and util.uuid() or nil,
    resuming = opts.resuming or nil,
    scratch = agent.wants_scratch and vim.fn.tempname() or nil,
  }

  local job = {
    repo = repo,
    note_id = note.id,
    question_id = question.id,
    agent = agent,
    state = 'running',
    started_at = os.time(),
    session = opts.session,
    resuming = opts.resuming or nil,
    retried = opts.retried or nil,
    scratch = ctx.scratch,
  }
  M.jobs[M.key(repo, question.id)] = job

  job.handle = vim.system(agent.argv(ctx), {
    cwd = repo.root,
    text = true,
    stdin = agent.stdin(ctx),
    timeout = cfg.timeout,
    env = {
      VIRGIL_SOCK = vim.g.virgil_socket_active,
      VIRGIL_REPO = repo.root,
      VIRGIL_NOTE_ID = note.id,
      VIRGIL_QUESTION_ID = question.id,
    },
  }, function(res)
    vim.schedule(function()
      if M.jobs[M.key(repo, question.id)] ~= job then
        -- cancelled, or replaced by a newer ask; nothing here is wanted
        clean_scratch(job)
        return
      end

      local ok = res.code == 0 and res.signal == 0
      if not ok and job.resuming and not job.retried then
        -- a session that is gone fails the same way a real error does, and
        -- reading the difference out of stderr is guesswork. Starting over
        -- costs one run; not starting over wedges the thread for good
        clean_scratch(job)
        M.jobs[M.key(repo, question.id)] = nil
        local fresh = store.get(repo, note.id) or note
        M.spawn(repo, fresh, question, agent, { retried = true, on_done = opts.on_done })
        return
      end

      local done
      if not ok then
        job.state = 'failed'
        job.err = why(res, cfg.timeout)
        clean_scratch(job)
        util.warn(('ask failed: %s'):format(job.err))
        done = false
      else
        done = record(job, res, ctx)
      end
      require('virgil.render').refresh()
      if opts.on_done then
        opts.on_done(done, job.err)
      end
    end)
  end)
end

--------------------------------------------------------------------- cancelling

--- Stop asking one question. The job goes at once so the answer, if the process
--- has already written one, is dropped rather than landing after the fact.
---@param repo table
---@param question_id string
---@return boolean
function M.cancel(repo, question_id)
  local key = M.key(repo, question_id)
  local job = M.jobs[key]
  if not job then
    return false
  end
  M.jobs[key] = nil
  clean_scratch(job)
  if job.handle then
    pcall(function()
      job.handle:kill('sigterm')
    end)
  end
  return true
end

--- Unmake a question's answer, because it is no longer the question that was
--- answered.
---
--- The answer's words are left where they are — `unreply` is still the only
--- thing in virgil that destroys a reply — but the link that made it *the*
--- answer goes, so the question is open again and can be put afresh. A new
--- answer lands under the old one, which is a thread reading in order rather
--- than a hole where somebody's words used to be.
---
--- A run still in flight is stopped: it was handed the old wording and would
--- come back answering that. A run that already failed is dropped too, because
--- its error is about a question that no longer reads that way.
---@param repo table
---@param note_id string
---@param question_id string
---@return boolean undone whether there was anything to undo
function M.reopen(repo, note_id, question_id)
  local stopped = M.cancel(repo, question_id)
  local note = store.get(repo, note_id)
  local unlinked = false
  for _, reply in ipairs(note and note.replies or {}) do
    if reply.answers == question_id then
      store.update_reply(repo, note_id, reply.id, { answers = vim.NIL })
      unlinked = true
    end
  end
  return stopped or unlinked
end

--- Stop asking anything about these notes — they are about to stop existing.
---@param repo table
---@param ids string[]|string
---@return integer
function M.cancel_for(repo, ids)
  ids = type(ids) == 'string' and { ids } or ids
  local want = {}
  for _, id in ipairs(ids) do
    want[id] = true
  end
  -- collected first: cancelling takes entries out of the table being walked
  local hits = {}
  for _, job in pairs(M.jobs) do
    if job.repo.common == repo.common and want[job.note_id] then
      table.insert(hits, job.question_id)
    end
  end
  local stopped = 0
  for _, question_id in ipairs(hits) do
    if M.cancel(repo, question_id) then
      stopped = stopped + 1
    end
  end
  return stopped
end

--- Leaving the editor takes the agents with it; otherwise they keep working,
--- and keep spending, on a question nobody is waiting for any more.
function M.cancel_all()
  local jobs = {}
  for _, job in pairs(M.jobs) do
    table.insert(jobs, job)
  end
  M.jobs = {}
  for _, job in ipairs(jobs) do
    clean_scratch(job)
    if job.handle then
      pcall(function()
        job.handle:kill('sigterm')
      end)
    end
  end
end

return M
