--- virgil configuration.
---
--- `require('virgil').setup{}` is optional; every default below works without it.
local M = {}

M.defaults = {
  --- default author stamped on notes created from this instance
  author = nil, -- nil -> $USER

  --- how many context lines are recorded around an anchor (fallback material)
  context_lines = 3,

  render = {
    --- Frame drawn around a note: 'single' | 'rounded' | 'double' | 'heavy',
    --- 'bar' for a margin bar instead of a box, 'none' for nothing at all,
    --- or eight characters in `nvim_open_win` border order.
    border = 'single',
    prefix = '▏', -- the bar, used by border = 'bar'
    icon = '●',
    question_icon = '?', -- replaces `icon` while the note is waiting on an answer
    max_width = 100, -- hard cap for wrapped note text
    show_author = true,
    show_rationale = true,
    show_replies = true, -- draw a note's replies under it, inside the same box
    align_indent = true, -- indent the note block like the code line it hangs on
  },

  --- initial visibility mode: 'default' | 'all' | 'off'  (see `:Virgil toggle`)
  visibility = 'default',

  --- 'auto' picks fzf-lua, then snacks.nvim, then quickfix
  picker = 'auto', -- 'auto' | 'fzf-lua' | 'snacks' | 'quickfix'

  changeset = {
    --- 'vertical' (side by side) or 'horizontal'
    layout = 'vertical',
    --- Highlight the old-revision (left) scratch buffer.
    --- 'syntax' highlights without ever setting 'filetype', so no language server
    --- tries to attach to a buffer that has no file behind it.
    --- 'filetype' sets it anyway; false leaves the buffer plain.
    highlight = 'syntax', -- 'syntax' | 'filetype' | false
    --- Open the changed-file list beside every changeset tab. Off by default;
    --- `:Virgil sidebar` toggles it, and the toggle outlives one changeset.
    sidebar = false,
    sidebar_width = 40,
  },

  --- Asking an agent a question left on a line of code.
  ---
  --- With no `agent` the question mark is still written and still readable
  --- through `virgil.questions()` — an agent already on the socket can answer
  --- it. All that is switched off is virgil spawning one itself.
  question = {
    --- 'claude' | 'codex' | 'plain' | an adapter table (see lua/virgil/agents/).
    --- 'plain' needs a `command` and has no session: every question starts over.
    agent = nil,
    --- replaces the adapter's own command, e.g. to pin a path or a model
    command = nil, -- string[]
    --- extra arguments the adapter drops into its own argv. They must be flags
    --- the tool accepts in *both* its start and its resume form — codex's
    --- `exec` takes `-s`/`-C` and its `exec resume` does not, and a resume that
    --- fails costs the thread its session. Per-tool config files are safer.
    args = {},
    --- who the answer is stamped as; nil -> the adapter's name
    author = nil,
    timeout = 180000, -- ms, after which the agent is killed
    context_lines = 20, -- code quoted around the anchor in the prompt
    --- dispatch as soon as a question is marked. false leaves it to `:Virgil ask`
    auto = true,
  },

  socket = {
    enable = true,
    --- nil -> $XDG_RUNTIME_DIR/virgil.sock, or $TMPDIR/virgil-$USER.sock on macOS
    path = nil,
  },

  --- `:Virgil prune` policy
  prune = {
    orphan_days = 30,
    resolved_days = 90,
  },
}

M.options = vim.deepcopy(M.defaults)

--- Merge user options in place so long-lived references stay valid.
---@param opts table|nil
function M.setup(opts)
  local merged = vim.tbl_deep_extend('force', M.options, opts or {})
  for k in pairs(M.options) do
    M.options[k] = nil
  end
  for k, v in pairs(merged) do
    M.options[k] = v
  end
end

return M
