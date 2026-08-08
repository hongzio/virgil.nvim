--- Pull requests, and only through the `gh` CLI the human already has.
---
--- virgil has no hard dependencies. Where gh is missing, or the repository has
--- no GitHub remote, nothing here is offered and nothing fails — the pull
--- request row simply is not in the list. Every call that touches the network
--- is asynchronous and only ever runs because someone chose it.
local git = require('virgil.git')

local M = {}

--- Is there a `gh` to ask, and a GitHub remote to ask it about?
---@param repo table
---@return boolean
function M.available(repo)
  if vim.fn.executable('gh') ~= 1 then
    return false
  end
  local url = git.exec(repo, { 'remote', 'get-url', 'origin' })
  return url ~= nil and url:find('github.com', 1, true) ~= nil
end

local FIELDS = 'number,title,author,headRefName,headRefOid,baseRefName,isDraft,updatedAt'

--- Open pull requests, as gh orders them.
---@param repo table
---@param cb fun(prs: table[]|nil, err: string|nil)
function M.pull_requests(repo, cb)
  vim.system(
    { 'gh', 'pr', 'list', '--limit', '30', '--json', FIELDS },
    { cwd = repo.root, text = true },
    function(res)
      vim.schedule(function()
        if res.code ~= 0 then
          local err = vim.trim(res.stderr or '')
          cb(nil, err ~= '' and err or ('gh exited with %d'):format(res.code))
          return
        end
        local ok, data = pcall(vim.json.decode, res.stdout or '')
        if not ok or type(data) ~= 'table' then
          cb(nil, 'could not read what gh printed')
          return
        end
        cb(data)
      end)
    end
  )
end

--- The two revisions to review a pull request between.
---
--- The head is the sha gh reported, not the branch name: a branch name is only
--- meaningful in the fork it lives in, and the sha is the thing that gets
--- fetched. `review()` takes the merge base from here, which is what makes the
--- diff the one the forge shows.
---@param repo table
---@param pr table
---@return string base, string head
function M.revisions(repo, pr)
  local base = ('origin/%s'):format(pr.baseRefName)
  if not git.rev_commit(repo, base) then
    base = pr.baseRefName
  end
  return base, pr.headRefOid
end

--- Is this pull request's head already in the clone?
---@param repo table
---@param pr table
---@return boolean
function M.have_head(repo, pr)
  return pr.headRefOid ~= nil and git.rev_commit(repo, pr.headRefOid) ~= nil
end

--- Fetch one pull request's head. gh names a sha that a clone which has never
--- seen the branch does not have; without this, opening it would fail with
--- nothing more useful than "unknown revision".
---@param repo table
---@param pr table
---@param cb fun(ok: boolean, err: string|nil)
function M.fetch_head(repo, pr, cb)
  vim.system(
    { 'git', 'fetch', '--no-tags', 'origin', ('pull/%d/head'):format(pr.number) },
    { cwd = repo.root, text = true },
    function(res)
      vim.schedule(function()
        git.clear_cache()
        cb(res.code == 0, res.code ~= 0 and vim.trim(res.stderr or '') or nil)
      end)
    end
  )
end

return M
