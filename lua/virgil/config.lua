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
    max_width = 100, -- hard cap for wrapped note text
    show_author = true,
    show_rationale = true,
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
