--- What each agent CLI wants on its command line.
---
--- The adapter builds the whole argument list, rather than virgil building one
--- and the adapter adding flags to it. That is not generality for its own sake:
--- codex resumes a session with a subcommand in the middle of the line, and no
--- amount of appending reaches that position. The same split covers the other
--- difference worth having — whether the session id is one we hand the tool or
--- one we read back out of what it printed.
---
--- Adding a tool is one table; see `virgil.Agent` and the three beside this file.
local M = {}

---@class virgil.Agent
---@field name string
---@field command string[]|nil executable and subcommand, before any arguments
---@field sessions boolean the tool can carry a conversation on at all
---@field seeds_session boolean virgil mints the session id and passes it in
---@field wants_scratch boolean virgil provides a temp file as `ctx.scratch`
---@field argv fun(ctx: table): string[] the whole command line
---@field stdin fun(ctx: table): string|nil what to write to the process
---@field answer fun(res: table, ctx: table): string|nil, string|nil body, error
---@field session fun(res: table, ctx: table): string|nil id to carry forward

local BUILTIN = { 'plain', 'claude', 'codex' }

local loaded = {}

---@param name string
---@return virgil.Agent|nil
local function builtin(name)
  if not vim.tbl_contains(BUILTIN, name) then
    return nil
  end
  if not loaded[name] then
    loaded[name] = require('virgil.agents.' .. name)
  end
  return loaded[name]
end

--- The adapter `question.agent` names, with `command` settled.
---
--- A table given instead of a name is an adapter too; `plain` fills in whatever
--- it left out, so saying only what differs is enough.
---@param spec string|table|nil
---@param command string[]|nil overrides the adapter's own, from `question.command`
---@return virgil.Agent|nil agent, string|nil err
function M.resolve(spec, command)
  if spec == nil then
    return nil, 'no question.agent configured'
  end

  local base
  if type(spec) == 'string' then
    base = builtin(spec)
    if not base then
      return nil, ('unknown question.agent %q (try %s, or an adapter table)'):format(spec, table.concat(BUILTIN, ', '))
    end
  elseif type(spec) == 'table' then
    base = spec
  else
    return nil, 'question.agent must be a name or an adapter table'
  end

  -- a copy every time: `command` below is settled per call, and the built-in
  -- tables are shared. A table of one's own also only has to say what differs
  local agent = vim.tbl_extend('force', builtin('plain'), base)
  if agent.name == 'plain' and base ~= builtin('plain') then
    agent.name = 'agent'
  end

  if command ~= nil then
    if type(command) ~= 'table' then
      return nil, "question.command must be a list like { 'claude', '-p' }"
    end
    agent.command = command
  end
  if type(agent.command) ~= 'table' or #agent.command == 0 then
    return nil, ('question.agent %q has no command; set question.command'):format(agent.name)
  end
  return agent
end

return M
