--- Any command at all: the prompt goes in on stdin, the answer comes back on
--- stdout, and nothing else is assumed. `llm`, a wrapper script, `cat` in a
--- test — none of them have a session, so every question starts from nothing.
---
--- This is also the shape every other adapter is filled out from: a table given
--- straight to `question.agent` only has to say what it does differently.
---@type virgil.Agent
return {
  name = 'plain',
  -- nothing to guess at; `question.command` has to say what to run
  command = nil,
  -- no way to carry a conversation on: every question starts from nothing
  sessions = false,
  seeds_session = false,
  wants_scratch = false,

  argv = function(ctx)
    local argv = vim.deepcopy(ctx.command)
    return vim.list_extend(argv, ctx.args)
  end,

  stdin = function(ctx)
    return ctx.prompt
  end,

  answer = function(res)
    return vim.trim(res.stdout or '')
  end,

  session = function()
    return nil
  end,
}
