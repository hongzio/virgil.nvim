--- Claude Code, driven through `-p`.
---
--- The session id is ours to choose: `--session-id` plants the one we hand it,
--- so there is nothing to read back out of the output and stdout stays what it
--- should be — the answer, and only the answer.
---@type virgil.Agent
return {
  name = 'claude',
  command = { 'claude', '-p' },
  sessions = true,
  -- we mint the uuid; see `--session-id` below
  seeds_session = true,
  wants_scratch = false,

  argv = function(ctx)
    local argv = vim.deepcopy(ctx.command)
    vim.list_extend(argv, ctx.args)
    if ctx.resuming then
      vim.list_extend(argv, { '--resume', ctx.session })
    elseif ctx.new_session then
      vim.list_extend(argv, { '--session-id', ctx.new_session })
    end
    return argv
  end,

  stdin = function(ctx)
    return ctx.prompt
  end,

  answer = function(res)
    return vim.trim(res.stdout or '')
  end,

  session = function(_, ctx)
    return ctx.resuming and ctx.session or ctx.new_session
  end,
}
