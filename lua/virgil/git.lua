--- Thin git layer. Every content address virgil uses comes from here.
local util = require('virgil.util')

local M = {}

M.EMPTY = string.rep('0', 40)

local repo_cache = {} ---@type table<string, table|false>
local blob_cache = {} ---@type table<string, string[]>
local object_cache = {} ---@type table<string, boolean>

---@param sha string|nil
---@return boolean
function M.is_null(sha)
  return sha == nil or sha == '' or sha:match('^0+$') ~= nil
end

--- Resolve symlinks so that `/var/...` and `/private/var/...` are one repository.
---@param path string|nil
---@return string|nil
local function real(path)
  if not path or path == '' then
    return path
  end
  local resolved = vim.uv.fs_realpath(path)
  if not resolved then
    local dir = vim.uv.fs_realpath(vim.fs.dirname(path))
    resolved = dir and vim.fs.joinpath(dir, vim.fs.basename(path)) or nil
  end
  return vim.fs.normalize(resolved or path)
end

local function sys(cmd, opts)
  opts = opts or {}
  local ok, res = pcall(function()
    return vim
      .system(cmd, {
        cwd = opts.cwd,
        stdin = opts.stdin,
        text = opts.text ~= false,
      })
      :wait()
  end)
  if not ok then
    return nil
  end
  return res
end

--- Run git inside `repo`. Returns stdout on success, nil plus stderr otherwise.
---@param repo table|nil
---@param args string[]
---@param opts table|nil
---@return string|nil out, string|nil err
function M.exec(repo, args, opts)
  opts = opts or {}
  local cmd = { 'git', '--no-optional-locks', '-c', 'core.quotepath=false' }
  vim.list_extend(cmd, args)
  local res = sys(cmd, {
    cwd = opts.cwd or (repo and repo.root) or vim.uv.cwd(),
    stdin = opts.stdin,
    text = opts.text,
  })
  if not res then
    return nil, 'git not executable'
  end
  if res.code ~= 0 then
    return nil, vim.trim(res.stderr or '')
  end
  return res.stdout or ''
end

--- Resolve the repository containing `path` (a file or directory).
---@param path string|nil
---@return table|nil repo `{ root, common }`
function M.repo(path)
  local dir
  if path and path ~= '' then
    dir = vim.fn.isdirectory(path) == 1 and path or vim.fs.dirname(path)
  end
  if not dir or dir == '' then
    dir = vim.uv.cwd()
  end
  dir = vim.fs.normalize(dir)

  local hit = repo_cache[dir]
  if hit ~= nil then
    return hit or nil
  end

  local res = sys({ 'git', 'rev-parse', '--show-toplevel', '--git-common-dir' }, { cwd = dir })
  if not res or res.code ~= 0 then
    repo_cache[dir] = false
    return nil
  end
  local out = vim.split(vim.trim(res.stdout), '\n')
  local root = real(out[1] or '') or ''
  local common = out[2] or '.git'
  -- `--git-common-dir` is printed relative to the command's cwd
  if not vim.startswith(common, '/') then
    common = vim.fs.joinpath(dir, common)
  end
  common = real(common) or common
  if root == '' then
    repo_cache[dir] = false
    return nil
  end
  local repo = { root = root, common = common }
  repo_cache[dir] = repo
  return repo
end

--- Repository-relative path.
---@param repo table
---@param abs string
---@return string|nil
function M.rel(repo, abs)
  abs = real(abs) or vim.fs.normalize(abs)
  if abs == repo.root then
    return ''
  end
  local prefix = repo.root .. '/'
  if vim.startswith(abs, prefix) then
    return abs:sub(#prefix + 1)
  end
  return nil
end

---@param repo table
---@param rel string
---@return string
function M.abs(repo, rel)
  return vim.fs.joinpath(repo.root, rel)
end

--- Hash buffer/file contents the way git would, without writing an object.
---@param repo table
---@param text string
---@param path string|nil absolute path, so clean filters apply as they would on write
---@return string|nil
function M.hash_object(repo, text, path)
  local args = { 'hash-object', '-t', 'blob' }
  if path then
    table.insert(args, '--path')
    table.insert(args, path)
  end
  table.insert(args, '--stdin')
  local out = M.exec(repo, args, { stdin = text })
  if not out then
    return nil
  end
  out = vim.trim(out)
  return out ~= '' and out or nil
end

--- Blob sha of a file on disk.
---@param repo table
---@param abs string
---@return string|nil
function M.hash_file(repo, abs)
  local out = M.exec(repo, { 'hash-object', '-t', 'blob', '--', abs })
  if not out then
    return nil
  end
  out = vim.trim(out)
  return #out == 40 and out or nil
end

--- Is this blob still reachable in the object database?
---@param repo table
---@param sha string|nil
---@return boolean
function M.have_object(repo, sha)
  if M.is_null(sha) then
    return false
  end
  local key = repo.common .. ':' .. sha
  local hit = object_cache[key]
  if hit ~= nil then
    return hit
  end
  local out = M.exec(repo, { 'cat-file', '-e', sha .. '^{blob}' })
  local ok = out ~= nil
  object_cache[key] = ok
  return ok
end

--- Blob contents as lines. Cached: blobs are immutable.
---@param repo table
---@param sha string|nil
---@return string[]|nil
function M.blob_lines(repo, sha)
  if M.is_null(sha) then
    return nil
  end
  local key = repo.common .. ':' .. sha
  local hit = blob_cache[key]
  if hit then
    return hit
  end
  local out = M.exec(repo, { 'cat-file', 'blob', sha })
  if not out then
    object_cache[key] = false
    return nil
  end
  local lines = util.text_lines(out)
  blob_cache[key] = lines
  object_cache[key] = true
  return lines
end

--- Blob sha of `path` at `rev` (nil when the path does not exist there).
---@param repo table
---@param rev string
---@param path string
---@return string|nil
function M.file_blob(repo, rev, path)
  local out = M.exec(repo, { 'rev-parse', '--verify', '--quiet', ('%s:%s'):format(rev, path) })
  if not out then
    return nil
  end
  out = vim.trim(out)
  return #out == 40 and out or nil
end

---@param repo table
---@param rev string
---@return string|nil
function M.rev_parse(repo, rev)
  local out = M.exec(repo, { 'rev-parse', '--verify', '--quiet', rev })
  return out and vim.trim(out) ~= '' and vim.trim(out) or nil
end

--- Resolve `rev` to a commit that actually exists in this repository.
--- (`rev-parse --verify` happily echoes any well-formed sha, so it cannot be
--- used on its own to tell whether a revision is real.)
---@param repo table
---@param rev string
---@return string|nil
function M.rev_commit(repo, rev)
  local out = M.exec(repo, { 'rev-parse', '--verify', '--quiet', rev .. '^{commit}' })
  return out and vim.trim(out) ~= '' and vim.trim(out) or nil
end

--- The commit two revisions parted from, if they share any history.
---@param repo table
---@param a string
---@param b string
---@return string|nil
function M.merge_base(repo, a, b)
  local out = M.exec(repo, { 'merge-base', a, b })
  return out and vim.trim(out) ~= '' and vim.trim(out) or nil
end

---@param repo table
---@param rev string
---@return string short human label for a revision
function M.short(repo, rev)
  if not rev or rev == '' then
    return 'worktree'
  end
  local out = M.exec(repo, { 'rev-parse', '--short', rev })
  return out and vim.trim(out) or rev
end

--- `git diff --raw`: the anchor map for a changeset.
---@param repo table
---@param base string|nil
---@param head string|nil nil compares against the worktree
---@param paths string[]|nil
---@return table[] entries `{ status, old_sha, new_sha, path, old_path }`
function M.diff_raw(repo, base, head, paths)
  local args = { 'diff', '--raw', '--no-abbrev', '-z', '--no-color', '--find-renames' }
  if base and base ~= '' then
    table.insert(args, base)
  end
  if head and head ~= '' then
    table.insert(args, head)
  end
  if paths and #paths > 0 then
    table.insert(args, '--')
    vim.list_extend(args, paths)
  end
  local out = M.exec(repo, args)
  if not out then
    return {}
  end

  local fields = vim.split(out, '\0', { plain = true })
  local entries = {}
  local i = 1
  while i <= #fields do
    local meta = fields[i]
    if meta and vim.startswith(meta, ':') then
      local old_sha, new_sha, status = meta:match('^:%S+%s+%S+%s+(%S+)%s+(%S+)%s+(%S+)$')
      if status then
        local kind = status:sub(1, 1)
        if kind == 'R' or kind == 'C' then
          local src, dst = fields[i + 1], fields[i + 2]
          table.insert(entries, { status = kind, old_sha = old_sha, new_sha = new_sha, path = dst, old_path = src })
          i = i + 3
        else
          table.insert(entries, { status = kind, old_sha = old_sha, new_sha = new_sha, path = fields[i + 1], old_path = fields[i + 1] })
          i = i + 2
        end
      else
        i = i + 1
      end
    else
      i = i + 1
    end
  end
  return entries
end

--- Added/removed line counts per path, keyed by path.
---@return table<string, {added:integer, removed:integer}>
function M.diff_numstat(repo, base, head, paths)
  local args = { 'diff', '--numstat', '-z', '--no-color', '--find-renames' }
  if base and base ~= '' then
    table.insert(args, base)
  end
  if head and head ~= '' then
    table.insert(args, head)
  end
  if paths and #paths > 0 then
    table.insert(args, '--')
    vim.list_extend(args, paths)
  end
  local out = M.exec(repo, args)
  local stats = {}
  if not out then
    return stats
  end
  local fields = vim.split(out, '\0', { plain = true })
  local i = 1
  while i <= #fields do
    local rec = fields[i]
    local added, removed, inline_path
    if rec then
      added, removed, inline_path = rec:match('^(%S+)\t(%S+)\t?(.*)$')
    end
    if added then
      local path = inline_path
      if path == '' then
        -- rename: source and destination follow as separate NUL fields
        path = fields[i + 2]
        i = i + 3
      else
        i = i + 1
      end
      if path and path ~= '' then
        stats[path] = { added = tonumber(added) or 0, removed = tonumber(removed) or 0 }
      end
    else
      i = i + 1
    end
  end
  return stats
end

--- Files whose worktree content differs from the index/HEAD.
---@param repo table
---@return table<string, boolean>
function M.dirty_paths(repo)
  local out = M.exec(repo, { 'status', '--porcelain', '-z', '--untracked-files=no' })
  local dirty = {}
  if not out then
    return dirty
  end
  for _, rec in ipairs(vim.split(out, '\0', { plain = true })) do
    local path = rec:match('^..%s(.+)$')
    if path then
      dirty[path] = true
    end
  end
  return dirty
end

--- Branch/tag names, for command completion.
---@param repo table
---@return string[]
function M.refs(repo)
  local out = M.exec(repo, { 'for-each-ref', '--format=%(refname:short)', 'refs/heads', 'refs/tags', 'refs/remotes' })
  if not out then
    return {}
  end
  return vim.split(vim.trim(out), '\n', { trimempty = true })
end

function M.clear_cache()
  repo_cache = {}
  object_cache = {}
end

return M
