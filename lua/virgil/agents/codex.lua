--- Codex CLI, driven through `codex exec`.
---
--- Three things here are not like `claude`, and each one is why the adapter
--- builds the whole command line rather than appending flags to a shared one:
---
---   * resuming is a *subcommand* — `codex exec resume <id> -` — so the session
---     lands in the middle of the argument list, not at the end;
---   * the session id is codex's to mint, and comes back in the first `--json`
---     event rather than going in;
---   * `--json` turns stdout into an event stream, so the answer has to be
---     collected somewhere else — `-o` writes it to a file.
---
--- `codex exec resume` also takes fewer options than `codex exec` (no `-s`,
--- no `-C`, no `--add-dir`), which is why nothing is passed here that the
--- resume form would choke on. Sandbox and model belong in `~/.codex/config.toml`,
--- which both forms read.
---@type virgil.Agent
return {
  name = 'codex',
  command = { 'codex', 'exec' },
  sessions = true,
  -- codex mints its own; see `session` below
  seeds_session = false,
  wants_scratch = true,

  argv = function(ctx)
    local argv = vim.deepcopy(ctx.command)
    if ctx.resuming then
      table.insert(argv, 'resume')
    end
    vim.list_extend(argv, { '--json', '-o', ctx.scratch })
    vim.list_extend(argv, ctx.args)
    if ctx.resuming then
      -- the session to carry on, then `-` so the prompt is still read from
      -- stdin: the resume form does not fall back to it the way `exec` does
      vim.list_extend(argv, { ctx.session, '-' })
    end
    return argv
  end,

  stdin = function(ctx)
    return ctx.prompt
  end,

  answer = function(_, ctx)
    local fd = ctx.scratch and io.open(ctx.scratch, 'r')
    if not fd then
      -- codex leaves the file uncreated when the run fails, so a missing file
      -- is a failure and not an empty answer
      return nil, 'codex wrote no answer'
    end
    local body = fd:read('*a')
    fd:close()
    return vim.trim(body or '')
  end,

  session = function(res)
    -- `{"type":"thread.started","thread_id":"…"}`, and a resumed run says it
    -- again with the same id, so this one path covers both
    for _, line in ipairs(vim.split(res.stdout or '', '\n', { plain = true })) do
      local ok, event = pcall(vim.json.decode, line)
      if ok and type(event) == 'table' and event.type == 'thread.started' then
        if type(event.thread_id) == 'string' and event.thread_id ~= '' then
          return event.thread_id
        end
      end
    end
    return nil
  end,
}
